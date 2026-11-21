"""Pure functions: name matching, similarity, and the non-image path."""

from conftest import NOT_AN_IMAGE

from server.faces import embed_face, thumbnail
from server.logic import cached_card, card_fingerprint, cosine, same_person, store_card
from server.store import Person


def test_same_person_matches_an_exact_name():
    assert same_person("Sarah Chen", "Sarah Chen")


def test_same_person_is_case_and_whitespace_insensitive():
    assert same_person("  sarah chen ", "Sarah Chen")


def test_same_person_matches_a_first_name_to_a_full_name():
    # The bug this exists for: "Sarah again" on a second meeting created a
    # duplicate person instead of landing on the existing "Sarah Chen".
    assert same_person("Sarah", "Sarah Chen")
    assert same_person("Sarah Chen", "Sarah")


def test_same_person_matches_on_surname_alone():
    assert same_person("Chen", "Sarah Chen")


def test_same_person_rejects_different_people():
    assert not same_person("Sarah Chen", "Marcus Webb")
    assert not same_person("Sarah Chen", "Sarah Kim")


def test_same_person_rejects_empty_input_rather_than_matching_everything():
    assert not same_person("", "Sarah Chen")
    assert not same_person("Sarah Chen", "")
    assert not same_person("   ", "Sarah Chen")


def test_cosine_of_a_vector_with_itself_is_1():
    v = [1.0, 2.0, 3.0, 4.0]
    assert cosine(v, v) > 0.9999


def test_cosine_of_orthogonal_vectors_is_0():
    assert cosine([1.0, 0.0], [0.0, 1.0]) < 0.0001


def test_cosine_is_0_for_empty_or_mismatched_vectors_never_an_error():
    assert cosine([], [1.0, 2.0]) == 0.0
    assert cosine([1.0, 2.0], []) == 0.0
    assert cosine([1.0, 2.0], [1.0, 2.0, 3.0]) == 0.0


def test_cosine_survives_a_zero_vector_without_dividing_by_zero():
    assert cosine([0.0, 0.0], [1.0, 2.0]) == 0.0


def test_embed_face_returns_empty_for_input_that_is_not_an_image():
    # Must degrade to "no face" rather than raising - the endpoints treat an
    # empty vector as "say nothing", which is the safe behaviour.
    assert embed_face(NOT_AN_IMAGE) == []
    assert embed_face("") == []
    assert embed_face("%%% not even base64 %%%") == []


def test_thumbnail_of_an_unreadable_photo_is_empty_not_an_error():
    assert thumbnail("") == ""
    assert thumbnail(NOT_AN_IMAGE) == ""


def test_person_defaults_are_safe_to_read_before_anything_is_enrolled():
    p = Person(name="Blank Slate")
    assert p.face_vec == []
    assert p.photo_b64 == ""
    assert p.interests == []
    assert p.followups == []
    assert p.org == ""


def test_person_lists_are_not_shared_between_people():
    a, b = Person(name="A"), Person(name="B")
    a.interests.append("chess")
    assert b.interests == []


def test_a_stored_card_is_reused_only_while_the_facts_are_unchanged():
    who = Person(name="Sarah Chen", org="Acme")
    key = card_fingerprint(who, "history")
    assert cached_card(who, key) is None

    store_card(who, key, "Sarah Chen, Acme", ["Ask about pricing"])
    assert cached_card(who, key) == ("Sarah Chen, Acme", ["Ask about pricing"])

    who.followups.append("send the deck")
    assert cached_card(who, card_fingerprint(who, "history")) is None


def test_a_new_photo_does_not_invalidate_the_card():
    who = Person(name="Sarah Chen")
    before = card_fingerprint(who, "")
    who.photo_b64 = "abc"
    assert card_fingerprint(who, "") == before


def test_a_corrupt_stored_card_is_rebuilt_rather_than_crashing():
    who = Person(name="Sarah Chen", card_key="k", card_json="{not json")
    assert cached_card(who, "k") is None
