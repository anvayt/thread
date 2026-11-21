"""SQLite persistence.

Four tables. A person owns their interactions and topics; things stand alone.
`closeness` and `recency` on a person describe the wearer's tie to them and
sway face matching towards people known well and seen recently.
"""

import json
import os
import sqlite3
import threading
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

DEFAULT_DB_PATH = Path(__file__).resolve().parent.parent / "data" / "memory.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS person (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    name             TEXT NOT NULL,
    role             TEXT NOT NULL DEFAULT '',
    org              TEXT NOT NULL DEFAULT '',
    relationship     TEXT NOT NULL DEFAULT '',
    last_interaction TEXT NOT NULL DEFAULT '',
    notes            TEXT NOT NULL DEFAULT '',
    interests        TEXT NOT NULL DEFAULT '[]',
    followups        TEXT NOT NULL DEFAULT '[]',
    face_vec         TEXT NOT NULL DEFAULT '[]',
    photo_b64        TEXT NOT NULL DEFAULT '',
    card_key         TEXT NOT NULL DEFAULT '',
    card_json        TEXT NOT NULL DEFAULT '',
    closeness        REAL NOT NULL DEFAULT 0.5,
    recency          REAL NOT NULL DEFAULT 0.5
);
CREATE TABLE IF NOT EXISTS interaction (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    person_id  INTEGER NOT NULL REFERENCES person(id),
    timestamp  TEXT NOT NULL,
    summary    TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'sighting',
    transcript TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS topic (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    person_id INTEGER NOT NULL REFERENCES person(id),
    label     TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS thing (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    name      TEXT NOT NULL,
    category  TEXT NOT NULL DEFAULT '',
    context   TEXT NOT NULL DEFAULT '',
    closeness REAL NOT NULL DEFAULT 0.5,
    recency   REAL NOT NULL DEFAULT 0.5
);
CREATE INDEX IF NOT EXISTS interaction_person ON interaction(person_id);
CREATE INDEX IF NOT EXISTS topic_person ON topic(person_id);
"""


@dataclass
class Person:
    name: str
    role: str = ""
    org: str = ""
    relationship: str = ""
    last_interaction: str = ""
    notes: str = ""
    interests: list[str] = field(default_factory=list)
    followups: list[str] = field(default_factory=list)
    # What matching uses. Empty for anyone known by voice alone.
    face_vec: list[float] = field(default_factory=list)
    # The enrolment photo, kept so clients can show a face next to a name.
    # Only ever displayed, never matched against.
    photo_b64: str = ""
    # Memoised lookup card; see logic.card_fingerprint.
    card_key: str = ""
    card_json: str = ""
    closeness: float = 0.5
    recency: float = 0.5
    id: int | None = None


@dataclass
class Interaction:
    """One meeting with one person. A face sighting and a spoken conversation
    are both interactions - `kind` tells them apart - so recognising someone
    surfaces what was actually said last time, not just that they were seen."""

    timestamp: str
    summary: str
    kind: str = "sighting"
    transcript: str = ""
    id: int | None = None
    person_id: int | None = None


@dataclass
class Topic:
    label: str
    id: int | None = None
    person_id: int | None = None


@dataclass
class Thing:
    name: str
    category: str = ""
    context: str = ""
    closeness: float = 0.5
    recency: float = 0.5
    id: int | None = None


_PERSON_COLUMNS = (
    "name", "role", "org", "relationship", "last_interaction", "notes",
    "interests", "followups", "face_vec", "photo_b64", "card_key", "card_json",
    "closeness", "recency",
)  # fmt: skip
_JSON_COLUMNS = ("interests", "followups", "face_vec")


def _person_values(p: Person) -> list:
    return [
        json.dumps(getattr(p, col)) if col in _JSON_COLUMNS else getattr(p, col)
        for col in _PERSON_COLUMNS
    ]


def _person_from_row(row: sqlite3.Row) -> Person:
    values = {
        col: json.loads(row[col]) if col in _JSON_COLUMNS else row[col]
        for col in _PERSON_COLUMNS
    }
    return Person(id=row["id"], **values)


class Store:
    """One connection's view of the database. Rows come back in the order
    they were created, which is what "the last one" means everywhere else."""

    def __init__(self, conn: sqlite3.Connection) -> None:
        self.conn = conn

    # -- people

    def people(self) -> list[Person]:
        rows = self.conn.execute("SELECT * FROM person ORDER BY id")
        return [_person_from_row(r) for r in rows]

    def add_person(self, p: Person) -> Person:
        marks = ", ".join("?" for _ in _PERSON_COLUMNS)
        cur = self.conn.execute(
            f"INSERT INTO person ({', '.join(_PERSON_COLUMNS)}) VALUES ({marks})",
            _person_values(p),
        )
        p.id = cur.lastrowid
        return p

    def save_person(self, p: Person) -> None:
        sets = ", ".join(f"{col} = ?" for col in _PERSON_COLUMNS)
        self.conn.execute(
            f"UPDATE person SET {sets} WHERE id = ?", [*_person_values(p), p.id]
        )

    def delete_person(self, person_id: int) -> None:
        """Remove a person together with everything that hangs off them."""
        self.conn.execute("DELETE FROM interaction WHERE person_id = ?", [person_id])
        self.conn.execute("DELETE FROM topic WHERE person_id = ?", [person_id])
        self.conn.execute("DELETE FROM person WHERE id = ?", [person_id])

    # -- interactions

    def interactions(self, person_id: int) -> list[Interaction]:
        rows = self.conn.execute(
            "SELECT * FROM interaction WHERE person_id = ? ORDER BY id", [person_id]
        )
        return [
            Interaction(
                id=r["id"], person_id=r["person_id"], timestamp=r["timestamp"],
                summary=r["summary"], kind=r["kind"], transcript=r["transcript"],
            )
            for r in rows
        ]  # fmt: skip

    def add_interaction(self, person_id: int, e: Interaction) -> Interaction:
        cur = self.conn.execute(
            "INSERT INTO interaction (person_id, timestamp, summary, kind, transcript)"
            " VALUES (?, ?, ?, ?, ?)",
            [person_id, e.timestamp, e.summary, e.kind, e.transcript],
        )
        e.id, e.person_id = cur.lastrowid, person_id
        return e

    # -- topics

    def topics(self, person_id: int) -> list[Topic]:
        rows = self.conn.execute(
            "SELECT * FROM topic WHERE person_id = ? ORDER BY id", [person_id]
        )
        return [Topic(id=r["id"], person_id=r["person_id"], label=r["label"]) for r in rows]

    def add_topic(self, person_id: int, label: str) -> Topic:
        cur = self.conn.execute(
            "INSERT INTO topic (person_id, label) VALUES (?, ?)", [person_id, label]
        )
        return Topic(id=cur.lastrowid, person_id=person_id, label=label)

    # -- things

    def things(self) -> list[Thing]:
        rows = self.conn.execute("SELECT * FROM thing ORDER BY id")
        return [
            Thing(
                id=r["id"], name=r["name"], category=r["category"],
                context=r["context"], closeness=r["closeness"], recency=r["recency"],
            )
            for r in rows
        ]  # fmt: skip

    def add_thing(self, t: Thing) -> Thing:
        cur = self.conn.execute(
            "INSERT INTO thing (name, category, context, closeness, recency)"
            " VALUES (?, ?, ?, ?, ?)",
            [t.name, t.category, t.context, t.closeness, t.recency],
        )
        t.id = cur.lastrowid
        return t

    # -- everything

    def clear(self) -> None:
        for table in ("interaction", "topic", "person", "thing"):
            self.conn.execute(f"DELETE FROM {table}")


def db_path() -> Path:
    """Where the database lives. Read on every call so DB_PATH can change."""
    return Path(os.environ.get("DB_PATH") or DEFAULT_DB_PATH)


_ready: set[str] = set()
_ready_lock = threading.Lock()


def _connect() -> sqlite3.Connection:
    path = db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    missing = not path.exists()
    conn = sqlite3.connect(path, timeout=10)
    conn.row_factory = sqlite3.Row
    with _ready_lock:
        # Create the tables once per database file, not once per request.
        if missing or str(path) not in _ready:
            conn.execute("PRAGMA journal_mode = WAL")
            conn.executescript(SCHEMA)
            _ready.add(str(path))
    return conn


@contextmanager
def session() -> Iterator[Store]:
    """A unit of work: everything written inside is saved together when the
    block ends, or not at all if it raises."""
    conn = _connect()
    try:
        yield Store(conn)
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()
