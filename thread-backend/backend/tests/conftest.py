"""Shared fixtures.

Every test gets its own empty database file. Nothing in the suite contacts a
language model: tests that need one install `FakeLLM`, and the rest prove
they never ask by running with `NoLLM`, which fails the test if called.
"""

import pytest
from fastapi.testclient import TestClient

from server import llm
from server.main import app
from server.store import session

NOT_AN_IMAGE = "bm90IGFuIGltYWdl"  # base64 of the text "not an image"


class Api:
    """POSTs to /api/<name> and returns the `data` payload."""

    def __init__(self, client: TestClient) -> None:
        self.client = client

    def raw(self, name: str, body: dict | None = None):
        return self.client.post(f"/api/{name}", json=body or {})

    def __call__(self, name: str, body: dict | None = None) -> dict:
        response = self.raw(name, body)
        payload = response.json()
        assert response.status_code == 200, payload
        assert payload["ok"] is True
        return payload["data"]


class FakeLLM:
    """Scripted stand-in for the language model. Records every call."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple]] = []
        self.contact = llm.ContactInfo(name="", org="", interests=[], followups=[], topics=[])
        self.matches = llm.Matches(names=[], reason="nobody fits")
        self.card = llm.Card(headline="Someone you know", lines=["Ask how it went"])
        self.line = "Ask about the launch."
        self.caption_text = "A cleaned caption."
        # The agent's replies, one per step, in order. With none scripted it
        # behaves like a server that can't call tools, so Ask falls back to
        # pick_matches.
        self.turns: list[llm.Turn] = []
        # What the agent was sent at each step: (messages, tool names, finish_with).
        self.agent_steps: list[tuple[list[dict], list[str], str]] = []

    def count(self, name: str) -> int:
        return sum(1 for called, _ in self.calls if called == name)

    def compose(self, *args):
        self.calls.append(("compose", args))
        return llm.Spoken(line=self.line)

    def caption_line(self, *args):
        self.calls.append(("caption_line", args))
        return llm.Caption(language=args[1], text=self.caption_text)

    def extract_contact(self, *args):
        self.calls.append(("extract_contact", args))
        return self.contact

    def lookup_card(self, *args):
        self.calls.append(("lookup_card", args))
        return self.card

    def pick_matches(self, *args):
        self.calls.append(("pick_matches", args))
        return self.matches

    def agent_turn(self, messages, tools, finish_with=""):
        self.calls.append(("agent_turn", ()))
        self.agent_steps.append(
            ([dict(m) for m in messages], [t["function"]["name"] for t in tools], finish_with)
        )
        if not self.turns:
            raise llm.LLMError("this server can't call tools")
        return self.turns.pop(0)


TASKS = ("compose", "caption_line", "extract_contact", "lookup_card", "pick_matches", "agent_turn")
REAL_TASKS = {task: getattr(llm, task) for task in TASKS}


@pytest.fixture(autouse=True)
def isolated(tmp_path, monkeypatch):
    """A fresh database, and a language model that must not be called."""
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    # The defaults, whatever the shell or .env says: a local vLLM server, no key.
    for setting in ("LLM_BASE_URL", "LLM_API_KEY", "LLM_MODEL"):
        monkeypatch.delenv(setting, raising=False)
    for setting in ("OPENAI_API_KEY", "OPENAI_BASE_URL"):
        monkeypatch.delenv(setting, raising=False)

    def forbidden(*_args, **_kwargs):
        raise AssertionError("this test must not call the language model")

    for task in TASKS:
        monkeypatch.setattr(llm, task, forbidden)


@pytest.fixture
def api() -> Api:
    return Api(TestClient(app, raise_server_exceptions=False))


@pytest.fixture
def fake(monkeypatch) -> FakeLLM:
    stand_in = FakeLLM()
    for task in TASKS:
        monkeypatch.setattr(llm, task, getattr(stand_in, task))
    return stand_in


@pytest.fixture
def db():
    """Direct access to the test database, saved when the test ends."""
    with session() as store:
        yield store
