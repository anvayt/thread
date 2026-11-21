"""HTTP API.

Every endpoint is `POST /api/<name>` with a JSON body and answers
`{"ok": true, "data": {...}}`. Failures answer `{"ok": false, "error": "..."}`
with a matching HTTP status.
"""

import logging
import time
from dataclasses import replace
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel
from starlette.exceptions import HTTPException

from . import faces, llm
from .logic import cached_card, card_fingerprint, cosine, same_person, store_card
from .store import Interaction, Person, Store, Thing, session

log = logging.getLogger("server")

DASHBOARD = Path(__file__).resolve().parent.parent.parent / "web" / "index.html"

app = FastAPI(title="Thread", docs_url="/api/docs", redoc_url=None)

# The dashboard may be opened straight from disk, and the phone is a different
# origin again, so any page may call the API. There are no cookies to protect.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


def ok(data: dict) -> dict:
    return {"ok": True, "data": data}


def _fail(status: int, message: str) -> JSONResponse:
    return JSONResponse({"ok": False, "error": message}, status_code=status)


@app.exception_handler(RequestValidationError)
async def _bad_request(_: Request, err: RequestValidationError) -> JSONResponse:
    parts = []
    for e in err.errors():
        where = ".".join(str(p) for p in e["loc"] if p != "body")
        parts.append(f"{where}: {e['msg']}" if where else e["msg"])
    return _fail(422, "Invalid request - " + "; ".join(parts))


@app.exception_handler(llm.LLMError)
async def _llm_down(_: Request, err: llm.LLMError) -> JSONResponse:
    log.warning("language model unavailable: %s", err)
    return _fail(503, str(err))


@app.exception_handler(HTTPException)
async def _http_error(_: Request, err: HTTPException) -> JSONResponse:
    return _fail(err.status_code, str(err.detail))


@app.exception_handler(Exception)
async def _crash(_: Request, err: Exception) -> JSONResponse:
    log.exception("unhandled error", exc_info=err)
    return _fail(500, "The server hit an unexpected error. See its log for details.")


@app.get("/", include_in_schema=False)
def dashboard():
    if not DASHBOARD.exists():
        return _fail(404, "The dashboard is not installed next to the server.")
    # Always check with the server before reusing a saved copy, so an edited
    # dashboard is never shadowed by an older one in the browser's cache.
    return FileResponse(DASHBOARD, headers={"Cache-Control": "no-cache"})


# ------------------------------------------------------------------ helpers


def _stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def _find_by_name(people: list[Person], name: str) -> Person | None:
    """Exact match wins outright; a partial name ("Sarah") only falls back to
    the looser match, so two full names never collide on a first name."""
    wanted = name.strip().lower()
    for p in reversed(people):
        if p.name.lower() == wanted:
            return p
    for p in reversed(people):
        if same_person(p.name, name):
            return p
    return None


def _find_by_fragment(people: list[Person], fragment: str) -> Person | None:
    """The most recently added person whose name contains `fragment`."""
    needle = fragment.strip().lower()
    for p in reversed(people):
        if needle in p.name.lower():
            return p
    return None


def _best_face(people: list[Person], probe: list[float]) -> tuple[Person | None, float]:
    """Whoever the probe most resembles, with the weighted score.

    The relationship itself sways the match: someone the wearer knows well and
    saw recently is a likelier read than a faint acquaintance.
    """
    best, best_score = None, 0.0
    for p in people:
        weight = 1.0 + 0.15 * p.closeness + 0.10 * p.recency
        scored = cosine(probe, p.face_vec) * weight
        if scored > best_score:
            best, best_score = p, scored
    return best, best_score


def _whisper(db: Store, who: Person) -> str:
    """One line about `who` for the earpiece, or "" if it cannot be written.

    Recognising the face is local and already done; a language model outage
    must not turn a correct match into an error.
    """
    recent = db.interactions(who.id)[-3:]
    history = "".join(e.summary + "; " for e in reversed(recent))
    try:
        said = llm.compose(
            who.name, who.role, who.org, who.relationship,
            who.last_interaction, who.notes, history,
        )  # fmt: skip
    except llm.LLMError as err:
        log.warning("no whisper for %s: %s", who.name, err)
        return ""
    return said.line.strip()


def _card(db: Store, who: Person, history: str, refresh: bool = False) -> tuple[llm.Card, bool]:
    """The lookup card for `who`, and whether it came from the cache."""
    key = card_fingerprint(who, history)
    hit = None if refresh else cached_card(who, key)
    if hit is not None:
        return llm.Card(headline=hit[0], lines=hit[1]), True
    card = llm.lookup_card(
        who.name, who.org, who.relationship,
        ", ".join(who.interests), ", ".join(who.followups), history,
    )  # fmt: skip
    store_card(who, key, card.headline, card.lines)
    db.save_person(who)
    return card, False


def _recent_history(db: Store, who: Person) -> tuple[list[Interaction], str]:
    """The last five interactions (oldest first) and the same as one line of
    text for the model (newest first)."""
    past = db.interactions(who.id)[-5:]
    text = "".join(f"{e.timestamp} - {e.summary}; " for e in reversed(past))
    return past, text


# --------------------------------------------------------------------- faces


class RecognizeIn(BaseModel):
    frame_b64: str
    threshold: float = faces.FACE_THRESHOLD


@app.post("/api/recognize")
def recognize(body: RecognizeIn):
    """Resolve who is in frame, then say one useful thing about them."""
    started = time.time()
    probe = faces.embed_face(body.frame_b64)

    with session() as db:
        people = db.people()
        who, score = _best_face(people, probe)
        elapsed = round((time.time() - started) * 1000.0)

        if who is None or score < body.threshold:
            # Silence beats a wrong name. Report the miss so the client can
            # show it without speaking anything. Strangers are never recorded.
            return ok(
                {
                    "spoken": "",
                    "matched": False,
                    "score": round(score, 3),
                    "compared": len(people),
                    "elapsed_ms": elapsed,
                }
            )

        # Conversations filed by `ingest` land on the same person, so the
        # whisper can surface what was actually said, not just that we met.
        line = _whisper(db, who)
        summary = "Recognised in frame"
        if line:
            summary += f"; whispered: {line}"
        db.add_interaction(who.id, Interaction(timestamp=_stamp(), kind="sighting", summary=summary))

        return ok(
            {
                "spoken": line,
                "matched": True,
                "name": who.name,
                "role": who.role,
                "org": who.org,
                "score": round(score, 3),
                "compared": len(people),
                "elapsed_ms": elapsed,
            }
        )


class GlanceIn(BaseModel):
    image_b64: str
    source: str = "glasses"


@app.post("/api/glance")
def glance(body: GlanceIn):
    """Same work as recognize, shaped for a lens renderer:
    {whisper: {text, kind, confidence}, matched}."""
    probe = faces.embed_face(body.image_b64)

    with session() as db:
        who, score = _best_face(db.people(), probe)

        # No confident match: the lens shows a neutral line and nothing is
        # written. Strangers are never recorded.
        if who is None or score < faces.FACE_THRESHOLD:
            return ok(
                {
                    "whisper": {"text": "", "kind": "reassurance", "confidence": round(score, 3)},
                    "matched": "",
                }
            )

        line = _whisper(db, who)
        summary = f"Seen through the {body.source}"
        if line:
            summary += f"; whispered: {line}"
        db.add_interaction(who.id, Interaction(timestamp=_stamp(), kind="sighting", summary=summary))

        return ok(
            {
                "whisper": {"text": line, "kind": "recognition", "confidence": round(score, 3)},
                "matched": who.name,
            }
        )


class EnrollIn(BaseModel):
    name: str
    frame_b64: str
    role: str = ""
    org: str = ""
    relationship: str = ""
    last_interaction: str = ""
    notes: str = ""
    closeness: float = 0.5
    recency: float = 1.0


@app.post("/api/enroll")
def enroll(body: EnrollIn):
    """Attach a face to a person from a reference photo, creating them if new."""
    name = body.name.strip()
    if not name:
        return ok({"enrolled": False, "reason": "a name is needed to enrol a face"})

    vec = faces.embed_face(body.frame_b64)
    if not vec:
        return ok({"enrolled": False, "reason": "no face detected in the reference photo"})

    with session() as db:
        # This is the join. Someone whose conversation was already filed by
        # `ingest` must get their face attached to that SAME record -
        # otherwise recognising them later retrieves an empty history.
        who = _find_by_name(db.people(), name)
        attached = who is not None
        if who is None:
            who = db.add_person(
                Person(
                    name=name,
                    last_interaction=body.last_interaction,
                    closeness=body.closeness,
                    recency=body.recency,
                )
            )

        who.face_vec = vec
        # Keep the frame we enrolled from, so clients have a face to show.
        who.photo_b64 = faces.thumbnail(body.frame_b64)

        # Only fill fields the caller actually supplied, so enrolling a face
        # never blanks out detail the conversation already captured.
        for field in ("role", "org", "relationship", "notes"):
            supplied = getattr(body, field)
            if supplied:
                setattr(who, field, supplied)
        db.save_person(who)

        return ok(
            {
                "enrolled": True,
                "name": who.name,
                "dims": len(vec),
                "attached_to_existing": attached,
                "known_interactions": len(db.interactions(who.id)),
            }
        )


@app.post("/api/compact_photos")
def compact_photos():
    """Re-thumbnail stored photos. Useful after importing records whose photos
    were saved at full resolution."""
    saved = 0
    touched = []
    with session() as db:
        for p in db.people():
            before = len(p.photo_b64)
            if not before:
                continue
            small = faces.thumbnail(p.photo_b64)
            if small and len(small) < before:
                p.photo_b64 = small
                db.save_person(p)
                saved += before - len(small)
                touched.append(
                    {
                        "name": p.name,
                        "before_kb": round(before / 1024),
                        "after_kb": round(len(small) / 1024),
                    }
                )
    return ok({"compacted": touched, "bytes_saved": saved})


# ---------------------------------------------------------------- demo data

SEED_PEOPLE = [
    Person(
        name="Sarah Chen", role="VP Product", org="Acme",
        relationship="met at the Series A demo day",
        last_interaction="talked through their Series B raise",
        notes="still has an open question about our pricing tiers",
        closeness=0.9, recency=0.9,
    ),
    Person(
        name="Marcus Webb", role="Engineering Lead", org="Northwind",
        relationship="former colleague",
        last_interaction="promised to send the migration write-up",
        notes="allergic to shellfish; do not suggest the oyster bar",
        closeness=0.6, recency=0.4,
    ),
    Person(
        name="Priya Raman", role="Partner", org="Fieldstone Capital",
        relationship="introduced by Sarah",
        last_interaction="brief hallway chat about the seed round",
        notes="asked to be pinged once the metrics deck is ready",
        closeness=0.3, recency=0.2,
    ),
]  # fmt: skip

SEED_THINGS = [
    Thing(name="keys", category="everyday carry",
          context="usually left on the kitchen counter", closeness=0.8, recency=0.9),
    Thing(name="blue inhaler", category="medication",
          context="two puffs, morning and night", closeness=0.7, recency=0.5),
]  # fmt: skip


@app.post("/api/seed")
def seed():
    """Add the demo people and things. Safe to press twice: anything already
    present by name is left alone. Faces are enrolled separately."""
    added = []
    with session() as db:
        known = {p.name.lower() for p in db.people()}
        for spec in SEED_PEOPLE:
            if spec.name.lower() not in known:
                db.add_person(replace(spec))
                added.append(spec.name)

        held = {t.name.lower() for t in db.things()}
        for spec in SEED_THINGS:
            if spec.name.lower() not in held:
                db.add_thing(replace(spec))
                added.append(spec.name)

        return ok(
            {
                "seeded": True,
                "added": added,
                "people": len(db.people()),
                "things": len(db.things()),
            }
        )


@app.post("/api/reset")
def reset():
    """Delete everything: people, their interactions and topics, and things."""
    with session() as db:
        gone = len(db.people()) + len(db.things())
        db.clear()
    return ok({"cleared": gone})


@app.post("/api/roster")
def roster():
    """Everyone and everything currently known."""
    with session() as db:
        people = [
            {
                "name": p.name,
                "role": p.role,
                "org": p.org,
                "relationship": p.relationship,
                "enrolled_face": len(p.face_vec) > 0,
                "photo_b64": p.photo_b64,
                "encounters": len(db.interactions(p.id)),
            }
            for p in db.people()
        ]
        things = [
            {"name": t.name, "category": t.category, "context": t.context}
            for t in db.things()
        ]
    return ok({"people": people, "things": things})


# ------------------------------------------------------------------- speech
# recognize answers "who is this"; these answer "what did we say". They meet
# on the same person record.


class CaptionIn(BaseModel):
    text: str
    lang: str = "en"


@app.post("/api/caption")
def caption(body: CaptionIn):
    """Clean and optionally translate one chunk of live speech for a heads-up
    display. Never touches the database, so captions never wait on it."""
    heard = body.text.strip()
    if not heard:
        return ok({"display_text": ""})

    # A one- or two-word fragment carries no filler to strip and no grammar to
    # repair, but it does give a model room to improvise. Tidy it here
    # instead: no model call, no latency, nothing to hallucinate. Anything
    # needing translation still goes to the model.
    if len(heard.split()) < 3 and body.lang == "en":
        tidy = heard[0].upper() + heard[1:]
        if tidy[-1] not in ".!?,":
            tidy += "."
        return ok({"display_text": tidy})

    return ok({"display_text": llm.caption_line(heard, body.lang).text})


class IngestIn(BaseModel):
    transcript: str
    speaker: str = ""
    # The name of the person wearing the glasses. They introduce themselves
    # too, and must never be filed as the person they are meeting.
    wearer: str = ""


@app.post("/api/ingest")
def ingest(body: IngestIn):
    """File a conversation: find or create the speaker, append the
    interaction, link the topics discussed."""
    wearer = body.wearer.strip()
    info = (
        llm.extract_contact(body.transcript, wearer)
        if wearer
        else llm.extract_contact(body.transcript)
    )
    heard = info.name.strip()
    if wearer and heard and same_person(heard, wearer):
        # The model took the wearer's own introduction for the contact's.
        heard = ""

    # An explicit speaker (e.g. the person just recognised by face) always
    # beats a name the model thinks it heard.
    name = body.speaker.strip() or heard
    if not name:
        return ok({"saved": "", "reason": "nobody introduced themselves - not guessing a name"})

    with session() as db:
        who = _find_by_name(db.people(), name)
        fresh = who is None
        if who is None:
            who = db.add_person(
                Person(name=name, relationship="met at an event", closeness=0.5, recency=1.0)
            )

        if not who.org:
            who.org = info.org.strip()
        if not who.role:
            who.role = info.role.strip()
        for interest in info.interests:
            if interest not in who.interests:
                who.interests.append(interest)
        for followup in info.followups:
            if followup not in who.followups:
                who.followups.append(followup)

        gist = ", ".join(info.topics) or "a conversation"
        db.add_interaction(
            who.id,
            Interaction(
                timestamp=_stamp(), kind="conversation", summary=gist, transcript=body.transcript
            ),
        )
        who.last_interaction = gist
        db.save_person(who)

        # Topics are rows of their own, not a text field, so they can be
        # listed and linked instead of substring-matched out of a blob.
        discussed = {t.label.lower() for t in db.topics(who.id)}
        added = []
        for label in info.topics:
            if label.lower() not in discussed:
                db.add_topic(who.id, label)
                discussed.add(label.lower())
                added.append(label)

        return ok(
            {
                "saved": who.name,
                "new_person": fresh,
                "role": who.role,
                "org": who.org,
                "topics": info.topics,
                "new_topics": added,
                "followups": who.followups,
            }
        )


class LookupIn(BaseModel):
    name: str = "last"


@app.post("/api/lookup")
def lookup(body: LookupIn | None = None):
    """The card shown when you need reminding who someone is. Pass a name, or
    "last" for whoever you interacted with most recently."""
    name = (body or LookupIn()).name
    needle = name.strip().lower()

    with session() as db:
        people = db.people()
        who = None
        if needle in ("", "last"):
            latest = ("", 0)
            for p in people:
                for e in db.interactions(p.id):
                    if (e.timestamp, e.id) > latest:
                        latest, who = (e.timestamp, e.id), p
        else:
            who = _find_by_fragment(people, needle)

        if who is None:
            return ok({"found": False, "reason": f"nobody matching '{name}'"})

        past, history = _recent_history(db, who)
        card, cached = _card(db, who, history)

        return ok(
            {
                "found": True,
                "cached": cached,
                "name": who.name,
                "org": who.org,
                "photo_b64": who.photo_b64,
                "headline": card.headline,
                "lines": card.lines,
                "topics": [t.label for t in db.topics(who.id)],
                "followups": who.followups,
                "history": [
                    {"when": e.timestamp, "what": e.summary, "kind": e.kind} for e in past
                ],
            }
        )


class PersonCardIn(BaseModel):
    name: str
    refresh: bool = False


@app.post("/api/person_card")
def person_card(body: PersonCardIn):
    """Markdown dossier for one person."""
    with session() as db:
        who = _find_by_fragment(db.people(), body.name) if body.name.strip() else None
        if who is None:
            return ok({"md": f"**{body.name}** is not in your memory yet."})

        past, history = _recent_history(db, who)
        # `refresh: true` forces a rebuild; otherwise reuse the same memoised
        # card lookup serves, so the panel opens instantly.
        card, _ = _card(db, who, history, refresh=body.refresh)

        md = f"# {who.name}\n\n"
        if who.org:
            md += f"*{who.org}*\n\n"
        md += f"> {card.headline}\n\n"

        # The lens "more" pager reads the bullets under this exact heading -
        # renaming it silently empties that screen on the glasses.
        md += "## Things to ask about\n"
        md += "".join(f"- {line}\n" for line in card.lines)

        topics = [t.label for t in db.topics(who.id)]
        if topics:
            md += "\n## Discussed\n" + ", ".join(topics) + "\n"
        if who.followups:
            md += "\n## You owe them\n"
            md += "".join(f"- {f}\n" for f in who.followups)
        if past:
            md += "\n## History\n"
            md += "".join(f"- `{e.timestamp}` {e.summary}\n" for e in past)

        return ok({"name": who.name, "photo_b64": who.photo_b64, "md": md})


class QueryIn(BaseModel):
    question: str


@app.post("/api/query")
def query(body: QueryIn):
    """Free-text question over everyone met, e.g. 'who did I meet in
    fintech?'. The store builds the roster; the model only chooses from it."""
    with session() as db:
        people = db.people()
        if not people:
            return ok({"matches": [], "reason": "nobody in your memory yet", "searched": 0})
        if not body.question.strip():
            return ok({"matches": [], "reason": "no question asked", "searched": len(people)})

        # Role and last interaction go in too: a person who has been seeded or
        # enrolled but never had a conversation filed has no topics yet, and
        # would otherwise be invisible to every question.
        roster_text = ""
        for p in people:
            topics = ", ".join(t.label for t in db.topics(p.id))
            roster_text += (
                f"{p.name} | {p.role} | {p.org} | {', '.join(p.interests)}"
                f" | {topics} | {p.last_interaction}\n"
            )

        picked = llm.pick_matches(body.question, roster_text)

        # Only report people actually on record - the model chooses, it does
        # not get to invent a contact. But it does occasionally mistype a name
        # it just read ("Priva" for "Priya"), and losing a real match over one
        # letter looks broken. So: exact, then whole-word overlap, then a
        # single unambiguous word hit. Never a guess.
        matches = []
        taken = set()
        for picked_name in picked.names:
            hit = _find_by_name(people, picked_name)
            if hit is None:
                # Share a whole word, but only when exactly one person does -
                # two people called Sarah must never collapse into each other.
                words = set(picked_name.lower().split())
                sharing = [p for p in people if words & set(p.name.lower().split())]
                if len(sharing) == 1:
                    hit = sharing[0]
            if hit is not None and hit.id not in taken:
                taken.add(hit.id)
                matches.append({"name": hit.name, "org": hit.org, "last": hit.last_interaction})

        return ok({"matches": matches, "reason": picked.reason, "searched": len(people)})


class ForgetIn(BaseModel):
    name: str


@app.post("/api/forget")
def forget(body: ForgetIn):
    """Right to be forgotten: remove a person, their interactions and their
    topics together."""
    needle = body.name.strip().lower()
    gone = 0
    # An empty name would match everybody. Wiping everything is what reset is
    # for; it should never happen by accident here.
    if needle:
        with session() as db:
            for p in db.people():
                if same_person(p.name, body.name) or needle in p.name.lower():
                    db.delete_person(p.id)
                    gone += 1
    return ok({"forgotten": gone, "name": body.name})


# ---------------------------------------------------------------- dashboard
# Served in the shape the web view draws: {nodes, links} and a flat event list.


@app.post("/api/graph")
def graph():
    """Everything as nodes and links."""
    nodes = []
    links = []
    with session() as db:
        for p in db.people():
            pid = f"person:{p.id}"
            nodes.append({"id": pid, "label": p.name, "kind": "person"})
            for e in db.interactions(p.id):
                eid = f"encounter:{e.id}"
                nodes.append({"id": eid, "label": e.summary, "kind": "encounter"})
                links.append({"source": pid, "target": eid, "kind": "had"})
            for t in db.topics(p.id):
                tid = f"topic:{t.id}"
                nodes.append({"id": tid, "label": t.label, "kind": "topic"})
                links.append({"source": pid, "target": tid, "kind": "discussed"})
        for thing in db.things():
            nodes.append({"id": f"object:{thing.id}", "label": thing.name, "kind": "object"})
    return ok({"nodes": nodes, "links": links})


@app.post("/api/timeline")
def timeline():
    """Every interaction, oldest first."""
    events = []
    with session() as db:
        for p in db.people():
            for e in db.interactions(p.id):
                events.append(
                    {"kind": "encounter", "ts": e.timestamp, "text": f"{p.name} - {e.summary}"}
                )
    events.sort(key=lambda event: event["ts"])
    return ok({"events": events})
