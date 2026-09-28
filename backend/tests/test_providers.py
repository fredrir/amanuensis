import json

import httpx
import pytest

from screen_scribe_backend.config import BackendError
from screen_scribe_backend.providers import APIProviders, Provider, inline_vision_models


@pytest.mark.parametrize(
    ("endpoint", "expected"),
    [
        ("https://example.com", "https://example.com/v1/chat/completions"),
        (
            "https://example.com/chat/completions",
            "https://example.com/chat/completions",
        ),
        (
            "https://example.com/proxy/v1/",
            "https://example.com/proxy/v1/chat/completions",
        ),
        (
            "http://localhost:1234/v1/chat/completions",
            "http://localhost:1234/v1/chat/completions",
        ),
    ],
)
def test_custom_endpoints_preserve_proxy_paths(endpoint, expected):
    assert (
        Provider(kind="openAICompatible", baseURL=endpoint).endpoint("chat/completions")
        == expected
    )


@pytest.mark.parametrize(
    "endpoint",
    [
        "ftp://example.com",
        "https://key:secret@example.com",
        "https://example.com?key=secret",
        "file:///etc/passwd",
    ],
)
def test_invalid_endpoints_are_rejected(endpoint):
    with pytest.raises(BackendError, match="endpoint"):
        Provider(kind="openAICompatible", baseURL=endpoint).endpoint("models")


async def test_vision_discovery_preserves_reverse_proxy_prefix():
    paths = []

    def respond(request):
        paths.append(request.url.path)
        if request.url.path == "/proxy/v1/models":
            return httpx.Response(
                200, json={"data": [{"id": "vision"}, {"id": "text"}]}
            )
        if request.url.path == "/proxy/api/v1/models":
            return httpx.Response(
                200,
                json={
                    "models": [
                        {"key": "vision", "capabilities": {"vision": True}},
                        {"key": "text", "capabilities": {"vision": False}},
                    ]
                },
            )
        return httpx.Response(404)

    client = APIProviders(httpx.AsyncClient(transport=httpx.MockTransport(respond)))
    try:
        assert await client.models(
            Provider(kind="openAICompatible", baseURL="https://example.com/proxy/v1")
        ) == ["vision"]
        assert all(path.startswith("/proxy/") for path in paths)
    finally:
        await client.close()


@pytest.mark.parametrize("kind", ["gemini", "anthropic", "openAICompatible"])
async def test_provider_receives_image_model_and_backend_prompt(kind):
    async def handler(request):
        body = json.loads(request.content)
        assert "private-key" not in str(request.url)
        if kind == "gemini":
            assert request.headers["x-goog-api-key"] == "private-key"
            assert request.url.path.endswith("/models/vision:generateContent")
            assert (
                body["contents"][0]["parts"][0]["inline_data"]["data"] == "image-data"
            )
            assert body["systemInstruction"]["parts"][0]["text"] == "extract-prompt"
            return httpx.Response(
                200,
                json={
                    "candidates": [
                        {
                            "finishReason": "STOP",
                            "content": {
                                "parts": [
                                    {"text": "thinking", "thought": True},
                                    {"text": "Hello"},
                                ]
                            },
                        }
                    ]
                },
            )
        if kind == "anthropic":
            assert request.headers["x-api-key"] == "private-key"
            assert body["model"] == "vision"
            assert body["messages"][0]["content"][0]["source"]["data"] == "image-data"
            return httpx.Response(
                200,
                json={
                    "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": "Hello"}],
                },
            )
        assert request.headers["authorization"] == "Bearer private-key"
        assert (
            body["messages"][1]["content"][0]["image_url"]["url"]
            == "data:image/png;base64,image-data"
        )
        return httpx.Response(
            200,
            json={
                "choices": [{"finish_reason": "stop", "message": {"content": "Hello"}}]
            },
        )

    client = APIProviders(httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    try:
        provider = Provider(
            kind=kind,
            baseURL="https://example.com",
            apiKey="private-key",
            model="vision",
        )
        assert await client.infer(provider, "image-data", "extract-prompt") == "Hello"
    finally:
        await client.close()


async def test_rejected_credentials_do_not_leak_provider_diagnostics():
    client = APIProviders(
        httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda request: httpx.Response(
                    401, json={"error": {"message": "private-key"}}
                )
            )
        )
    )
    try:
        with pytest.raises(BackendError) as raised:
            await client.models(Provider(kind="anthropic", apiKey="private-key"))
        assert raised.value.code == "authentication_required"
        assert "private-key" not in str(raised.value)
    finally:
        await client.close()


async def test_truncated_response_is_not_copied_as_complete_content():
    client = APIProviders(
        httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda request: httpx.Response(
                    200,
                    json={
                        "choices": [
                            {
                                "finish_reason": "length",
                                "message": {"content": "partial"},
                            }
                        ]
                    },
                )
            )
        )
    )
    try:
        with pytest.raises(BackendError) as raised:
            await client.infer(
                Provider(
                    kind="openAICompatible",
                    baseURL="http://localhost:1234/v1",
                    model="vision",
                ),
                "data",
                "prompt",
            )
        assert raised.value.code == "incomplete_response"
    finally:
        await client.close()


async def test_gemini_model_discovery_paginates_and_excludes_embedding_models():
    def respond(request):
        if request.url.params.get("pageToken") == "next":
            return httpx.Response(
                200,
                json={
                    "models": [
                        {
                            "name": "models/vision-2",
                            "supportedGenerationMethods": ["generateContent"],
                        }
                    ]
                },
            )
        return httpx.Response(
            200,
            json={
                "models": [
                    {
                        "name": "models/vision-1",
                        "supportedGenerationMethods": ["generateContent"],
                    },
                    {
                        "name": "models/embed",
                        "supportedGenerationMethods": ["embedContent"],
                    },
                ],
                "nextPageToken": "next",
            },
        )

    client = APIProviders(httpx.AsyncClient(transport=httpx.MockTransport(respond)))
    try:
        assert await client.models(Provider(kind="gemini", apiKey="key")) == [
            "vision-1",
            "vision-2",
        ]
    finally:
        await client.close()


@pytest.mark.parametrize(
    ("entries", "expected"),
    [
        ([{"id": "unknown"}], None),
        ([{"id": "text", "capabilities": {"vision": False}}], []),
        (
            [
                {
                    "id": "image",
                    "architecture": {"input_modalities": ["text", "image"]},
                },
                {"id": "text", "architecture": {"input_modalities": ["text"]}},
            ],
            ["image"],
        ),
        ([{"id": "image", "model_info": {"supports_vision": True}}], ["image"]),
    ],
)
def test_model_capabilities_distinguish_unknown_from_unsupported(entries, expected):
    assert inline_vision_models(entries) == expected
