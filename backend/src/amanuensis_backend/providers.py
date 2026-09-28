import asyncio
from typing import Literal
from urllib.parse import quote, urlsplit

import httpx
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from .config import MODEL_ID, MODEL_ROOT, BackendError

ProviderKind = Literal[
    "granite", "gemini", "openAICompatible", "anthropic", "codex", "geminiSubscription"
]


class Provider(BaseModel):
    model_config = ConfigDict(
        extra="ignore", populate_by_name=True, str_strip_whitespace=True
    )
    kind: ProviderKind
    base_url: str = Field(default="", alias="baseURL")
    api_key: SecretStr = Field(default_factory=lambda: SecretStr(""), alias="apiKey")
    model: str = ""

    def endpoint(self, route: str) -> str:
        defaults = {
            "gemini": "https://generativelanguage.googleapis.com",
            "anthropic": "https://api.anthropic.com",
        }
        root = self.base_url or defaults.get(self.kind, "")
        parsed = urlsplit(root)
        if (
            parsed.scheme not in ("http", "https")
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
        ):
            raise BackendError(
                "Enter an HTTP or HTTPS endpoint without credentials or query parameters.",
                "invalid_configuration",
            )
        root = root.rstrip("/")
        if self.kind == "openAICompatible":
            explicit_route = root.endswith("/chat/completions")
            root = root.removesuffix("/chat/completions")
            if not urlsplit(root).path and not explicit_route:
                root += "/v1"
        elif self.kind == "gemini" and not root.endswith(("/v1", "/v1beta")):
            root += "/v1beta"
        elif self.kind == "anthropic" and not root.endswith("/v1"):
            root += "/v1"
        return root + "/" + route

    def validate_extraction(self):
        if self.kind == "granite":
            return
        if not self.model:
            raise BackendError("Select a model in Settings.", "invalid_configuration")
        if self.kind in ("gemini", "anthropic") and not self.api_key.get_secret_value():
            raise BackendError(
                "Enter an API key in Settings.", "authentication_required"
            )


class APIProviders:
    def __init__(self, client: httpx.AsyncClient | None = None):
        self.client = client or httpx.AsyncClient(
            timeout=httpx.Timeout(180, connect=15), follow_redirects=False
        )

    async def close(self):
        await self.client.aclose()

    async def request(self, provider: Provider, method: str, route: str, **kwargs):
        headers = {"Accept": "application/json"}
        key = provider.api_key.get_secret_value()
        if key:
            headers[
                {"gemini": "x-goog-api-key", "anthropic": "x-api-key"}.get(
                    provider.kind, "Authorization"
                )
            ] = key if provider.kind in ("gemini", "anthropic") else f"Bearer {key}"
        if provider.kind == "anthropic":
            headers["anthropic-version"] = "2023-06-01"
        url = kwargs.pop("url", None) or provider.endpoint(route)
        for attempt in range(3):
            try:
                response = await self.client.request(
                    method, url, headers=headers, **kwargs
                )
            except httpx.TimeoutException as exc:
                raise BackendError("Provider request timed out.", "timeout") from exc
            except httpx.HTTPError as exc:
                raise BackendError(
                    "Cannot connect to the provider.", "connection_failed"
                ) from exc
            if response.status_code in (429, 502, 503, 504) and attempt < 2:
                await asyncio.sleep(2**attempt)
                continue
            if response.status_code in (401, 403):
                raise BackendError(
                    "The provider rejected the credentials. Check Settings.",
                    "authentication_required",
                )
            if not response.is_success:
                raise BackendError(
                    f"Provider request failed (HTTP {response.status_code}).",
                    "provider_error",
                )
            try:
                return response.json()
            except ValueError as exc:
                raise BackendError(
                    "The provider returned invalid JSON.", "invalid_response"
                ) from exc

    async def infer(self, provider: Provider, image: str, prompt: str) -> str:
        provider.validate_extraction()
        if provider.kind == "gemini":
            result = await self.request(
                provider,
                "POST",
                f"models/{quote(provider.model, safe='')}:generateContent",
                json={
                    "systemInstruction": {"parts": [{"text": prompt}]},
                    "contents": [
                        {
                            "role": "user",
                            "parts": [
                                {
                                    "inline_data": {
                                        "mime_type": "image/png",
                                        "data": image,
                                    }
                                }
                            ],
                        }
                    ],
                    "generationConfig": {"maxOutputTokens": 8192},
                },
            )
            candidates = result.get("candidates", [])
            if not candidates or candidates[0].get("finishReason") not in (
                None,
                "STOP",
            ):
                raise BackendError(
                    "The model could not complete the extraction.",
                    "incomplete_response",
                )
            text = "".join(
                p.get("text", "")
                for p in candidates[0].get("content", {}).get("parts", [])
                if not p.get("thought")
            )
        elif provider.kind == "anthropic":
            result = await self.request(
                provider,
                "POST",
                "messages",
                json={
                    "model": provider.model,
                    "max_tokens": 8192,
                    "system": prompt,
                    "messages": [
                        {
                            "role": "user",
                            "content": [
                                {
                                    "type": "image",
                                    "source": {
                                        "type": "base64",
                                        "media_type": "image/png",
                                        "data": image,
                                    },
                                },
                                {"type": "text", "text": "Extract this image."},
                            ],
                        }
                    ],
                },
            )
            if result.get("stop_reason") not in ("end_turn", "stop_sequence"):
                raise BackendError(
                    "The model could not complete the extraction.",
                    "incomplete_response",
                )
            text = "".join(
                p.get("text", "")
                for p in result.get("content", [])
                if p.get("type") == "text"
            )
        else:
            result = await self.request(
                provider,
                "POST",
                "chat/completions",
                json={
                    "model": provider.model,
                    "messages": [
                        {"role": "system", "content": prompt},
                        {
                            "role": "user",
                            "content": [
                                {
                                    "type": "image_url",
                                    "image_url": {
                                        "url": f"data:image/png;base64,{image}"
                                    },
                                }
                            ],
                        },
                    ],
                },
            )
            choices = result.get("choices", [])
            if not choices or choices[0].get("finish_reason") not in (None, "stop"):
                raise BackendError(
                    "The model could not complete the extraction.",
                    "incomplete_response",
                )
            text = choices[0].get("message", {}).get("content", "")
            if isinstance(text, list):
                text = "".join(
                    p.get("text", "") for p in text if p.get("type") == "text"
                )
        if not isinstance(text, str) or not text.strip():
            raise BackendError(
                "The model returned no extracted content.", "empty_result"
            )
        return text

    async def models(self, provider: Provider) -> list[str]:
        if provider.kind == "granite":
            if not (
                MODEL_ROOT / MODEL_ID.replace("/", "--") / "model.safetensors"
            ).is_file():
                raise BackendError(
                    "The bundled Granite model is missing. Rebuild ScreenScribe.",
                    "model_missing",
                )
            return [MODEL_ID]
        if provider.kind == "gemini":
            models, token, seen = [], None, set()
            while True:
                params = {"pageSize": 1000, **({"pageToken": token} if token else {})}
                result = await self.request(provider, "GET", "models", params=params)
                models.extend(
                    m["name"].removeprefix("models/")
                    for m in result.get("models", [])
                    if "generateContent" in m.get("supportedGenerationMethods", [])
                )
                token = result.get("nextPageToken")
                if not token or token in seen:
                    break
                seen.add(token)
        else:
            result = await self.request(provider, "GET", "models")
            models = [
                m["id"] for m in result.get("data", []) if isinstance(m.get("id"), str)
            ]
            if provider.kind == "anthropic":
                seen = set()
                while result.get("has_more") and result.get("last_id") not in seen:
                    cursor = result.get("last_id")
                    if not cursor:
                        break
                    seen.add(cursor)
                    result = await self.request(
                        provider, "GET", "models", params={"after_id": cursor}
                    )
                    models.extend(
                        m["id"]
                        for m in result.get("data", [])
                        if isinstance(m.get("id"), str)
                    )
            else:
                filtered = inline_vision_models(result.get("data", []))
                if filtered is None:
                    filtered = await self.probe_vision(provider, models)
                if filtered is not None:
                    models = filtered
        if not models:
            raise BackendError(
                "The provider reported no image-capable models.", "no_models"
            )
        return sorted(set(models))

    async def probe_vision(self, provider, model_ids):
        api_root = provider.endpoint("models").removesuffix("/models")
        server_root = (
            api_root[:-3]
            if urlsplit(api_root).path.lower().endswith("/v1")
            else api_root
        )
        for url, key, id_key in (
            (api_root + "/model/info", "data", "model_name"),
            (server_root + "/api/v1/models", "models", "key"),
            (server_root + "/api/v0/models", "data", "id"),
        ):
            try:
                data = await self.request(provider, "GET", "", url=url, timeout=5)
                found = inline_vision_models(data.get(key, []), id_key)
                if found is not None:
                    return found
            except BackendError:
                pass
        found = []
        for model_id in model_ids:
            try:
                data = await self.request(
                    provider,
                    "POST",
                    "",
                    url=server_root + "/api/show",
                    json={"model": model_id},
                    timeout=5,
                )
            except BackendError:
                return None
            if not isinstance(data.get("capabilities"), list):
                return None
            if "vision" in data["capabilities"]:
                found.append(model_id)
        return found if model_ids else None


def inline_vision_models(entries, id_key="id"):
    found, reported = [], False
    for entry in entries:
        vision = None
        if isinstance((entry.get("architecture") or {}).get("input_modalities"), list):
            vision = "image" in entry["architecture"]["input_modalities"]
        elif isinstance((entry.get("capabilities") or {}).get("vision"), bool):
            vision = entry["capabilities"]["vision"]
        elif isinstance((entry.get("model_info") or {}).get("supports_vision"), bool):
            vision = entry["model_info"]["supports_vision"]
        elif "type" in entry:
            vision = entry["type"] == "vlm"
        if vision is not None and isinstance(entry.get(id_key), str):
            reported = True
            if vision:
                found.append(entry[id_key])
    return sorted(set(found)) if reported else None
