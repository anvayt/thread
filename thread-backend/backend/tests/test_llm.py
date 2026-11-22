"""What is sent to the language model, and what is made of its reply.

Nothing here reaches a model server. The OpenAI SDK is real, but its HTTP
client is handed a transport that is a function in this file. (The SDK
uses httpx2, the successor to httpx, so the transport comes from there.)
"""

import json

import httpx2
import pytest
from conftest import REAL_TASKS

from server import llm

SARAH = ("Sarah Chen", "VP Product", "Acme", "met at demo day", "their Series B", "", "")


class ChatServer:
    """Stands in for an OpenAI-compatible chat server (vLLM, or NVIDIA's
    hosted API): records each request and gives the next scripted reply."""

    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.urls: list[str] = []
        self.auth: list[str | None] = []
        self.clients: list[dict] = []
        # The read timeout each request was sent with, in seconds.
        self.timeouts: list[float | None] = []
        self.replies: list[httpx2.Response | str | None] = []

    def will_answer(self, text: str | None, finish_reason: str = "stop") -> None:
        self.replies.append(
            httpx2.Response(
                200,
                json={
                    "id": "chatcmpl-test",
                    "object": "chat.completion",
                    "created": 0,
                    "model": llm.DEFAULT_MODEL,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": text},
                            "finish_reason": finish_reason,
                        }
                    ],
                },
            )
        )

    def will_call(self, *calls: tuple[str, str]) -> None:
        """Reply with tool calls: (name, arguments as sent, a JSON string)."""
        self.replies.append(
            httpx2.Response(
                200,
                json={
                    "id": "chatcmpl-test",
                    "object": "chat.completion",
                    "created": 0,
                    "model": llm.DEFAULT_MODEL,
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": None,
                                "tool_calls": [
                                    {"id": f"call-{n}", "type": "function",
                                     "function": {"name": name, "arguments": args}}
                                    for n, (name, args) in enumerate(calls)
                                ],  # fmt: skip
                            },
                            "finish_reason": "tool_calls",
                        }
                    ],
                },
            )
        )

    def will_refuse(self, code: int, message: str) -> None:
        self.replies.append(
            httpx2.Response(
                code, json={"error": {"message": message, "type": "BadRequestError", "code": code}}
            )
        )

    def will_not_answer(self) -> None:
        self.replies.append(None)

    def will_stall(self) -> None:
        """Take the request, then answer nothing before the client gives up."""
        self.replies.append("stall")

    def __call__(self, request: httpx2.Request) -> httpx2.Response:
        self.requests.append(json.loads(request.content))
        self.urls.append(str(request.url))
        self.auth.append(request.headers.get("authorization"))
        self.timeouts.append(request.extensions.get("timeout", {}).get("read"))
        reply = self.replies.pop(0)
        if reply is None:
            raise httpx2.ConnectError("connection refused", request=request)
        if reply == "stall":
            raise httpx2.ReadTimeout("timed out", request=request)
        return reply

    @property
    def schema(self) -> dict:
        return self.requests[0]["response_format"]["json_schema"]["schema"]

    def message(self, role: str, n: int = 0) -> str:
        [content] = [m["content"] for m in self.requests[n]["messages"] if m["role"] == role]
        return content


@pytest.fixture
def server(monkeypatch) -> ChatServer:
    stand_in = ChatServer()
    http = httpx2.Client(transport=httpx2.MockTransport(stand_in))
    real_client = llm.openai.OpenAI

    def client(**options):
        stand_in.clients.append(options)
        return real_client(**options, http_client=http)

    monkeypatch.setattr(llm.openai, "OpenAI", client)
    monkeypatch.setattr(llm, "_clients", {})
    return stand_in


def test_a_task_sends_its_inputs_and_answer_shape_and_returns_the_answer(server):
    server.will_answer('{"line": "Ask about the launch."}')

    said = REAL_TASKS["compose"](*SARAH)

    assert said == llm.Spoken(line="Ask about the launch.")
    [sent] = server.requests
    assert sent["model"] == llm.DEFAULT_MODEL == "nvidia/nemotron-3.5-lightning-30b-a3b"
    assert [m["role"] for m in sent["messages"]] == ["system", "user"]
    assert "whispered into the wearer's earpiece" in server.message("system")
    assert "- name: The recognised person's name." in server.message("system")
    assert "<name>\nSarah Chen\n</name>" in server.message("user")
    assert sent["response_format"]["type"] == "json_schema"
    assert sent["response_format"]["json_schema"]["name"] == "Spoken"
    assert server.schema["required"] == ["line"]


def test_the_answer_shape_is_also_stated_in_the_system_message(server):
    server.will_answer('{"line": "Ask about the launch."}')
    REAL_TASKS["compose"](*SARAH)
    assert json.dumps(server.schema) in server.message("system")


def test_every_task_asks_for_an_answer_without_thinking_first(server):
    server.will_answer('{"line": "Ask about the launch."}')
    REAL_TASKS["compose"](*SARAH)
    assert server.requests[0]["chat_template_kwargs"] == {"enable_thinking": False}


def test_requests_go_to_a_local_vllm_server_by_default_with_no_key(server):
    server.will_answer('{"line": "Ask about the launch."}')
    REAL_TASKS["compose"](*SARAH)
    assert server.urls == ["http://127.0.0.1:8001/v1/chat/completions"]
    # vLLM started without --api-key accepts any; this is its docs' placeholder.
    assert server.auth == ["Bearer EMPTY"]


def test_the_client_gives_up_after_45_seconds_and_does_not_retry_on_its_own(server):
    server.will_answer('{"line": "Ask about the launch."}')
    REAL_TASKS["compose"](*SARAH)
    [options] = server.clients
    assert options["timeout"] == 45
    assert options["max_retries"] == 0


def test_llm_base_url_and_llm_api_key_point_it_at_nvidias_hosted_api(server, monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://integrate.api.nvidia.com/v1")
    monkeypatch.setenv("LLM_API_KEY", "nvapi-test")
    server.will_answer('{"line": "Ask about the launch."}')

    REAL_TASKS["compose"](*SARAH)

    assert server.urls == ["https://integrate.api.nvidia.com/v1/chat/completions"]
    assert server.auth == ["Bearer nvapi-test"]


def test_openai_settings_in_the_shell_are_not_used(server, monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "a-key-for-something-else")
    monkeypatch.setenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
    server.will_answer('{"line": "Ask about the launch."}')

    REAL_TASKS["compose"](*SARAH)

    assert server.urls == ["http://127.0.0.1:8001/v1/chat/completions"]
    assert server.auth == ["Bearer EMPTY"]


def test_the_hosted_api_without_a_key_is_reported_and_not_called(server, monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://integrate.api.nvidia.com/v1")

    assert not llm.available()
    with pytest.raises(llm.LLMError, match="LLM_API_KEY is not set"):
        REAL_TASKS["compose"](*SARAH)
    assert server.requests == []


def test_llm_model_overrides_the_default_model(server, monkeypatch):
    monkeypatch.setenv("LLM_MODEL", "some-other-model")
    server.will_answer('{"line": "Ask about the launch."}')
    REAL_TASKS["compose"](*SARAH)
    assert server.requests[0]["model"] == "some-other-model"


def test_an_optional_field_is_sent_without_a_default_and_may_be_left_out(server):
    server.will_answer(
        '{"name": "Dana", "org": "Ledgerloop", "interests": [], "followups": [], "topics": []}'
    )

    info = REAL_TASKS["extract_contact"]("Hi, I'm Dana from Ledgerloop.")

    assert info.role == ""
    assert "role" in server.schema["properties"]
    assert "role" not in server.schema["required"]
    assert server.schema["required"] == ["name", "org", "interests", "followups", "topics"]
    assert "default" not in json.dumps(server.schema)


def test_a_cut_off_answer_is_asked_for_again_with_twice_the_room(server):
    server.will_answer('{"line": "Ask ab', finish_reason="length")
    server.will_answer('{"line": "Ask about the launch."}')

    said = REAL_TASKS["compose"](*SARAH)

    assert said.line == "Ask about the launch."
    first, second = (r["max_tokens"] for r in server.requests)
    assert second == 2 * first


def test_an_answer_cut_off_twice_is_reported_not_returned(server):
    server.will_answer('{"line": "Ask ab', finish_reason="length")
    server.will_answer('{"line": "Ask about the la', finish_reason="length")

    with pytest.raises(llm.LLMError, match="stopped early: length"):
        REAL_TASKS["compose"](*SARAH)


def test_an_answer_that_does_not_fit_the_shape_is_reported_not_returned(server):
    server.will_answer('{"sentence": "Ask about the launch."}')
    server.will_answer('{"sentence": "Ask about the launch."}')

    with pytest.raises(llm.LLMError, match="1 field\\(s\\) missing or malformed"):
        REAL_TASKS["compose"](*SARAH)


def test_an_empty_reply_is_reported_as_empty(server):
    server.will_answer(None)
    server.will_answer("")

    with pytest.raises(llm.LLMError, match="the reply was empty"):
        REAL_TASKS["compose"](*SARAH)


def test_a_refused_request_is_reported_with_the_servers_reason_and_not_retried(server):
    server.will_refuse(400, "The model `nvidia/nemotron` does not exist.")

    with pytest.raises(llm.LLMError, match="request failed.*400.*does not exist"):
        REAL_TASKS["compose"](*SARAH)

    assert len(server.requests) == 1


def test_a_server_that_is_not_running_is_reported_plainly_and_named_in_the_log(
    server, caplog
):
    server.will_not_answer()

    with pytest.raises(llm.LLMError, match="Nemotron isn't answering right now") as err:
        REAL_TASKS["compose"](*SARAH)

    assert err.value.unreachable
    assert "nothing answered at http://127.0.0.1:8001/v1" in caplog.text
    assert len(server.requests) == 1


# ------------------------------------------------------------- time limits


@pytest.mark.parametrize(
    ("task", "args", "reply"),
    [
        ("compose", SARAH, '{"line": "Ask about the launch."}'),
        ("caption_line", ("hello there", "en"), '{"language": "en", "text": "Hello there."}'),
        ("extract_contact", ("I'm Sarah.",), '{"name": "Sarah", "org": "", "role": "", '
                                             '"interests": [], "followups": [], "topics": []}'),
        ("lookup_card", ("Sarah", "", "", "", "", ""), '{"headline": "Sarah", "lines": []}'),
        ("pick_matches", ("who?", "Sarah | | | | |"), '{"names": [], "reason": "nobody"}'),
        ("draft_followup", ("Sarah", "", "", "", "", "", "", "", ""), '{"message": "Hi Sarah."}'),
    ],
)  # fmt: skip
def test_every_task_is_sent_with_its_own_time_limit(server, task, args, reply):
    server.will_answer(reply)
    REAL_TASKS[task](*args)
    [sent] = server.timeouts
    assert llm.SECONDS[task] - 1 < sent <= llm.SECONDS[task]


def test_a_server_that_stops_answering_is_given_up_on_and_not_asked_again(server):
    server.will_stall()

    with pytest.raises(llm.LLMError, match="didn't answer within 8 seconds") as err:
        REAL_TASKS["compose"](*SARAH)

    assert err.value.unreachable
    assert len(server.requests) == 1


def test_a_failing_model_server_is_reported_as_down(server):
    server.will_refuse(500, "EngineCore encountered an issue.")

    with pytest.raises(llm.LLMError, match="had a problem answering \\(500\\)") as err:
        REAL_TASKS["compose"](*SARAH)

    assert err.value.unreachable
    assert len(server.requests) == 1


def test_a_refused_request_is_not_taken_for_a_server_that_is_down(server):
    server.will_refuse(400, "The model `nvidia/nemotron` does not exist.")
    with pytest.raises(llm.LLMError) as err:
        REAL_TASKS["compose"](*SARAH)
    assert not err.value.unreachable


def test_the_second_try_gets_only_the_time_that_is_left(server, monkeypatch):
    clock = iter([100.0, 100.0, 105.5])  # start, first try, second try
    monkeypatch.setattr(llm.time, "monotonic", lambda: next(clock))
    server.will_answer("not json")
    server.will_answer('{"line": "Ask about the launch."}')

    REAL_TASKS["compose"](*SARAH)

    assert server.timeouts == [8.0, 2.5]


def test_with_under_a_second_left_there_is_no_second_try(server, monkeypatch):
    clock = iter([100.0, 100.0, 107.5])
    monkeypatch.setattr(llm.time, "monotonic", lambda: next(clock))
    server.will_answer("not json")

    with pytest.raises(llm.LLMError, match="unusable answer"):
        REAL_TASKS["compose"](*SARAH)

    assert len(server.requests) == 1


# -------------------------------------------------------------------- agent

TOOLS = [{"type": "function", "function": {"name": "person", "parameters": {"type": "object"}}}]


def test_an_agent_step_offers_the_tools_and_lets_the_model_choose(server):
    server.will_call(("person", '{"name": "Sarah"}'), ("promises", "{}"))
    turn = REAL_TASKS["agent_turn"]([{"role": "user", "content": "q"}], TOOLS)

    sent = server.requests[0]
    assert sent["tools"] == TOOLS
    assert sent["tool_choice"] == "auto"
    assert sent["chat_template_kwargs"] == {"enable_thinking": False}
    assert [(c.id, c.name, c.args) for c in turn.calls] == [
        ("call-0", "person", {"name": "Sarah"}),
        ("call-1", "promises", {}),
    ]


def test_the_last_agent_step_must_call_the_tool_that_answers(server):
    server.will_call(("answer", '{"text": "t", "people": []}'))
    REAL_TASKS["agent_turn"]([{"role": "user", "content": "q"}], TOOLS, finish_with="answer")
    assert server.requests[0]["tool_choice"] == {"type": "function", "function": {"name": "answer"}}


def test_tool_arguments_that_are_not_an_object_come_back_empty(server):
    server.will_call(("person", "not json"), ("person", "[1, 2]"))
    turn = REAL_TASKS["agent_turn"]([{"role": "user", "content": "q"}], TOOLS)
    assert [c.args for c in turn.calls] == [{}, {}]


def test_a_server_that_cannot_call_tools_is_reported(server):
    server.will_refuse(400, '"auto" tool choice requires --enable-auto-tool-choice')
    with pytest.raises(llm.LLMError, match="enable-auto-tool-choice"):
        REAL_TASKS["agent_turn"]([{"role": "user", "content": "q"}], TOOLS)


def test_the_follow_up_draft_is_told_to_stay_on_the_record(server):
    server.will_answer('{"message": "Hi Renata, good to meet you."}')

    draft = REAL_TASKS["draft_followup"](
        "Renata Okoye", "University Recruiter", "Brightfern AI", "ML internships",
        "send them the resume", "", "", "ML internships", "", "",
    )  # fmt: skip

    assert draft == llm.FollowUp(message="Hi Renata, good to meet you.")
    system = server.message("system")
    assert "never add a fact" in system
    assert "Under 80 words" in system and "no placeholders" in system
    assert "<you_owe>\nsend them the resume\n</you_owe>" in server.message("user")
    assert server.requests[0]["response_format"]["json_schema"]["name"] == "FollowUp"


def test_an_agent_step_is_sent_with_the_time_it_is_given(server):
    server.will_call(("answer", '{"text": "t", "people": []}'))
    REAL_TASKS["agent_turn"]([{"role": "user", "content": "q"}], TOOLS, seconds=3.5)
    assert server.timeouts == [3.5]
