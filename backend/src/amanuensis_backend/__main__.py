import asyncio
import contextlib
import json
import logging
import mimetypes
import os
import signal
import sys

from pydantic import ValidationError

from .config import GRANITE_PACKAGES, STATE_ROOT, BackendError, granite_ready
from .extraction import ExtractionRequest, Extractor
from .providers import APIProviders, Provider
from .subscriptions import Subscriptions


class Server:
    def __init__(self, output):
        self.output = output
        self.api = APIProviders()
        self.subscriptions = Subscriptions(self.notify)
        self.extractor = Extractor(self.api, self.subscriptions, self.notify)

    def send(self, message):
        self.output.write(json.dumps(message, ensure_ascii=False) + "\n")
        self.output.flush()

    def notify(self, event, params):
        self.send({"event": event, "params": params})

    async def dispatch(self, method, params):
        if method == "health":
            return {"version": 1, "graniteReady": granite_ready()}
        if method == "extract":
            return await self.extractor.extract(
                ExtractionRequest.model_validate(params)
            )
        if method == "models":
            provider = Provider.model_validate(params["provider"])
            if provider.kind in ("codex", "geminiSubscription"):
                models = await self.subscriptions.models(provider.kind)
            else:
                models = await self.api.models(provider)
            return {"models": models}
        if method in ("account/status", "account/login", "account/logout"):
            kind = params.get("kind")
            if kind not in ("codex", "geminiSubscription"):
                raise BackendError(
                    "This provider uses an API key.", "invalid_configuration"
                )
            return await getattr(self.subscriptions, method.split("/")[1])(kind)
        raise BackendError("Unknown backend method.", "invalid_request")

    async def handle(self, request):
        request_id = request.get("id")
        try:
            result = await self.dispatch(request["method"], request.get("params", {}))
            self.send({"id": request_id, "result": result})
        except (ValidationError, KeyError, TypeError, ValueError):
            self.send(
                {
                    "id": request_id,
                    "error": {
                        "code": "invalid_request",
                        "message": "Invalid backend request.",
                    },
                }
            )
        except BackendError as exc:
            self.send(
                {"id": request_id, "error": {"code": exc.code, "message": str(exc)}}
            )
        except TimeoutError:
            self.send(
                {
                    "id": request_id,
                    "error": {"code": "timeout", "message": "Extraction timed out."},
                }
            )
        except Exception as exc:  # noqa: BLE001 — protocol boundary
            logging.getLogger(__name__).error(
                "Backend operation failed: %s", type(exc).__name__
            )
            self.send(
                {
                    "id": request_id,
                    "error": {
                        "code": "backend_error",
                        "message": "Extraction failed. Check the model and try again.",
                    },
                }
            )

    async def run(self):
        reader = asyncio.StreamReader(limit=32 * 1024 * 1024)
        loop = asyncio.get_running_loop()
        transport, _ = await loop.connect_read_pipe(
            lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer
        )
        tasks = set()
        try:
            while line := await reader.readline():
                try:
                    request = json.loads(line)
                    if not isinstance(request, dict):
                        raise TypeError()
                except (ValueError, TypeError):
                    self.send(
                        {
                            "id": None,
                            "error": {
                                "code": "invalid_request",
                                "message": "Invalid JSON request.",
                            },
                        }
                    )
                    continue
                task = asyncio.create_task(self.handle(request))
                tasks.add(task)
                task.add_done_callback(tasks.discard)
        finally:
            transport.close()
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await self.subscriptions.close()
            await self.api.close()


def main():
    os.umask(0o077)
    if GRANITE_PACKAGES.is_dir():
        sys.path.append(str(GRANITE_PACKAGES))
    STATE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.environ["HF_HOME"] = str(STATE_ROOT / "cache/huggingface")
    os.environ["XDG_CACHE_HOME"] = str(STATE_ROOT / "cache")
    os.environ["TORCH_HOME"] = str(STATE_ROOT / "cache/torch")
    # System MIME files may be unreadable inside App Sandbox.
    mimetypes.knownfiles = []
    mimetypes.init()
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    # Libraries may write to stdout at the native level. Reserve a separate FD
    # for the protocol and route every other stdout write to stderr.
    output = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)

    async def run():
        current = asyncio.current_task()
        for sig in (signal.SIGTERM, signal.SIGINT):
            asyncio.get_running_loop().add_signal_handler(sig, current.cancel)
        try:
            await Server(output).run()
        finally:
            # Native inference can outlive an asyncio cancellation. Child clients
            # have already been closed by Server.run; exit without waiting for MLX.
            os._exit(0)

    with contextlib.suppress(
        asyncio.CancelledError, KeyboardInterrupt, BrokenPipeError
    ):
        asyncio.run(run())


if __name__ == "__main__":
    main()
