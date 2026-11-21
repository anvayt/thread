"""Measure what Nemotron pulls out of a conversation.

The unit tests run against a stand-in for the model, so they say the code is
right, not that the model is. This asks the real model (the one LLM_BASE_URL
points at) to file fifteen scripted career-fair conversations, compares each
answer with what was actually said, and prints a score per field.

    cd thread-backend/backend
    uv run python tests/eval_nemotron.py          # the table
    uv run python tests/eval_nemotron.py -v       # and every answer

It is not a pytest file and never runs with the suite: it needs the model, and
takes a few seconds per conversation.

The conversations are ones we wrote, with invented people and companies. Some
are easy; some are there to catch a specific mistake: no name said, the wearer
introducing themself, speech-recogniser text with no punctuation, nothing
promised. Fifteen is a check on the prompt, not a benchmark.
"""

import argparse
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from server import llm  # noqa: E402
from server.__main__ import load_env  # noqa: E402
from server.agent import owed_by  # noqa: E402

WEARER = "Maya Lindqvist"


@dataclass
class Case:
    """One conversation and what a careful listener would write down.

    `role` and each entry of `topics` are sets of acceptable words: the model
    may say "campus recruiter" or "recruiting", "ML" or "machine learning".
    `followup` is a word the promise must contain, and `owed` who made it:
    "you" (the wearer), "them" (the other person). Empty means not said."""

    label: str
    transcript: str
    name: str = ""
    role: tuple[str, ...] = ()
    org: str = ""
    topics: list[tuple[str, ...]] = field(default_factory=list)
    followup: str = ""
    owed: str = ""
    wearer: str = ""


CASES = [
    Case(
        "plain introduction",
        "Hi, I'm Odette Marlowe, I'm a campus recruiter at Pennyroyal Labs. We're hiring "
        "machine learning interns for the summer, mostly on the recommendations team. "
        "Send me your resume tonight and I'll make sure it gets read.",
        name="Odette Marlowe", role=("recruit",), org="Pennyroyal Labs",
        topics=[("machine learning", "ml"), ("intern",)],
        followup="resume", owed="you",
    ),
    Case(
        "they promise to send something",
        "Nice to meet you, I'm Caspian Whitlow, staff engineer at Harrowgate Systems. "
        "I work on our distributed storage layer. I'll send you the link to our "
        "new grad openings after the fair.",
        name="Caspian Whitlow", role=("engineer",), org="Harrowgate Systems",
        topics=[("storage", "distributed")],
        followup="link", owed="them",
    ),
    Case(
        "no name said",
        "So we're Tallowmere Robotics, we build warehouse picking arms. Honestly the "
        "best thing you can do is apply online and mention you stopped by the booth. "
        "We care a lot about controls and embedded experience.",
        name="", org="Tallowmere Robotics",
        topics=[("robot", "warehouse"), ("controls", "embedded")],
    ),
    Case(
        "both people speak, wearer named first",
        "Hi, I'm Maya Lindqvist, I'm a junior in computer science. Great to meet you "
        "Maya, I'm Ignatius Voss, I lead data engineering at Quillfeather. Tell me about "
        "your pipeline project. Sure, it was a streaming ETL job on Kafka. "
        "That's exactly what my team does. Email me your GitHub and I'll take a look.",
        name="Ignatius Voss", role=("data engineering", "lead"), org="Quillfeather",
        topics=[("data engineering", "pipeline", "etl", "streaming", "kafka")],
        followup="github", owed="you", wearer=WEARER,
    ),
    Case(
        "speech-recogniser text, no punctuation",
        "hey there im beatrix okonkwo im a product manager at lumenvale health we do "
        "scheduling software for clinics were looking for product interns who can "
        "code a little ill connect you with our university team next week",
        name="Beatrix Okonkwo", role=("product",), org="Lumenvale Health",
        topics=[("health", "clinic", "scheduling"), ("product", "intern")],
        followup="university", owed="them",
    ),
    Case(
        "nothing promised",
        "I'm Leopold Arkwright, I'm a security researcher at Dunmore and Finch. Mostly "
        "I do firmware reverse engineering. It's a small team, we don't have intern "
        "roles this year, but it was good talking about your capture the flag team.",
        name="Leopold Arkwright", role=("security", "research"), org="Dunmore and Finch",
        topics=[("security", "firmware", "reverse engineering"), ("capture the flag", "ctf")],
    ),
    Case(
        "no company said",
        "Hey, I'm Saoirse Dunleavy. I'm a PhD student working on reinforcement learning "
        "for robot grasping. I'm not recruiting, just here with my lab's poster. "
        "You should read our paper, I'll send you the preprint.",
        name="Saoirse Dunleavy", role=("phd", "student"), org="",
        topics=[("reinforcement learning", "rl"), ("robot", "grasping")],
        followup="preprint", owed="them",
    ),
    Case(
        "the wearer promises",
        "I'm Thaddeus Brink, engineering manager at Coppergate Payments. We run the "
        "card authorisation service, lots of Go and Postgres. I'd love to see that "
        "rate limiter you built. Okay, I'll send you the repo link tonight.",
        name="Thaddeus Brink", role=("manager",), org="Coppergate Payments",
        topics=[("payment", "card"), ("go", "postgres", "rate limiter")],
        followup="repo", owed="you", wearer=WEARER,
    ),
    Case(
        "name spelled out",
        "My name's Xiomara Quenby, that's Q-U-E-N-B-Y. I'm a technical recruiter with "
        "Starling Ridge. We're hiring for compilers and developer tools. Apply by "
        "Friday and put my name in the referral box.",
        name="Xiomara Quenby", role=("recruit",), org="Starling Ridge",
        topics=[("compiler",), ("developer tools", "tools", "tooling")],
        followup="apply", owed="you",
    ),
    Case(
        "a third person is mentioned",
        "Hi, I'm Rosalind Achterberg, I'm a hardware engineer at Vantablack Devices. I "
        "do FPGA design. You should really talk to my colleague Emeric Stroud, he runs "
        "the intern programme. I'll introduce you to him by email.",
        name="Rosalind Achterberg", role=("hardware", "engineer"), org="Vantablack Devices",
        topics=[("fpga", "hardware")],
        followup="introduc", owed="them",
    ),
    Case(
        "role but no title",
        "I'm Florian Estrada from Meridian Tidewater. I've been on the computer vision "
        "team for three years, we do inspection for wind turbine blades. We take "
        "interns every spring. Send me a note in January and I'll flag your application.",
        name="Florian Estrada", org="Meridian Tidewater",
        topics=[("computer vision", "vision"), ("wind", "turbine", "inspection")],
        followup="january", owed="you",
    ),
    Case(
        "small talk around the facts",
        "Wow, long day, my feet are killing me. Anyway. Philippa Nakagawa, I head up "
        "university recruiting at Oakhollow Analytics. We're a data science consultancy. "
        "Did you get a tote bag? Take one. We're hiring analysts in Austin and Denver.",
        name="Philippa Nakagawa", role=("recruit",), org="Oakhollow Analytics",
        topics=[("data science", "analyst", "analytics")],
    ),
    Case(
        "wearer does most of the talking",
        "Hi, I'm Maya Lindqvist. I built a face recognition app for smart glasses and "
        "I'm looking for machine learning internships. Oh cool. I'm Cornelius Adeyemi, "
        "I'm on the applied research team at Fernbank AI. That's close to what we do. "
        "I'll forward your profile to our hiring manager.",
        name="Cornelius Adeyemi", role=("research",), org="Fernbank AI",
        topics=[("machine learning", "ml", "research", "face recognition", "internship")],
        followup="profile", owed="them", wearer=WEARER,
    ),
    Case(
        "two promises, one each way",
        "I'm Henrietta Solberg, site reliability engineer at Kestrel Cloudworks. We "
        "run Kubernetes for about four hundred teams. I'll send you our on-call "
        "handbook, it's public. And send me that outage write-up you mentioned.",
        name="Henrietta Solberg", role=("reliability", "sre", "engineer"), org="Kestrel Cloudworks",
        topics=[("kubernetes", "reliability", "sre", "on-call", "cloud")],
        followup="handbook", owed="them",
    ),
    Case(
        "nothing useful said",
        "Yeah the line for the coffee is insane. I think the keynote starts at two? "
        "I'm just waiting for my friend. Have a good one.",
        name="", org="",
    ),
]  # fmt: skip


# ------------------------------------------------------------------ scoring


def plain(text: str) -> str:
    """Lower-case, letters and digits only, single spaces."""
    return " ".join(re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).split())


def has_any(text: str, words: tuple[str, ...]) -> bool:
    text = plain(text)
    return any(re.search(rf"\b{re.escape(plain(w))}", text) for w in words)


def grounded(topic: str, transcript: str) -> bool:
    """Whether a topic the model gave was said: any of its longer words, or
    the start of one, is in the transcript. Rough, and on the generous side."""
    said = plain(transcript)
    words = [w for w in plain(topic).split() if len(w) > 2]
    return any(w[:5] in said for w in words) if words else plain(topic) in said


@dataclass
class Score:
    hits: int = 0
    total: int = 0

    def add(self, ok: bool) -> bool:
        self.hits += bool(ok)
        self.total += 1
        return bool(ok)

    def __str__(self) -> str:
        if not self.total:
            return "      n/a"
        return f"{self.hits:>3}/{self.total:<3} {100 * self.hits / self.total:>4.0f}%"


ROWS = [
    ("name", "the right name, or none when none was said"),
    ("role", "the role they gave"),
    ("company", "the right company, or none when none was said"),
    ("topics found", "subjects that were discussed and got recorded"),
    ("topics said", "recorded subjects that were really in the conversation"),
    ("follow-up", "the promise recorded, or none when none was made"),
    ("who owes it", "the promise worded so the right person owes it"),
]


def judge(case: Case, got: llm.ContactInfo, scores: dict[str, Score]) -> list[str]:
    """Score one answer. Returns what it got wrong, in words."""
    wrong = []

    if not scores["name"].add(plain(got.name) == plain(case.name)):
        wrong.append(f"name: wanted “{case.name}”, got “{got.name}”")

    if case.role and not scores["role"].add(has_any(got.role, case.role)):
        wrong.append(f"role: wanted {' / '.join(case.role)}, got “{got.role}”")

    if not scores["company"].add(plain(got.org) == plain(case.org)):
        wrong.append(f"company: wanted “{case.org}”, got “{got.org}”")

    recorded = " | ".join([*got.topics, *got.interests])
    for wanted in case.topics:
        if not scores["topics found"].add(has_any(recorded, wanted)):
            wrong.append(f"topic missed: {' / '.join(wanted)}")
    for given in got.topics:
        if not scores["topics said"].add(grounded(given, case.transcript)):
            wrong.append(f"topic not said: “{given}”")

    if case.followup:
        match = next((f for f in got.followups if has_any(f, (case.followup,))), None)
        if not scores["follow-up"].add(match is not None):
            wrong.append(f"follow-up missed: {case.followup} (got {got.followups})")
        elif not scores["who owes it"].add(owed_by(match) == case.owed):
            wrong.append(f"follow-up owed by {case.owed}, but worded “{match}”")
    elif not scores["follow-up"].add(not got.followups):
        wrong.append(f"follow-up invented: {got.followups}")

    return wrong


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("-v", "--verbose", action="store_true", help="print every answer")
    args = parser.parse_args()

    load_env()
    print(f"Model:    {llm.model_name()}")
    print(f"Endpoint: {llm.endpoint()}")
    print(f"Conversations: {len(CASES)}\n")

    scores = {name: Score() for name, _ in ROWS}
    failed, clean, seconds = 0, 0, []
    for n, case in enumerate(CASES, 1):
        started = time.perf_counter()
        try:
            got = llm.extract_contact(case.transcript, case.wearer)
        except llm.LLMError as error:
            failed += 1
            print(f"{n:>2}. {case.label}: NO ANSWER ({error})")
            if failed == 3 and failed == n:
                print("\nThe model isn't answering. Check LLM_BASE_URL and LLM_API_KEY.")
                return 1
            continue
        seconds.append(time.perf_counter() - started)
        wrong = judge(case, got, scores)
        clean += not wrong
        print(f"{n:>2}. {case.label}: {'ok' if not wrong else 'MISSED'}  ({seconds[-1]:.1f}s)")
        for line in wrong:
            print(f"      {line}")
        if args.verbose:
            print(f"      {got.model_dump()}")

    answered = len(CASES) - failed
    print(f"\n{'Field':<14}{'Score':>12}   What it means")
    print("-" * 78)
    for name, meaning in ROWS:
        print(f"{name:<14}{str(scores[name]):>12}   {meaning}")
    print("-" * 78)
    print(f"Conversations filed with nothing wrong: {clean}/{answered}")
    if failed:
        print(f"Conversations the model gave no answer for: {failed}")
    if seconds:
        seconds.sort()
        print(f"Time per conversation: median {seconds[len(seconds) // 2]:.1f}s, "
              f"slowest {seconds[-1]:.1f}s")
    return 0 if answered else 1


if __name__ == "__main__":
    sys.exit(main())
