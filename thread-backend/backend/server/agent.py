"""Ask: Nemotron as an agent over the people you have met.

A question goes to the model with an outline of the network and a set of
read-only tools: search everyone, read one person's page, see who someone
connects to and through what, see who talked about a topic, list recent
meetings, list open promises. The model calls them as it sees fit, a few
rounds at most, and finishes by calling `answer` with what to say, who it is
about and how they connect.

Everything in that answer is checked against the database before it is
shown: a name has to belong to someone on record, and a link has to join two
people, or a person and a topic one of them talked about. The model reads the
network; it never writes to it and can't add anyone to it.

The network is read into memory once per question, so no database connection
is held open while the model thinks.
"""

import json
import re
import time
from dataclasses import dataclass, field

from . import llm
from .logic import find_by_name, resolve_names
from .store import Interaction, Person, Store

# Rounds of tool use before the model is made to answer.
MAX_ROUNDS = 3
# Tools run per round. Left alone, the model fires dozens at once, which is
# slow and no better; the rest are answered "not run".
MAX_CALLS = 3
# What the answer says it looked at, before "and N more".
MAX_STEPS = 5
# How many people the opening outline lists before it says "and N more".
OUTLINE_LIMIT = 80
# How many pairs of people who share something the outline lists.
PAIRS_LIMIT = 25


# ------------------------------------------------------------------ network


@dataclass
class Known:
    """One person, with what hangs off them."""

    person: Person
    topics: list[str]
    meetings: list[Interaction]

    @property
    def name(self) -> str:
        return self.person.name

    def heading(self) -> str:
        """Name, then role and company when known."""
        what = ", ".join(x for x in (self.person.role, self.person.org) if x)
        return f"{self.name} ({what})" if what else self.name

    def subjects(self) -> set[str]:
        """Topics and interests, lower-cased, for finding common ground."""
        return {s.strip().lower() for s in [*self.topics, *self.person.interests] if s.strip()}


@dataclass
class Network:
    people: list[Known] = field(default_factory=list)

    @classmethod
    def load(cls, db: Store) -> "Network":
        return cls(
            [
                Known(p, [t.label for t in db.topics(p.id)], db.interactions(p.id))
                for p in db.people()
            ]
        )

    def find(self, name: str) -> Known | None:
        hit = find_by_name([k.person for k in self.people], str(name or ""))
        return next((k for k in self.people if k.person is hit), None)

    def topics(self) -> set[str]:
        """Every topic and interest anyone has, lower-cased."""
        return set().union(*(k.subjects() for k in self.people)) if self.people else set()


# Words too common to link two topics ("payments for" and "for robotics").
_FILLER = {"about", "with", "from", "into", "their", "this", "that", "your", "over"}


def _key_words(subject: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", subject.lower()) if len(w) > 3 and w not in _FILLER}


def common(a: Known, b: Known) -> list[str]:
    """What links two people on record: topics or interests they share, or
    that share a key word ("embedded payments" and "payments
    infrastructure"), the same company, or one having been introduced by or
    knowing the other."""
    mine, theirs = a.subjects(), b.subjects()
    shared = sorted(mine & theirs)
    for x in sorted(mine - theirs):
        for y in sorted(theirs - mine):
            if _key_words(x) & _key_words(y):
                shared.append(f"{x} / {y}")
    if a.person.org and a.person.org.lower() == b.person.org.lower():
        shared.append(f"both at {a.person.org}")
    for one, other in ((a, b), (b, a)):
        said = set(re.findall(r"\w+", one.person.relationship.lower()))
        if said and set(other.name.lower().split()) & said:
            shared.append(one.person.relationship)
    return shared


# -------------------------------------------------------------------- tools


def _clip(text: str, limit: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def owed_by(text: str) -> str:
    """Who owes a follow-up, read from its wording: "you" when the wearer
    said they would ("send them the repo link") or was asked to ("send me
    your resume"), "them" when the other person said they would ("send you
    our demo"), "" when the wording doesn't say.

    "me" is looked for first: a line that kept the other person's own words,
    "send me your resume", has "your" in it and is still the wearer's to do."""
    words = set(re.findall(r"[a-z']+", text.lower()))
    if "me" in words or words & {"them", "their", "him", "her", "his"}:
        return "you"
    if words & {"you", "your", "yours"}:
        return "them"
    # "send my deck": theirs if they said it, but nothing says who did
    return "you" if "my" in words else ""


def follow_ups(people: list[Known]) -> str:
    """Every follow-up, grouped by who owes it."""
    groups = {"you": [], "them": [], "": []}
    for k in people:
        for f in k.person.followups:
            groups[owed_by(f)].append(f"- {k.name}: {f}")
    titles = {
        "you": "What you said you'd do, and for whom:",
        "them": "What others said they'd do for you:",
        "": "Follow-ups where it isn't clear who said them:",
    }
    parts = [titles[g] + "\n" + "\n".join(lines) for g, lines in groups.items() if lines]
    return "\n".join(parts)


def _meeting_line(m: Interaction, who: str = "") -> str:
    whom = f"{who}, " if who else ""
    return f"- {m.timestamp[:16]}, {whom}{m.kind}: {_clip(m.summary, 200)}"


def outline(net: Network) -> str:
    """The network at a glance, given with the question."""
    lines = [f"Your network has {len(net.people)} people."]
    for k in sorted(net.people, key=lambda k: -len(k.meetings))[:OUTLINE_LIMIT]:
        bits = [k.heading()]
        if k.topics:
            bits.append("talked about " + ", ".join(k.topics[:6]))
        bits.append(f"met {len(k.meetings)} times")
        lines.append("- " + "; ".join(bits))
    if len(net.people) > OUTLINE_LIMIT:
        lines.append(f"…and {len(net.people) - OUTLINE_LIMIT} more. Use find_people.")
    pairs = shared_ground(net)
    if pairs:
        lines += ["", "Who shares what, from the record:", *pairs]
    owed = follow_ups(net.people)
    return "\n".join(lines) + (f"\n\n{owed}" if owed else "")


def shared_ground(net: Network) -> list[str]:
    """Pairs of people who share something on record, those who share most
    first: the only grounds for suggesting an introduction."""
    found = []
    people = sorted(net.people, key=lambda k: k.name.lower())
    for i, a in enumerate(people):
        for b in people[i + 1 :]:
            shared = common(a, b)
            if shared:
                found.append((-len(shared), f"- {a.name} & {b.name}: {', '.join(shared)}"))
    return [line for _, line in sorted(found)[:PAIRS_LIMIT]]


def find_people(net: Network, text: str = "") -> str:
    words = [w for w in (text or "").lower().replace(",", " ").split() if len(w) > 1]
    if not words:
        return "Say what to search for."
    scored = []
    for k in net.people:
        p = k.person
        fields = {
            "name": p.name, "role": p.role, "company": p.org,
            "how you know them": p.relationship, "notes": p.notes,
            "interests": " ".join(p.interests), "topics": " ".join(k.topics),
            "promises": " ".join(p.followups),
            "meetings": " ".join(m.summary for m in k.meetings),
        }  # fmt: skip
        hits = [label for label, value in fields.items() if any(w in value.lower() for w in words)]
        if hits:
            score = sum(w in " ".join(fields.values()).lower() for w in words)
            scored.append((score, len(hits), k, hits))
    if not scored:
        return f"Nobody matches “{text}”."
    scored.sort(key=lambda s: (-s[0], -s[1]))
    return "\n".join(f"- {k.heading()}: matched in {', '.join(hits)}" for _, _, k, hits in scored[:8])


def person(net: Network, name: str = "") -> str:
    k = net.find(name)
    if k is None:
        return f"Nobody called “{name}” is on record."
    p = k.person
    lines = [k.heading()]
    if p.relationship:
        lines.append(f"How you know them: {p.relationship}")
    lines.append(f"Met {len(k.meetings)} times. Last: {p.last_interaction or 'nothing on file'}")
    if p.interests:
        lines.append("Interests: " + ", ".join(p.interests))
    if k.topics:
        lines.append("Talked about: " + ", ".join(k.topics))
    if p.followups:
        lines.append(follow_ups([k]))
    if p.notes:
        lines.append("Notes: " + _clip(p.notes, 300))
    if k.meetings:
        lines.append("Meetings, newest first:")
        lines += [_meeting_line(m) for m in reversed(k.meetings[-6:])]
        heard = next((m.transcript for m in reversed(k.meetings) if m.transcript), "")
        if heard:
            lines.append("Last conversation, as heard: " + _clip(heard, 700))
    return "\n".join(lines)


def connections(net: Network, name: str = "") -> str:
    k = net.find(name)
    if k is None:
        return f"Nobody called “{name}” is on record."
    mine = k.subjects()
    lines = []
    for other in net.people:
        if other is k:
            continue
        shared = sorted(mine & other.subjects())
        if k.person.org and k.person.org.lower() == other.person.org.lower():
            shared.append(f"both at {k.person.org}")
        if shared:
            lines.append(f"- {other.heading()}: {', '.join(shared)}")
    if not lines:
        return f"No one shares a topic, company or interest with {k.name} yet."
    return f"Who {k.name} connects to, and through what:\n" + "\n".join(lines)


def topic(net: Network, label: str = "") -> str:
    wanted = (label or "").strip().lower()
    if not wanted:
        return "Say which topic."
    lines = []
    for k in net.people:
        near = [s for s in k.subjects() if wanted in s or s in wanted]
        if k.person.org and wanted in k.person.org.lower():
            near.append(f"works at {k.person.org}")
        if near:
            lines.append(f"- {k.heading()}: {', '.join(sorted(set(near)))}")
    return "\n".join(lines) if lines else f"Nobody talked about “{label}”."


def recent_meetings(net: Network, limit: int = 8) -> str:
    try:
        limit = max(1, min(int(limit), 20))
    except (TypeError, ValueError):
        limit = 8
    every = [(m, k.name) for k in net.people for m in k.meetings]
    every.sort(key=lambda mk: mk[0].timestamp, reverse=True)
    if not every:
        return "No meetings on record yet."
    return "\n".join(_meeting_line(m, who) for m, who in every[:limit])


def promises(net: Network) -> str:
    return follow_ups(net.people) or "No follow-ups on record."


def _text_arg(description: str) -> dict:
    return {"type": "string", "description": description}


def _tool(name: str, description: str, properties: dict, required: list[str]) -> dict:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {"type": "object", "properties": properties, "required": required},
        },
    }


TOOLS = [
    _tool(
        "find_people",
        "Search everyone by any words: name, role, company, interests, topics, promises, "
        "what was said in meetings.",
        {"text": _text_arg("What to search for, e.g. 'fintech investor'.")},
        ["text"],
    ),
    _tool(
        "person",
        "Everything on record about one person: who they are, how you know them, what you "
        "talked about, what was promised, their meetings and the last conversation.",
        {"name": _text_arg("Their name, as in the outline.")},
        ["name"],
    ),
    _tool(
        "connections",
        "Who one person connects to, and through what: a shared topic, interest or company.",
        {"name": _text_arg("Their name.")},
        ["name"],
    ),
    _tool(
        "topic",
        "Who talked about a topic, or is interested in it, or works at a company of that name.",
        {"label": _text_arg("The topic, e.g. 'payments'.")},
        ["label"],
    ),
    _tool(
        "recent_meetings",
        "The latest meetings with anyone, newest first.",
        {"limit": {"type": "integer", "description": "How many, 1 to 20. Default 8."}},
        [],
    ),
    _tool(
        "promises",
        "Every follow-up from conversations, by person: things you or they said would be done.",
        {},
        [],
    ),
    _tool(
        "answer",
        "Give the final answer. Call this once you know enough, or when nothing fits.",
        {
            "text": _text_arg(
                "What to tell the wearer: one to three short sentences, under 60 words, "
                "addressed to them as 'you'. Concrete: names, what links them, what to do. "
                "If nobody fits, say so plainly."
            ),
            "people": {
                "type": "array",
                "items": {"type": "string"},
                "description": "The people the answer is about, most relevant first, "
                "exactly as named on record. Empty if nobody fits.",
            },
            "links": {
                "type": "array",
                "description": "Connections the answer points out, for the map to draw.",
                "items": {
                    "type": "object",
                    "properties": {
                        "from": _text_arg("A person's name."),
                        "to": _text_arg("Another person's name, or a topic."),
                        "via": _text_arg("What links them, in a few words."),
                    },
                    "required": ["from", "to"],
                },
            },
        },
        ["text", "people"],
    ),
]

# Arguments are made text first: the model may send a list or a number.
_RUN = {
    "find_people": lambda net, a: find_people(net, str(a.get("text", ""))),
    "person": lambda net, a: person(net, str(a.get("name", ""))),
    "connections": lambda net, a: connections(net, str(a.get("name", ""))),
    "topic": lambda net, a: topic(net, str(a.get("label", ""))),
    "recent_meetings": lambda net, a: recent_meetings(net, a.get("limit", 8)),
    "promises": lambda net, _a: promises(net),
}


def step_line(net: Network, name: str, args: dict) -> str:
    """What a tool call did, in words for the person who asked."""
    who = net.find(args.get("name", "")) if "name" in args else None
    named = who.name if who else str(args.get("name", "")).strip()
    text = str(args.get("text", args.get("label", ""))).strip()
    if name in ("find_people", "topic") and not text:
        return ""
    return {
        "find_people": f"Searched for “{_clip(str(args.get('text', '')), 40)}”",
        "person": f"Read about {named}",
        "connections": f"Looked at who {named} connects to",
        "topic": f"Looked at who talked about {_clip(str(args.get('label', '')), 40)}",
        "recent_meetings": "Looked at your recent meetings",
        "promises": "Looked at the follow-ups",
    }.get(name, "")


# -------------------------------------------------------------------- agent

SYSTEM = """You are Thread's memory. The wearer meets people while wearing smart \
glasses, and Thread remembers who they met and what was said. Answer the wearer's \
question about the people they have met.

Use the tools to look things up: find people, read about someone, see who they \
connect to and through what, see who talked about a topic, recent meetings, \
follow-ups. If the outline already answers the question, call `answer` straight \
away. Otherwise use one to three tools at a time, look only for what the question \
needs, and answer as soon as you know. When the question is about connecting \
people, check what actually links them. Then call `answer`.

Rules:
- Only use what the tools and the outline say. Never invent a person, a company, \
a meeting or a fact. If nothing fits, say so.
- Name people exactly as they are on record.
- Suggest connecting two people only from "Who shares what" or what a tool shows \
they share. Say what links them, and include the link in `answer`. Don't \
speculate about links the record doesn't show.
- Follow-ups are grouped by who said they'd do them. "What you said you'd do" is \
the wearer's; "What others said they'd do for you" is theirs. Keep to that.
- One to three short sentences, spoken to the wearer as "you"."""


@dataclass
class Result:
    text: str
    people: list[Person]
    links: list[dict]
    steps: list[str]


def ask(net: Network, question: str, wearer: str = "") -> Result:
    """Answer `question` by letting the model use the tools. Raises
    llm.LLMError when the model can't be reached or never answers."""
    today = time.strftime("%A %d %B %Y")
    about = f"\nThe wearer's own name is {wearer}; they are never one of the people." if wearer else ""
    messages: list[dict] = [
        {"role": "system", "content": f"{SYSTEM}\n\nToday is {today}.{about}"},
        {"role": "user", "content": f"{outline(net)}\n\nQuestion: {question}"},
    ]
    steps: list[str] = []
    for round_ in range(MAX_ROUNDS + 1):
        last = round_ == MAX_ROUNDS
        turn = llm.agent_turn(messages, TOOLS, finish_with="answer" if last else "")
        final = next((c for c in turn.calls if c.name == "answer"), None)
        if final is not None:
            return _checked(net, final.args, steps)
        if not turn.calls:
            if not turn.content.strip():
                raise llm.LLMError("The language model neither used a tool nor answered.")
            return _in_words(net, messages, turn.content, steps)
        messages.append(
            {
                "role": "assistant",
                "content": turn.content or None,
                "tool_calls": [
                    {
                        "id": c.id,
                        "type": "function",
                        "function": {"name": c.name, "arguments": json.dumps(c.args)},
                    }
                    for c in turn.calls
                ],
            }
        )
        for n, call in enumerate(turn.calls):
            run = _RUN.get(call.name)
            if n >= MAX_CALLS:
                result = f"Not run: use at most {MAX_CALLS} tools at a time."
            elif run is None:
                result = f"There is no tool called {call.name}. Use one of: {', '.join(_RUN)}, answer."
            else:
                result = run(net, call.args)
                line = step_line(net, call.name, call.args)
                if line and line not in steps:
                    steps.append(line)
            messages.append({"role": "tool", "tool_call_id": call.id, "content": result})
    raise llm.LLMError("The language model didn't finish answering.")


def _in_words(net: Network, messages: list[dict], said: str, steps: list[str]) -> Result:
    """The model answered in words rather than through `answer`. Ask it once
    to give that answer through the tool, so its people and links are named
    and checked like any other. Failing that, the words are the answer, about
    whoever they name in full."""
    messages = [
        *messages,
        {"role": "assistant", "content": said},
        {"role": "user", "content": "Give exactly that answer with the `answer` tool: "
                                    "the text, the people it is about, and the links."},
    ]  # fmt: skip
    try:
        turn = llm.agent_turn(messages, TOOLS, finish_with="answer")
        final = next((c for c in turn.calls if c.name == "answer"), None)
        if final is not None:
            return _checked(net, final.args, steps)
    except llm.LLMError:
        pass
    named = [k.name for k in net.people if _mentions(said, k.name)]
    return _checked(net, {"text": said, "people": named}, steps)


def _mentions(text: str, name: str) -> bool:
    """Whether `text` names this person in full."""
    return bool(name.strip()) and re.search(rf"\b{re.escape(name)}\b", text, re.I) is not None


def _sentences(text: str, limit: int) -> str:
    """As many whole sentences as fit in `limit` characters, as plain text:
    the model sometimes writes Markdown, which would show as asterisks."""
    text = re.sub(r"(\*\*|__|`)", "", text)
    text = " ".join(text.split())
    kept = ""
    for sentence in re.split(r"(?<=[^\d\s][.!?])\s+", text):
        if kept and len(kept) + 1 + len(sentence) > limit:
            break
        kept = f"{kept} {sentence}".strip()
    return _clip(kept, limit)


def _checked(net: Network, args: dict, steps: list[str]) -> Result:
    """The answer, keeping only names and links that are on record."""
    on_record = [k.person for k in net.people]
    named = args.get("people") if isinstance(args.get("people"), list) else []
    people = resolve_names(on_record, [n for n in named if isinstance(n, str)])

    links, seen = [], set()
    known = {id(k.person): k for k in net.people}
    raw_links = args.get("links") if isinstance(args.get("links"), list) else []
    for link in raw_links[:12]:
        if not isinstance(link, dict):
            continue
        a = resolve_names(on_record, [str(link.get("from", ""))])
        if not a:
            continue
        to_text = str(link.get("to", "")).strip()
        b = resolve_names(on_record, [to_text])
        ka = known[id(a[0])]
        if b and b[0].id != a[0].id:
            # Two people: only when the record shows what links them, and
            # that, not the model's wording, is what the link says.
            shared = common(ka, known[id(b[0])])
            if not shared:
                continue
            to, kind, via = b[0].name, "person", _clip(shared[0], 60)
        elif to_text.lower() in ka.subjects():
            to, kind, via = to_text.lower(), "topic", ""
        else:
            continue
        key = (a[0].name, to)
        if key in seen or key[::-1] in seen:
            continue
        seen.add(key)
        links.append({"from": a[0].name, "to": to, "kind": kind, "via": via})
        # whoever a link joins is part of the answer too
        for p in a + (b if kind == "person" else []):
            if all(p.id != q.id for q in people):
                people.append(p)

    text = _sentences(str(args.get("text", "")), 360)
    if not text:
        text = "No one fits that yet." if not people else "These are the people that fit."
    if len(steps) > MAX_STEPS:
        steps = [*steps[: MAX_STEPS - 1], f"and {len(steps) - MAX_STEPS + 1} more lookups"]
    return Result(text=text, people=people, links=links, steps=steps)
