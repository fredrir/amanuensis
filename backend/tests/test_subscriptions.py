from screen_scribe_backend.providers import Provider
from screen_scribe_backend.subscriptions import Subscriptions


class FakeCodex:
    def __init__(self, subscriptions):
        self.subscriptions = subscriptions
        self.calls = []

    async def call(self, method, params=None, **kwargs):
        self.calls.append((method, params))
        if method == "account/read":
            return {"account": {"type": "chatgpt"}}
        if method == "account/login/start":
            assert params["type"] == "chatgpt"
            return {"authUrl": "https://auth.openai.com/test"}
        if method == "thread/start":
            assert params["ephemeral"] is True
            return {"thread": {"id": "test-thread"}}
        if method == "turn/start":
            assert params["input"][1]["url"] == "data:image/png;base64,png"
            for phase, text in [
                ("commentary", "I will extract this"),
                ("final_answer", "# Extracted"),
            ]:
                self.subscriptions.on_notification(
                    "codex",
                    "item/completed",
                    {
                        "threadId": "test-thread",
                        "item": {"type": "agentMessage", "phase": phase, "text": text},
                    },
                )
            self.subscriptions.on_notification(
                "codex",
                "turn/completed",
                {"threadId": "test-thread", "turn": {"status": "completed"}},
            )
        return {}


async def test_codex_subscription_uses_image_input_and_only_final_output(
    tmp_path, monkeypatch
):
    subscriptions = Subscriptions(lambda *args: None, state_root=tmp_path)
    rpc = FakeCodex(subscriptions)

    async def client(kind):
        return rpc

    monkeypatch.setattr(subscriptions, "client", client)
    result = await subscriptions.infer(
        Provider(kind="codex", model="vision"), "png", "extract"
    )
    assert result == "# Extracted"
    assert not subscriptions.codex_turns
    assert rpc.calls[-1][0] == "thread/unsubscribe"


async def test_codex_sign_in_returns_official_client_browser_url(tmp_path, monkeypatch):
    subscriptions = Subscriptions(lambda *args: None, state_root=tmp_path)

    async def client(kind):
        return FakeCodex(subscriptions)

    monkeypatch.setattr(subscriptions, "client", client)
    assert await subscriptions.login("codex") == {
        "url": "https://auth.openai.com/test",
        "pending": True,
    }


async def test_google_sign_in_finishes_asynchronously(tmp_path, monkeypatch):
    events = []
    subscriptions = Subscriptions(
        lambda *event: events.append(event), state_root=tmp_path
    )

    class Google:
        async def call(self, method, params, **kwargs):
            assert method == "authenticate"
            assert params["methodId"] == "oauth-personal"

    async def client(kind):
        return Google()

    monkeypatch.setattr(subscriptions, "client", client)
    assert await subscriptions.login("geminiSubscription") == {"pending": True}
    await subscriptions.login_tasks["geminiSubscription"]
    assert events == [
        ("accountChanged", {"kind": "geminiSubscription", "signedIn": True})
    ]


async def test_gemini_subscription_streams_image_extraction(tmp_path, monkeypatch):
    subscriptions = Subscriptions(lambda *args: None, state_root=tmp_path)

    class Google:
        async def call(self, method, params, **kwargs):
            if method == "session/new":
                return {"sessionId": "test-session"}
            if method == "session/set_model":
                assert params["modelId"] == "vision"
            if method == "session/prompt":
                assert params["prompt"][1] == {
                    "type": "image",
                    "mimeType": "image/png",
                    "data": "png",
                }
                for chunk in ["Hello ", "world"]:
                    subscriptions.on_notification(
                        "geminiSubscription",
                        "session/update",
                        {
                            "sessionId": "test-session",
                            "update": {
                                "sessionUpdate": "agent_message_chunk",
                                "content": {"type": "text", "text": chunk},
                            },
                        },
                    )
                return {"stopReason": "end_turn"}
            return {}

    async def client(kind):
        return Google()

    async def status(kind):
        return {"signedIn": True}

    monkeypatch.setattr(subscriptions, "client", client)
    monkeypatch.setattr(subscriptions, "status", status)
    assert (
        await subscriptions.infer(
            Provider(kind="geminiSubscription", model="vision"), "png", "extract"
        )
        == "Hello world"
    )
    assert not subscriptions.gemini_messages
