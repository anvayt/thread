"""Language tasks.

Each function hands the model a task, named inputs and an answer shape, and
gets back a validated object. The model is forced to answer by filling that
shape, so a conversational reply ("I need more input to...") can never reach
the display; an answer that does not fit is asked for once more, then
reported as a failure.

The model is NVIDIA Nemotron, reached through any OpenAI-compatible chat
endpoint: a vLLM server of your own (the default), or NVIDIA's hosted API.

Callers reach these through the module (`llm.compose(...)`) so tests can
substitute fakes.
"""

import json
import os
from dataclasses import dataclass, field
from urllib.parse import urlsplit

import openai
from pydantic import BaseModel, Field, ValidationError
from pydantic.json_schema import GenerateJsonSchema

# A vLLM server on this machine. Started with
# `--served-model-name nvidia/nemotron-3.5-lightning-30b-a3b`, it answers to
# the same model name as NVIDIA's hosted API, so one default fits both.
DEFAULT_BASE_URL = "http://127.0.0.1:8001/v1"

# Nemotron 3.5 Lightning 30B-A3B, by the name NVIDIA's API catalog gives it.
DEFAULT_MODEL = "nvidia/nemotron-3.5-lightning-30b-a3b"


class LLMError(RuntimeError):
    """The language model could not be reached or did not give a usable answer."""


# ------------------------------------------------------------ answer shapes


class Spoken(BaseModel):
    line: str = Field(
        description="The whisper itself: under 20 words, no greeting, no preamble, "
        "no lead-in like 'This is'. Speak it the way a friend would lean in and say it."
    )


class Caption(BaseModel):
    language: str = Field(
        description="The ISO code of the language you wrote `text` in. This MUST equal "
        "the requested target language. Naming it first is what stops the caption "
        "coming back untranslated."
    )
    text: str = Field(
        description="The caption to put on screen, written in the target language. It "
        "is always the speech itself - cleaned up, and translated when the target "
        "language differs from the language spoken. Never a question back to the user, "
        "never a request for input, never an explanation. If the input is too short or "
        "garbled to improve, return it as-is rather than commenting on it."
    )


class ContactInfo(BaseModel):
    name: str = Field(
        description="The speaker's name if they introduce themselves. Empty string if "
        "never stated - never guess a name."
    )
    role: str = Field(
        default="",
        description="Their job title if they state it. Empty if not stated.",
    )
    org: str = Field(
        description="The company or organisation they say they are with. Empty if not stated."
    )
    interests: list[str] = Field(
        description="What they are into, working on, or care about. Short noun phrases."
    )
    followups: list[str] = Field(
        description="Anything either person promised to do or send. Short imperative "
        "phrases, e.g. 'send them the repo link'. Empty list if nothing was promised."
    )
    topics: list[str] = Field(
        description="Two to five short subject labels for what was discussed, e.g. "
        "'fintech', 'Series B', 'rock climbing'."
    )


class Card(BaseModel):
    headline: str = Field(
        description="One line identifying the person: name, then org or how you know "
        "them. Under 12 words."
    )
    lines: list[str] = Field(
        description="Two to four short bullets: what you last discussed, what you owe "
        "them, and one thing worth asking about now. Each under 15 words. Concrete "
        "details only - never filler like 'catch up soon'."
    )


class Matches(BaseModel):
    names: list[str] = Field(
        description="Names of the people who match the question, best first. Empty "
        "list if none do."
    )
    reason: str = Field(
        description="One short sentence explaining the selection. Under 20 words."
    )


class FollowUp(BaseModel):
    message: str = Field(
        description="The message itself, ready to paste and send: plain text, first "
        "person, under 80 words. No subject line, no Markdown, and no placeholders "
        "such as '[Your Name]'."
    )


# ---------------------------------------------------------------- transport

_clients: dict = {}


def endpoint() -> str:
    """The base URL of the chat completions API the tasks are sent to."""
    return os.environ.get("LLM_BASE_URL") or DEFAULT_BASE_URL


def model_name() -> str:
    return os.environ.get("LLM_MODEL") or DEFAULT_MODEL


def _api_key() -> str:
    return os.environ.get("LLM_API_KEY") or ""


def _needs_key(url: str) -> bool:
    """NVIDIA's hosted API refuses requests without a key. A vLLM server
    started without `--api-key` takes any."""
    host = urlsplit(url).hostname or ""
    return host == "api.nvidia.com" or host.endswith(".api.nvidia.com")


def available() -> bool:
    """Whether a request can be attempted. It may still find nothing answering."""
    return bool(_api_key()) or not _needs_key(endpoint())


def _client() -> openai.OpenAI:
    base_url, key = endpoint(), _api_key()
    if not available():
        raise LLMError(
            f"LLM_API_KEY is not set on the server, and {base_url} needs one to "
            "write language. Add it to backend/.env and restart."
        )
    if (base_url, key) not in _clients:
        _clients[(base_url, key)] = openai.OpenAI(
            # Both passed explicitly: left to itself the SDK reads
            # OPENAI_BASE_URL and OPENAI_API_KEY, which may be set in the shell
            # for OpenAI's own service. "EMPTY" is the placeholder vLLM's docs
            # use for a server that checks no key.
            base_url=base_url,
            api_key=key or "EMPTY",
            timeout=45,
            # One attempt per call: `_ask` decides what is worth asking again.
            max_retries=0,
        )
    return _clients[(base_url, key)]


def _complete(**request):
    """Send one chat completion request, reporting a failure as LLMError."""
    try:
        return _client().chat.completions.create(
            model=model_name(),
            # Nemotron reasons before answering unless told not to. These
            # tasks are short and the wearer is waiting.
            extra_body={"chat_template_kwargs": {"enable_thinking": False}},
            **request,
        )
    except openai.APIError as err:
        hint = ""
        if isinstance(err, openai.APIConnectionError) and not isinstance(
            err, openai.APITimeoutError
        ):
            hint = f" Nothing answered at {endpoint()}; is the model server running?"
        raise LLMError(f"The language model request failed: {err}{hint}") from err


class _NoDefaults(GenerateJsonSchema):
    """Leaves `default` out of a schema. The model never sees a default
    applied, and leaving it out keeps to the part of JSON Schema that every
    structured-output engine handles."""

    def default_schema(self, schema):
        return self.generate_inner(schema["schema"])


def _ask[T: BaseModel](
    shape: type[T],
    task: str,
    inputs: list[tuple[str, str, str]],
    *,
    temperature: float,
    max_tokens: int,
) -> T:
    """Run one task. `inputs` is (name, what it is, value) for each input."""
    _client()  # a missing key is reported before any work is done
    schema = shape.model_json_schema(schema_generator=_NoDefaults)
    described = "\n".join(f"- {name}: {what}" for name, what, _ in inputs)
    # The schema is also stated in words, for an endpoint that ignores
    # `response_format` rather than enforcing it.
    system = (
        f"{task}\n\nYou are given:\n{described}\n\n"
        "Answer with a single JSON object and nothing else. It must match this "
        f"JSON Schema:\n{json.dumps(schema)}"
    )
    user = "\n\n".join(f"<{name}>\n{value}\n</{name}>" for name, _, value in inputs)

    problem = "no answer"
    for attempt in range(2):
        reply = _complete(
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            # The server constrains decoding to this schema, so the reply
            # is the object itself.
            response_format={
                "type": "json_schema",
                "json_schema": {"name": shape.__name__, "schema": schema},
            },
            temperature=temperature,
            # A cut-off answer is the usual reason for a retry; give the
            # second attempt room to finish.
            max_tokens=max_tokens * (attempt + 1),
        )

        choice = reply.choices[0] if reply.choices else None
        text = (choice.message.content if choice else None) or ""
        try:
            return shape.model_validate_json(text)
        except ValidationError as err:
            finish = choice.finish_reason if choice else None
            if finish not in (None, "stop"):
                problem = f"it stopped early: {finish}"
            elif not text:
                problem = "the reply was empty"
            else:
                problem = f"{err.error_count()} field(s) missing or malformed"

    raise LLMError(f"The language model gave an unusable answer ({problem}).")


# -------------------------------------------------------------------- tasks


def compose(
    name: str, role: str, org: str, relationship: str, last: str, notes: str, history: str
) -> Spoken:
    return _ask(
        Spoken,
        "Write one short line to be whispered into the wearer's earpiece, reminding "
        "them who they are looking at and surfacing the single most useful thing to "
        "raise right now. Prefer a concrete, specific detail over a generic greeting. "
        "Never use gendered pronouns for the person - their pronouns are not recorded "
        "and guessing wrong is worse than not knowing. Use their name, or 'they', or "
        "rewrite the line to need no pronoun at all.",
        [
            ("name", "The recognised person's name.", name),
            ("role", "Their job title, may be empty.", role),
            ("org", "The organisation they belong to, may be empty.", org),
            ("relationship", "How the wearer knows them.", relationship),
            ("last", "What happened at the last interaction.", last),
            ("notes", "Free-form notes the wearer keeps about them.", notes),
            (
                "history",
                "Summaries of recent prior encounters, most recent first. May be empty.",
                history,
            ),
        ],
        temperature=0.3,
        max_tokens=80,
    )


def caption_line(heard: str, lang: str) -> Caption:
    return _ask(
        Caption,
        "Clean up one chunk of live speech-to-text for display on a heads-up screen: "
        "fix obvious mis-transcriptions, add punctuation, drop filler words. If the "
        "target language differs from the language spoken, translate into it. The "
        "input is always real captured speech, however odd it looks - caption it, do "
        "not ask for clarification.",
        [
            ("heard", "The captured speech to clean up.", heard),
            (
                "lang",
                "The language the caption MUST be written in, as an ISO code ('en', "
                "'es', 'fr', 'de', 'ja'). If the speech is in a different language, "
                "translate it. The wearer reads only this language.",
                lang,
            ),
        ],
        temperature=0.0,
        max_tokens=200,
    )


def extract_contact(transcript: str, wearer: str = "") -> ContactInfo:
    fields = [
        (
            "transcript",
            "A transcript of what was just said, possibly by both people.",
            transcript,
        )
    ]
    if wearer:
        fields.append(
            (
                "wearer",
                "The name of the person wearing the glasses. They are not the contact: "
                "never return this name, or part of it, as the contact's name.",
                wearer,
            )
        )
    return _ask(
        ContactInfo,
        "Pull structured contact details out of a snippet of conversation at a "
        "networking event. Record only what was actually said - leave fields empty "
        "rather than inferring. Never guess a name from a voice.",
        fields,
        temperature=0.0,
        max_tokens=500,
    )


def lookup_card(
    name: str, org: str, relationship: str, interests: str, followups: str, history: str
) -> Card:
    return _ask(
        Card,
        "Build the card shown on the wearer's display when they need reminding who "
        "someone is. Ground every line in the recorded history - never invent a "
        "detail. Never use gendered pronouns for the person: their pronouns are not "
        "recorded and guessing wrong is worse than not knowing. Use their name, "
        "'they', or rewrite to avoid the pronoun.",
        [
            ("name", "The person's name.", name),
            ("org", "The organisation they belong to, may be empty.", org),
            ("relationship", "How the wearer knows them. May be empty.", relationship),
            (
                "interests",
                "What they are known to be into, comma separated. May be empty.",
                interests,
            ),
            ("followups", "Outstanding promises, comma separated. May be empty.", followups),
            (
                "history",
                "Past interactions, newest first, as 'date - what was discussed'. May be empty.",
                history,
            ),
        ],
        temperature=0.3,
        max_tokens=400,
    )


def pick_matches(question: str, roster: str) -> Matches:
    return _ask(
        Matches,
        "Answer a question about who the wearer has met by choosing from the roster. "
        "Select only people the roster actually supports - an empty list is the "
        "correct answer when nobody fits.",
        [
            ("question", "A free-text question, e.g. 'who did I meet in fintech?'.", question),
            (
                "roster",
                "Everyone known, one per line, as 'Name | role | org | interests | "
                "topics discussed | last interaction'. Any field may be empty.",
                roster,
            ),
        ],
        temperature=0.0,
        max_tokens=400,
    )


def draft_followup(
    name: str, role: str, org: str, topics: str,
    you_owe: str, they_owe: str, other: str, last: str, heard: str, wearer: str = "",
) -> FollowUp:  # fmt: skip
    return _ask(
        FollowUp,
        "Write the short follow-up message the wearer sends this person after meeting "
        "them at a career fair or conference, the kind sent on LinkedIn. Write as the "
        "wearer, in the first person, to the person by their first name. Use only what "
        "is given: never add a fact, a date, a link, a job or a promise that is not "
        "there. Keep what the wearer promised and what the person promised the right "
        "way round. If almost nothing is given, write a brief, plain note saying it "
        "was good to meet them, and nothing more. Under 80 words, plain text, no "
        "subject line, no Markdown, and no placeholders in brackets. Sign off with the "
        "wearer's name only when one is given.",
        [
            ("name", "The person the message is to.", name),
            ("role", "Their job title, may be empty.", role),
            ("org", "The organisation they belong to, may be empty.", org),
            ("topics", "What the two talked about, comma separated. May be empty.", topics),
            (
                "you_owe",
                "What the wearer said they would do for this person, one per line. "
                "May be empty.",
                you_owe,
            ),
            (
                "they_owe",
                "What this person said they would do for the wearer, one per line. "
                "May be empty.",
                they_owe,
            ),
            (
                "other",
                "Follow-ups where the record doesn't say who promised them, one per "
                "line. Mention them without saying who owes them. May be empty.",
                other,
            ),
            ("last", "What the last conversation was about, in a few words. May be empty.", last),
            ("heard", "The last conversation as it was heard. May be empty.", heard),
            ("wearer", "The wearer's own name, to sign off with. May be empty.", wearer),
        ],
        temperature=0.3,
        max_tokens=300,
    )


# ------------------------------------------------------------------- agent


@dataclass
class ToolCall:
    """One tool the model asked to use, with its arguments already parsed.
    Arguments that are not a JSON object come back as an empty dict."""

    id: str
    name: str
    args: dict = field(default_factory=dict)


@dataclass
class Turn:
    """One reply from the model in an agent conversation."""

    content: str = ""
    calls: list[ToolCall] = field(default_factory=list)


def agent_turn(messages: list[dict], tools: list[dict], *, finish_with: str = "") -> Turn:
    """One step of an agent: the conversation so far and the tools on offer
    go to the model, which calls one or more of them or replies in words.
    With `finish_with`, it must call that tool, which ends the conversation.
    The choice is otherwise left to the model ("auto"): requiring a call
    makes the server constrain every token to a JSON shape, which is several
    times slower and no better.

    This needs a server that does tool calling: vLLM started with
    `--enable-auto-tool-choice --tool-call-parser qwen3_coder`, or NVIDIA's
    hosted API. Anything else is reported as LLMError, and the caller falls
    back to a single question.
    """
    choice = {"type": "function", "function": {"name": finish_with}} if finish_with else "auto"
    reply = _complete(
        messages=messages,
        tools=tools,
        tool_choice=choice,
        temperature=0.0,
        max_tokens=500,
    )
    if not reply.choices:
        raise LLMError("The language model gave an empty reply.")
    message = reply.choices[0].message
    calls = []
    for call in message.tool_calls or []:
        try:
            args = json.loads(call.function.arguments or "{}")
        except json.JSONDecodeError:
            args = {}
        calls.append(
            ToolCall(id=call.id, name=call.function.name, args=args if isinstance(args, dict) else {})
        )
    return Turn(content=message.content or "", calls=calls)
