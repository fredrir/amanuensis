import asyncio
import io
import json
import os
import sys

import pytest

from screen_scribe_backend.__main__ import Server
from screen_scribe_backend.config import BackendError
from screen_scribe_backend.subscriptions import RPCProcess


async def test_backend_keeps_serving_after_invalid_request():
    output = io.StringIO()
    server = Server(output)
    try:
        await server.handle(
            {"id": "bad", "method": "extract", "params": {"apiKey": "secret"}}
        )
        await server.handle({"id": "good", "method": "health"})
        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        assert messages[0]["error"]["code"] == "invalid_request"
        assert messages[1]["result"]["version"] == 1
        assert "secret" not in output.getvalue()
    finally:
        await server.api.close()


async def test_stdio_client_matches_out_of_order_responses(tmp_path):
    script = tmp_path / "server.py"
    script.write_text("""import sys, json
requests = [json.loads(sys.stdin.readline()) for _ in range(2)]
for request in reversed(requests):
    print(json.dumps({'id': request['id'], 'result': {'method': request['method']}}), flush=True)
for _ in sys.stdin: pass
""")
    rpc = RPCProcess(
        [sys.executable, "-u", str(script)], os.environ.copy(), str(tmp_path)
    )
    await rpc.start()
    try:
        first, second = await asyncio.gather(rpc.call("first"), rpc.call("second"))
        assert first == {"method": "first"}
        assert second == {"method": "second"}
    finally:
        await rpc.close()
    assert rpc.process.returncode is not None


async def test_client_crash_fails_request_without_waiting_for_timeout(tmp_path):
    rpc = RPCProcess(
        [sys.executable, "-c", "import sys; sys.stdin.readline()"],
        os.environ.copy(),
        str(tmp_path),
    )
    await rpc.start()
    try:
        with pytest.raises(BackendError, match="stopped"):
            await asyncio.wait_for(rpc.call("anything"), 3)
    finally:
        await rpc.close()
