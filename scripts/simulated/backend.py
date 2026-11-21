"""The real backend with a scripted stand-in for the language model.

For running the app end to end in the Simulator with no language model.
Everything but the five language tasks is the real server: face matching,
storage, the API and the dashboard. The five tasks answer from the fixed rules below, so
names, cards and answers are crude and repeatable.

`scripts/simulate.sh` starts this when it finds no language model. By hand:

    cd thread-backend/backend
    DB_PATH=../../build/mock/test.db uv run python ../../scripts/simulated/backend.py
"""

import os
import re
import sys
from pathlib import Path

import uvicorn

# The server package sits in thread-backend/backend, wherever this is run from.
BACKEND = Path(__file__).resolve().parents[2] / "thread-backend" / "backend"
sys.path.insert(0, str(BACKEND))

from server import llm  # noqa: E402


def extract_contact(transcript: str, wearer: str = "") -> llm.ContactInfo:
    name = re.search(r"\b(?:I'm|I am|my name is|this is)\s+([A-Z][a-z]+(?:\s[A-Z][a-z]+)?)", transcript)
    org = re.search(r"\b(?:at|from|with)\s+([A-Z][A-Za-z]+)", transcript)
    role = re.search(r"\bI (?:run|lead|head)\s+([a-z]+)", transcript)
    owes = ["send them the API docs"] if "send" in transcript.lower() else []
    return llm.ContactInfo(
        name=name.group(1) if name else "",
        role=role.group(1).title() if role else "",
        org=org.group(1) if org else "",
        interests=["embedded payments"] if "payments" in transcript.lower() else [],
        followups=owes,
        topics=["payments", "API docs"] if "payments" in transcript.lower() else ["introductions"],
    )


def compose(name, role, org, relationship, last, notes, history) -> llm.Spoken:
    return llm.Spoken(line=f"{name}, {org or 'no company yet'}. Last time: {last or 'nothing on file'}.")


def lookup_card(name, org, relationship, interests, followups, history) -> llm.Card:
    lines = [f"You last talked about {interests or 'introductions'}."]
    if followups:
        lines.append(f"You owe them: {followups}.")
    lines.append("Ask how the launch went.")
    return llm.Card(headline=f"{name}, {org}" if org else name, lines=lines)


def pick_matches(question: str, roster: str) -> llm.Matches:
    first = roster.splitlines()[0].split("|")[0].strip() if roster.strip() else ""
    return llm.Matches(names=[first] if first else [], reason="Scripted: the first person on the roster.")


def caption_line(heard: str, lang: str) -> llm.Caption:
    return llm.Caption(language=lang, text=heard.strip().capitalize() + ".")


def agent_turn(messages, tools, finish_with=""):
    # No agent here: Ask falls back to pick_matches above.
    raise llm.LLMError("the stand-in answers in one step")


for task in (extract_contact, compose, lookup_card, pick_matches, caption_line, agent_turn):
    setattr(llm, task.__name__, task)

if __name__ == "__main__":
    # Only this machine: the Simulator reaches it as localhost.
    port = int(os.environ.get("PORT") or 8000)
    uvicorn.run("server.main:app", host="127.0.0.1", port=port, log_level="info")
