"""Pure helpers: name matching, vector similarity, card fingerprints.

Nothing here touches the database, the camera models or the network, so it
can be tested exactly.
"""

import json

from .store import Person


def same_person(a: str, b: str) -> bool:
    """Whether two spoken names refer to the same person.

    People rarely re-introduce themselves in full. "Sarah" on the second
    meeting has to land on the existing "Sarah Chen" rather than creating a
    duplicate, so a name matches when every word of the shorter one appears
    in the longer.
    """
    x = a.strip().lower()
    y = b.strip().lower()
    if not x or not y:
        return False
    if x == y:
        return True
    short, long_ = sorted((x.split(), y.split()), key=len)
    return all(word in long_ for word in short)


def cosine(a: list[float], b: list[float]) -> float:
    """Cosine similarity; 0.0 if either vector is empty, mismatched or zero."""
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a)
    nb = sum(y * y for y in b)
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / ((na**0.5) * (nb**0.5))


def card_fingerprint(who: Person, history: str) -> str:
    """Key for a memoised lookup card.

    A card is only as fresh as the facts it was written from, so fingerprint
    exactly those. Any change to the person or their history changes the key
    and the card is rebuilt; otherwise the stored one is reused and no model
    is called. Deliberately excludes the photo - a new photo does not change
    what there is to say about someone.
    """
    return "|".join(
        [
            who.name,
            who.role,
            who.org,
            who.relationship,
            ",".join(who.interests),
            ",".join(who.followups),
            history,
        ]
    )


def cached_card(who: Person, key: str) -> tuple[str, list[str]] | None:
    """The stored (headline, lines) if the facts behind it have not moved."""
    if who.card_key != key or not who.card_json:
        return None
    try:
        raw = json.loads(who.card_json)
        return str(raw["headline"]), [str(line) for line in raw["lines"]]
    except (ValueError, KeyError, TypeError):
        # A card written in an older shape is not worth a crash - rebuild it.
        return None


def store_card(who: Person, key: str, headline: str, lines: list[str]) -> None:
    who.card_key = key
    who.card_json = json.dumps({"headline": headline, "lines": lines})
