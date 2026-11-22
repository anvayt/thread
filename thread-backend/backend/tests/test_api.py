"""The HTTP endpoints, run against a real (temporary) database.

Deliberately covers the logic that is easy to break rather than the parts
never in doubt: name resolution, seeding twice, the face/conversation join,
the deterministic caption path, and what happens without a language model.
"""

from conftest import NOT_AN_IMAGE, REAL_TASKS

from server import agent, faces, llm
from server.store import Interaction, Person, Thing, session


def names(api) -> list[str]:
    return [p["name"] for p in api("roster")["people"]]


def add_person(**fields) -> Person:
    with session() as db:
        return db.add_person(Person(**fields))


def add_trio() -> None:
    """Three people with nothing but their details on record: no meetings,
    no topics, no faces."""
    add_person(name="Sarah Chen", role="VP Product", org="Acme",
               relationship="met at the Series A demo day",
               last_interaction="talked through their Series B raise",
               closeness=0.9, recency=0.9)  # fmt: skip
    add_person(name="Marcus Webb", role="Engineering Lead", org="Northwind",
               relationship="former colleague",
               last_interaction="promised to send the migration write-up",
               closeness=0.6, recency=0.4)  # fmt: skip
    add_person(name="Priya Raman", role="Partner", org="Fieldstone Capital",
               relationship="introduced by Sarah",
               last_interaction="brief hallway chat about the seed round",
               closeness=0.3, recency=0.2)  # fmt: skip


def add_interaction(person: Person, **fields) -> None:
    with session() as db:
        db.add_interaction(person.id, Interaction(**fields))


# ------------------------------------------------------------------ seeding


def test_seed_populates_an_empty_store(api):
    got = api("seed")
    assert got["seeded"] is True
    assert got["people"] == 5
    assert got["things"] == 0, "the sample data has no things in it"
    assert set(got["added"]) == set(names(api))
    assert {"Renata Okoye", "Tobias Hale", "Jonah Bergstrom"} <= set(names(api))
    assert api("roster")["things"] == []


def test_seed_is_idempotent_pressing_it_twice_does_not_duplicate_everyone(api):
    api("seed")
    before = names(api)
    again = api("seed")
    api("seed")
    assert again["added"] == []
    assert names(api) == before
    assert all(p["encounters"] == 1 for p in api("roster")["people"])


def test_seeded_people_carry_the_context_the_cards_are_built_from(api, db):
    api("seed")
    for p in db.people():
        assert p.role and p.org and p.last_interaction and p.notes
        assert p.followups
    tobias = next(p for p in db.people() if p.name == "Tobias Hale")
    assert tobias.org == "Wrenfield Robotics"


def test_seeded_people_carry_the_weights_recognition_scores_with(api, db):
    api("seed")
    people = db.people()
    assert len(people) >= 4
    for p in people:
        assert 0.0 <= p.closeness <= 1.0
        assert 0.0 <= p.recency <= 1.0


def test_seeded_people_each_have_a_conversation_and_topics_that_link_them(api, db):
    api("seed")
    net = agent.Network.load(db)
    for k in net.people:
        assert len(k.topics) >= 2
        [meeting] = k.meetings
        assert meeting.kind == "conversation"
        assert meeting.transcript and meeting.summary
        assert meeting.timestamp <= api("timeline")["events"][-1]["ts"]
    # shared topics and a shared company are what the map draws links from
    pairs = "\n".join(agent.shared_ground(net))
    assert "Devika Rao & Renata Okoye: " in pairs and "ml internships" in pairs
    assert "Jonah Bergstrom & Tobias Hale: " in pairs and "both at Wrenfield Robotics" in pairs


def test_seeded_follow_ups_read_the_right_way_round(api, db):
    api("seed")
    owed = {p.name: [agent.owed_by(f) for f in p.followups] for p in db.people()}
    assert owed == {
        "Renata Okoye": ["you"],
        "Tobias Hale": ["them"],
        "Devika Rao": ["you"],
        "Jonah Bergstrom": ["you"],
        "Priscilla Tan": ["them"],
    }


def test_the_seed_has_answers_to_the_questions_the_map_suggests(api, db):
    api("seed")
    net = agent.Network.load(db)
    # "Who's hiring ML interns?"
    hiring = agent.find_people(net, "hiring ML interns")
    assert hiring.splitlines()[0].startswith(("- Renata Okoye", "- Devika Rao"))
    assert "Renata Okoye" in hiring and "Devika Rao" in hiring
    # "Who should I talk to about robotics?"
    robotics = agent.topic(net, "robotics")
    assert "Tobias Hale" in robotics and "Jonah Bergstrom" in robotics
    assert "Renata" not in robotics
    # "Who do I owe a follow-up?"
    mine, theirs = agent.promises(net).split("These people owe you (they said they'd do it for you):")
    assert mine.count("\n- ") == 3 and "Renata Okoye" in mine and "Tobias" not in mine
    assert "Tobias Hale" in theirs and "Priscilla Tan" in theirs


def test_reset_empties_everything(api):
    api("seed")
    assert api("reset")["cleared"] == 5
    roster = api("roster")
    assert roster["people"] == []
    assert roster["things"] == []
    assert api("timeline")["events"] == []


# ------------------------------------------------------------- enrol / faces


def test_enroll_reports_a_miss_when_no_face_is_present_and_stores_nothing(api):
    got = api("enroll", {"name": "Faceless", "frame_b64": NOT_AN_IMAGE})
    assert got["enrolled"] is False
    assert "no face" in got["reason"]
    assert "Faceless" not in names(api)


def test_enroll_needs_a_name(api):
    got = api("enroll", {"name": "  ", "frame_b64": NOT_AN_IMAGE})
    assert got["enrolled"] is False


def test_enroll_ignores_extra_fields_a_client_sends(api):
    got = api(
        "enroll", {"name": "Faceless", "frame_b64": NOT_AN_IMAGE, "photo_b64": NOT_AN_IMAGE}
    )
    assert got["enrolled"] is False


def test_enroll_attaches_a_face_to_the_person_a_conversation_created(api, fake, monkeypatch):
    # The join the whole product rests on: the conversation is filed first,
    # the face arrives later under a shorter name, and both must end up on
    # one record.
    fake.contact = llm.ContactInfo(
        name="Dana Okafor", org="Lumen", interests=[], followups=[], topics=["robotics"]
    )
    api("ingest", {"transcript": "Hi, I'm Dana Okafor from Lumen."})

    monkeypatch.setattr(faces, "embed_face", lambda _frame: [0.1] * 128)
    got = api("enroll", {"name": "dana", "frame_b64": "frame", "role": "CTO"})

    assert got["enrolled"] is True
    assert got["name"] == "Dana Okafor"
    assert got["attached_to_existing"] is True
    assert got["known_interactions"] == 1
    assert got["dims"] == 128

    roster = api("roster")["people"]
    assert len(roster) == 1
    assert roster[0]["enrolled_face"] is True
    assert roster[0]["role"] == "CTO"
    assert roster[0]["org"] == "Lumen", "enrolling must not blank what the conversation captured"


def test_enroll_creates_a_new_person_when_nobody_matches(api, monkeypatch):
    monkeypatch.setattr(faces, "embed_face", lambda _frame: [0.2] * 128)
    got = api("enroll", {"name": "New Face", "frame_b64": "frame", "org": "Initech"})
    assert got["enrolled"] is True
    assert got["attached_to_existing"] is False
    assert got["known_interactions"] == 0
    assert names(api) == ["New Face"]


def test_roster_exposes_photo_and_face_status_so_clients_can_render_a_face(api):
    add_trio()
    people = api("roster")["people"]
    assert people
    for p in people:
        assert "photo_b64" in p
        assert p["enrolled_face"] is False
        assert p["encounters"] == 0


def test_recognize_stays_silent_and_records_nothing_for_a_stranger(api, monkeypatch):
    add_person(name="Sarah Chen", face_vec=[1.0, 0.0, 0.0])
    monkeypatch.setattr(faces, "embed_face", lambda _frame: [0.0, 1.0, 0.0])

    got = api("recognize", {"frame_b64": "frame"})

    assert got["matched"] is False
    assert got["spoken"] == ""
    assert "name" not in got
    assert api("timeline")["events"] == []


def test_recognize_with_no_face_in_frame_is_a_quiet_miss(api):
    add_trio()
    got = api("recognize", {"frame_b64": NOT_AN_IMAGE})
    assert got["matched"] is False
    assert got["score"] == 0.0


def test_recognize_names_a_known_face_and_logs_the_sighting(api, fake, monkeypatch):
    sarah = add_person(name="Sarah Chen", org="Acme", role="VP Product", face_vec=[1.0, 0.0])
    add_person(name="Marcus Webb", face_vec=[0.0, 1.0])
    add_interaction(sarah, timestamp="2026-01-01 09:00:00", summary="pricing", kind="conversation")
    monkeypatch.setattr(faces, "embed_face", lambda _frame: [0.9, 0.1])
    fake.line = "Sarah still has a pricing question."

    got = api("recognize", {"frame_b64": "frame"})

    assert got["matched"] is True
    assert got["name"] == "Sarah Chen"
    assert got["org"] == "Acme"
    assert got["spoken"] == "Sarah still has a pricing question."
    assert got["score"] > faces.FACE_THRESHOLD
    # The whisper was written from what was actually said last time.
    assert "pricing" in fake.calls[0][1][-1]
    events = api("timeline")["events"]
    assert len(events) == 2
    assert "whispered: Sarah still has a pricing question." in events[-1]["text"]


def test_recognize_prefers_the_closer_tie_when_two_faces_score_alike(api, fake, monkeypatch):
    add_person(name="Faint Acquaintance", face_vec=[1.0, 0.0], closeness=0.0, recency=0.0)
    add_person(name="Close Friend", face_vec=[1.0, 0.0], closeness=1.0, recency=1.0)
    monkeypatch.setattr(faces, "embed_face", lambda _frame: [1.0, 0.0])
    assert api("recognize", {"frame_b64": "frame"})["name"] == "Close Friend"


def test_recognize_still_names_the_person_when_the_language_model_is_down(api, monkeypatch):
    add_person(name="Sarah Chen", face_vec=[1.0, 0.0])
    monkeypatch.setattr(faces, "embed_face", lambda _frame: [1.0, 0.0])

    def down(*_args):
        raise llm.LLMError("unreachable")

    monkeypatch.setattr(llm, "compose", down)
    got = api("recognize", {"frame_b64": "frame"})

    assert got["matched"] is True
    assert got["name"] == "Sarah Chen"
    assert got["spoken"] == ""
    assert api("timeline")["events"][0]["text"] == "Sarah Chen - Recognised in frame"


def test_glance_shapes_the_same_match_for_a_lens(api, fake, monkeypatch):
    add_person(name="Sarah Chen", face_vec=[1.0, 0.0])
    monkeypatch.setattr(faces, "embed_face", lambda _frame: [1.0, 0.0])
    got = api("glance", {"image_b64": "frame"})
    assert got["matched"] == "Sarah Chen"
    assert got["whisper"]["kind"] == "recognition"
    assert got["whisper"]["text"] == fake.line

    monkeypatch.setattr(faces, "embed_face", lambda _frame: [])
    missed = api("glance", {"image_b64": "frame"})
    assert missed["matched"] == ""
    assert missed["whisper"] == {"text": "", "kind": "reassurance", "confidence": 0.0}


# ------------------------------------------------------------- conversations


def test_ingest_files_a_conversation_under_the_person_who_introduced_themselves(api, fake):
    fake.contact = llm.ContactInfo(
        name="Dana Okafor", role="CTO", org="Lumen",
        interests=["robotics"], followups=["send the deck"], topics=["robotics", "hiring"],
    )  # fmt: skip
    got = api("ingest", {"transcript": "Hi, I'm Dana, CTO at Lumen."})

    assert got["saved"] == "Dana Okafor"
    assert got["new_person"] is True
    assert got["org"] == "Lumen"
    assert got["role"] == "CTO"
    assert got["topics"] == ["robotics", "hiring"]
    assert got["new_topics"] == ["robotics", "hiring"]
    assert got["followups"] == ["send the deck"]

    person = api("roster")["people"][0]
    assert person["relationship"] == "met at an event"
    assert person["encounters"] == 1
    assert api("timeline")["events"][0]["text"] == "Dana Okafor - robotics, hiring"


def test_ingest_gives_a_name_heard_without_capitals_its_capitals(api, fake):
    fake.contact = llm.ContactInfo(
        name="krishna  iyer", org="", interests=[], followups=[], topics=[]
    )
    assert api("ingest", {"transcript": "hi im krishna iyer"})["saved"] == "Krishna Iyer"

    # one that came with capitals is kept as it was heard
    fake.contact = llm.ContactInfo(
        name="DeShawn van der Berg", org="", interests=[], followups=[], topics=[]
    )
    assert api("ingest", {"transcript": "I'm DeShawn."})["saved"] == "DeShawn van der Berg"


def test_ingest_never_files_the_wearer_as_the_contact(api, fake):
    fake.contact = llm.ContactInfo(
        name="Sam Rivera", org="", interests=[], followups=[], topics=["design"],
    )  # fmt: skip
    got = api("ingest", {"transcript": "Hi, I'm Sam.", "wearer": "Sam Rivera"})

    assert got["saved"] == ""
    assert names(api) == []
    assert fake.calls[-1] == ("extract_contact", ("Hi, I'm Sam.", "Sam Rivera"))


def test_ingest_without_a_wearer_is_unchanged(api, fake):
    fake.contact = llm.ContactInfo(
        name="Sam Rivera", org="", interests=[], followups=[], topics=[],
    )  # fmt: skip
    got = api("ingest", {"transcript": "Hi, I'm Sam."})

    assert got["saved"] == "Sam Rivera"
    assert fake.calls[-1] == ("extract_contact", ("Hi, I'm Sam.",))


def test_ingest_lands_a_first_name_on_the_existing_person(api, fake):
    add_trio()
    fake.contact = llm.ContactInfo(
        name="Sarah", org="Somewhere Else", interests=["climbing"],
        followups=[], topics=["Series B"],
    )  # fmt: skip
    got = api("ingest", {"transcript": "It's Sarah again."})

    assert got["saved"] == "Sarah Chen"
    assert got["new_person"] is False
    assert got["org"] == "Acme", "an org already on record is not overwritten"
    assert len(names(api)) == 3


def test_ingest_does_not_repeat_topics_interests_or_followups(api, fake):
    fake.contact = llm.ContactInfo(
        name="Dana Okafor", org="", interests=["robotics"],
        followups=["send the deck"], topics=["Robotics", "hiring"],
    )  # fmt: skip
    api("ingest", {"transcript": "one"})
    fake.contact = llm.ContactInfo(
        name="Dana Okafor", org="", interests=["robotics", "sailing"],
        followups=["send the deck"], topics=["robotics", "funding"],
    )  # fmt: skip
    second = api("ingest", {"transcript": "two"})

    assert second["new_topics"] == ["funding"]
    assert second["followups"] == ["send the deck"]
    topic_nodes = [n["label"] for n in api("graph")["nodes"] if n["kind"] == "topic"]
    assert topic_nodes == ["Robotics", "hiring", "funding"]


def test_ingest_prefers_an_explicit_speaker_over_a_name_the_model_heard(api, fake):
    add_trio()
    fake.contact = llm.ContactInfo(
        name="Sarah", org="", interests=[], followups=[], topics=["migration"]
    )
    got = api("ingest", {"transcript": "Sarah said hi.", "speaker": "Marcus Webb"})
    assert got["saved"] == "Marcus Webb"


def test_ingest_refuses_to_guess_a_name_and_stores_nothing(api, fake):
    got = api("ingest", {"transcript": "Nice weather today."})
    assert got["saved"] == ""
    assert "not guessing" in got["reason"]
    assert names(api) == []


def test_ingest_without_topics_still_records_that_a_conversation_happened(api, fake):
    fake.contact = llm.ContactInfo(name="Dana", org="", interests=[], followups=[], topics=[])
    api("ingest", {"transcript": "I'm Dana."})
    assert api("timeline")["events"][0]["text"] == "Dana - a conversation"


# ------------------------------------------------------------------- lookup


def test_lookup_reports_not_found_rather_than_inventing_a_person(api):
    got = api("lookup", {"name": "Nobody Ever Met This Person"})
    assert got["found"] is False


def test_lookup_last_on_an_empty_store_finds_nobody(api):
    assert api("lookup")["found"] is False


def test_lookup_builds_a_card_once_then_serves_it_from_the_cache(api, fake):
    add_trio()
    fake.card = llm.Card(headline="Sarah Chen, Acme", lines=["Ask about pricing tiers"])

    first = api("lookup", {"name": "sarah"})
    second = api("lookup", {"name": "sarah"})

    assert first["found"] is True
    assert first["cached"] is False
    assert first["name"] == "Sarah Chen"
    assert first["headline"] == "Sarah Chen, Acme"
    assert first["lines"] == ["Ask about pricing tiers"]
    assert second["cached"] is True
    assert second["lines"] == first["lines"]
    assert fake.count("lookup_card") == 1


def test_lookup_rebuilds_the_card_when_something_new_is_learned(api, fake):
    add_trio()
    api("lookup", {"name": "Sarah"})
    fake.contact = llm.ContactInfo(
        name="Sarah Chen", org="", interests=[], followups=["intro to Priya"], topics=["pricing"]
    )
    api("ingest", {"transcript": "..."})

    got = api("lookup", {"name": "Sarah"})

    assert got["cached"] is False
    assert fake.count("lookup_card") == 2
    assert got["topics"] == ["pricing"]
    assert got["followups"] == ["intro to Priya"]
    assert got["history"][-1]["kind"] == "conversation"
    assert got["history"][-1]["what"] == "pricing"


def test_lookup_last_returns_whoever_was_interacted_with_most_recently(api, fake):
    add_trio()
    with session() as db:
        by_name = {p.name: p for p in db.people()}
    add_interaction(by_name["Priya Raman"], timestamp="2026-03-01 10:00:00", summary="older")
    add_interaction(by_name["Marcus Webb"], timestamp="2026-03-02 10:00:00", summary="newer")
    assert api("lookup", {"name": "last"})["name"] == "Marcus Webb"
    assert api("lookup")["name"] == "Marcus Webb"


def test_person_card_is_markdown_with_the_heading_the_lens_reads(api, fake):
    fake.contact = llm.ContactInfo(
        name="Dana Okafor", org="Lumen", interests=[],
        followups=["send the deck"], topics=["robotics"],
    )  # fmt: skip
    api("ingest", {"transcript": "..."})
    fake.card = llm.Card(headline="Dana Okafor, Lumen", lines=["Ask about the robot arm"])

    got = api("person_card", {"name": "dana"})

    assert got["name"] == "Dana Okafor"
    md = got["md"]
    assert md.startswith("# Dana Okafor\n\n*Lumen*\n\n> Dana Okafor, Lumen\n\n")
    assert "## Things to ask about\n- Ask about the robot arm\n" in md
    assert "\n## Discussed\nrobotics\n" in md
    assert "\n## You owe them\n- send the deck\n" in md
    assert "\n## History\n- `" in md


def test_person_card_shares_the_cache_with_lookup_unless_refreshed(api, fake):
    add_trio()
    api("lookup", {"name": "Sarah"})
    api("person_card", {"name": "Sarah"})
    assert fake.count("lookup_card") == 1
    api("person_card", {"name": "Sarah", "refresh": True})
    assert fake.count("lookup_card") == 2


def test_person_card_for_an_unknown_name_says_so(api):
    got = api("person_card", {"name": "Nobody"})
    assert got["md"].startswith("**Nobody** is not in")


# ---------------------------------------------------------------- follow-up


def test_followup_drafts_from_what_is_on_record_and_nothing_else(api, fake):
    api("seed")
    fake.message = "Hi Renata, thanks for the chat about ML internships."

    got = api("followup", {"name": "renata", "wearer": "Alex"})

    assert got == {"name": "Renata Okoye", "message": fake.message}
    [args] = [args for name, args in fake.calls if name == "draft_followup"]
    name, role, org, topics, you_owe, they_owe, other, last, heard, wearer = args
    assert (name, role, org) == ("Renata Okoye", "University Recruiter", "Brightfern AI")
    assert topics == "ML internships, recommendation systems"
    assert you_owe == "send them the resume and the capstone repo link"
    assert they_owe == "" and other == ""
    assert last == "ML internships, recommendation systems"
    assert heard.startswith("Hi, I'm Renata Okoye")
    assert wearer == "Alex"
    # only this person's record goes to the model
    assert "Tobias" not in " ".join(args) and "Wrenfield" not in " ".join(args)


def test_followup_tells_the_model_which_way_each_promise_runs(api, fake):
    add_person(
        name="Dana Okafor",
        followups=["send you the open roles", "send them the deck", "coffee next week"],
    )
    api("followup", {"name": "Dana Okafor"})
    args = fake.calls[-1][1]
    assert args[4:7] == ("send them the deck", "send you the open roles", "coffee next week")
    assert args[-1] == ""


def test_followup_for_someone_with_almost_nothing_on_record_sends_only_the_name(api, fake):
    add_person(name="Sam Rivera")
    got = api("followup", {"name": "Sam Rivera"})
    assert got["name"] == "Sam Rivera"
    assert fake.calls[-1][1] == ("Sam Rivera", "", "", "", "", "", "", "", "", "")


def test_followup_uses_the_last_conversation_not_a_sighting(api, fake):
    dana = add_person(name="Dana Okafor", last_interaction="robotics")
    add_interaction(dana, timestamp="2026-05-01 10:00:00", summary="robotics",
                    kind="conversation", transcript="We build  robot\narms.")  # fmt: skip
    add_interaction(dana, timestamp="2026-05-02 10:00:00", summary="Recognised in frame")
    api("followup", {"name": "Dana"})
    args = fake.calls[-1][1]
    assert args[7:9] == ("robotics", "We build robot arms.")


def test_followup_saves_nothing(api, fake):
    api("seed")
    before = api("timeline")["events"]
    api("followup", {"name": "Tobias Hale"})
    assert api("timeline")["events"] == before
    assert fake.count("lookup_card") == 0


def test_followup_comes_back_as_plain_text(api, fake):
    add_person(name="Dana Okafor")
    fake.message = (
        'Subject: Great to meet you\n\n**Hi Dana**, good to meet you.\n\n\n\nBest,\n[Your Name]'
    )
    got = api("followup", {"name": "Dana"})
    assert got["message"] == "Hi Dana, good to meet you.\n\nBest,"


def test_followup_for_an_unknown_name_is_an_error(api, fake):
    add_trio()
    for name in ("Nobody Ever Met", "   "):
        response = api.raw("followup", {"name": name})
        assert response.status_code == 404
        body = response.json()
        assert body["ok"] is False
        assert "on record" in body["error"]
    assert fake.count("draft_followup") == 0


def test_followup_reports_a_language_model_outage(api, monkeypatch):
    add_trio()

    def down(*_args):
        raise llm.LLMError("The language model request failed: timeout")

    monkeypatch.setattr(llm, "draft_followup", down)
    response = api.raw("followup", {"name": "Sarah"})
    assert response.status_code == 503
    assert response.json() == {"ok": False, "error": "The language model request failed: timeout"}


def test_followup_with_an_empty_draft_is_an_error_not_a_blank_message(api, fake):
    add_trio()
    fake.message = "  \n"
    response = api.raw("followup", {"name": "Sarah"})
    assert response.status_code == 503
    assert response.json()["ok"] is False


def test_person_card_lists_follow_ups_under_whoever_owes_them(api, fake):
    api("seed")
    md = api("person_card", {"name": "Tobias"})["md"]
    assert "\n## They owe you\n- send you the link to the perception team's open roles\n" in md
    assert "## You owe them" not in md
    md = api("person_card", {"name": "Renata"})["md"]
    assert "\n## You owe them\n- send them the resume and the capstone repo link\n" in md
    assert "## They owe you" not in md


# -------------------------------------------------------------------- query


def test_query_on_an_empty_store_returns_no_matches_rather_than_guessing(api):
    got = api("query", {"question": ""})
    assert got["matches"] == []


def test_query_with_an_empty_question_asks_nobody(api):
    add_trio()
    got = api("query", {"question": "   "})
    assert got["matches"] == []
    assert got["searched"] == 3


def test_query_gives_the_model_the_roster_and_reports_who_it_picked(api, fake):
    add_trio()
    fake.matches = llm.Matches(names=["Priya Raman"], reason="Priya is the investor.")

    got = api("query", {"question": "who invests?"})

    assert got["matches"] == [
        {"name": "Priya Raman", "org": "Fieldstone Capital",
         "last": "brief hallway chat about the seed round"}
    ]  # fmt: skip
    assert got["reason"] == "Priya is the investor."
    assert got["searched"] == 3
    # the agent was tried first; this server can't call tools
    assert fake.count("agent_turn") == 1
    [(question, roster)] = [args for name, args in fake.calls if name == "pick_matches"]
    assert question == "who invests?"
    assert "Marcus Webb | Engineering Lead | Northwind |" in roster


def test_query_never_reports_a_person_who_is_not_on_record(api, fake):
    add_trio()
    fake.matches = llm.Matches(names=["Quinn Halloway", "Sarah Chen"], reason="r")
    got = api("query", {"question": "who?"})
    assert [m["name"] for m in got["matches"]] == ["Sarah Chen"]


def test_query_forgives_a_mistyped_name_only_when_it_is_unambiguous(api, fake):
    add_trio()
    add_person(name="Sarah Kim")

    # "Priva Raman" shares exactly one whole word with exactly one person.
    fake.matches = llm.Matches(names=["Priva Raman"], reason="r")
    assert [m["name"] for m in api("query", {"question": "q"})["matches"]] == ["Priya Raman"]

    # "Sarah Lopez" shares a word with two people - never a guess.
    fake.matches = llm.Matches(names=["Sarah Lopez"], reason="r")
    assert api("query", {"question": "q"})["matches"] == []


def test_query_lists_a_person_once_even_if_picked_twice(api, fake):
    add_trio()
    fake.matches = llm.Matches(names=["Marcus Webb", "Marcus", "Webb"], reason="r")
    assert len(api("query", {"question": "q"})["matches"]) == 1


def test_query_is_answered_by_the_agent_with_its_links_and_steps(api, fake):
    add_trio()
    fake.turns = [
        llm.Turn(calls=[llm.ToolCall(id="c1", name="person", args={"name": "Priya"})]),
        llm.Turn(calls=[llm.ToolCall(id="c2", name="answer", args={
            "text": "Priya Raman: Sarah introduced you.",
            "people": ["Priya Raman"],
            "links": [{"from": "Priya Raman", "to": "Sarah Chen", "via": "introduced by Sarah"}],
        })]),
    ]  # fmt: skip

    got = api("query", {"question": "who invests?", "wearer": "Alex"})

    assert got["agent"] is True
    assert got["reason"] == "Priya Raman: Sarah introduced you."
    assert [m["name"] for m in got["matches"]] == ["Priya Raman", "Sarah Chen"]
    assert got["links"] == [{"from": "Priya Raman", "to": "Sarah Chen", "kind": "person",
                             "via": "introduced by Sarah"}]  # fmt: skip
    assert got["steps"] == ["Read about Priya Raman"]
    assert got["searched"] == 3
    assert fake.count("pick_matches") == 0
    assert "The wearer's own name is Alex" in fake.agent_steps[0][0][0]["content"]


def test_query_with_nemotron_down_says_so_without_asking_again_the_simple_way(api, fake):
    add_trio()
    fake.agent_error = llm.LLMError("Nemotron isn't answering right now.", unreachable=True)

    response = api.raw("query", {"question": "who invests?"})

    assert response.status_code == 503
    assert response.json() == {"ok": False, "error": "Nemotron isn't answering right now."}
    assert fake.count("pick_matches") == 0


def test_query_falls_back_to_the_simple_way_when_the_agent_cannot_finish(api, fake):
    add_trio()
    fake.agent_error = llm.LLMError("The language model didn't finish answering.")
    fake.matches = llm.Matches(names=["Sarah Chen"], reason="Sarah works on pricing.")

    got = api("query", {"question": "who works on pricing?"})

    assert [m["name"] for m in got["matches"]] == ["Sarah Chen"]
    assert fake.count("pick_matches") == 1


# ---------------------------------------------------------------- dashboard


def test_graph_emits_nodes_and_links_the_dashboard_can_draw(api, fake):
    add_trio()
    with session() as db:
        db.add_thing(Thing(name="badge", category="everyday carry"))
    fake.contact = llm.ContactInfo(
        name="Sarah Chen", org="", interests=[], followups=[], topics=["pricing"]
    )
    api("ingest", {"transcript": "..."})

    got = api("graph")
    nodes, links = got["nodes"], got["links"]

    assert {n["kind"] for n in nodes} == {"person", "encounter", "topic", "object"}
    ids = [n["id"] for n in nodes]
    assert len(ids) == len(set(ids)), "node ids must be unique"
    for n in nodes:
        assert n["label"]
    assert {link["kind"] for link in links} == {"had", "discussed"}
    for link in links:
        assert link["source"] in ids and link["target"] in ids


def test_timeline_is_ordered_oldest_first(api):
    late = add_person(name="Late")
    early = add_person(name="Early")
    add_interaction(late, timestamp="2026-05-02 10:00:00", summary="second")
    add_interaction(early, timestamp="2026-05-01 10:00:00", summary="first")

    events = api("timeline")["events"]

    assert [e["text"] for e in events] == ["Early - first", "Late - second"]
    assert all(e["kind"] == "encounter" for e in events)


def test_the_dashboard_page_is_served_at_the_root(api):
    response = api.client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]


def test_the_dashboard_is_always_rechecked_with_the_server(api):
    # Without this a browser may keep showing an older saved copy of the page.
    assert api.client.get("/").headers["cache-control"] == "no-cache"


# ----------------------------------------------------------------- captions


def test_caption_returns_empty_for_empty_input_and_never_calls_a_model(api):
    assert api("caption", {"text": "   ", "lang": "en"})["display_text"] == ""


def test_caption_tidies_a_short_fragment_deterministically(api):
    # Under three words never goes to a model, so this is exact.
    assert api("caption", {"text": "hello", "lang": "en"})["display_text"] == "Hello."
    assert api("caption", {"text": "test"})["display_text"] == "Test."
    assert api("caption", {"text": "ok", "lang": "en"})["display_text"] == "Ok."


def test_caption_keeps_punctuation_a_fragment_already_has(api):
    assert api("caption", {"text": "hello!", "lang": "en"})["display_text"] == "Hello!"


def test_caption_never_leaks_prompt_text_into_a_caption(api):
    leaks = ["captured speech", "speech-to-text", "I need actual input", "provide the"]
    for probe in ["hello", "ok", "hey there"]:
        shown = api("caption", {"text": probe, "lang": "en"})["display_text"]
        for bad in leaks:
            assert bad.lower() not in shown.lower(), f"leaked prompt text for {probe!r}: {shown!r}"


def test_caption_sends_longer_speech_and_translations_to_the_model(api, fake):
    fake.caption_text = "So, the launch went well."
    got = api("caption", {"text": "so um the launch went uh well", "lang": "en"})
    assert got["display_text"] == "So, the launch went well."

    fake.caption_text = "Hola."
    assert api("caption", {"text": "hello", "lang": "es"})["display_text"] == "Hola."
    assert fake.calls[-1] == ("caption_line", ("hello", "es"))


# --------------------------------------------------------------- forgetting


def test_forget_removes_a_person_and_everything_attached_to_them(api, fake):
    add_trio()
    fake.contact = llm.ContactInfo(
        name="Temporary Contact", org="", interests=[], followups=[], topics=["a chat"]
    )
    api("ingest", {"transcript": "..."})
    assert "Temporary Contact" in names(api)

    got = api("forget", {"name": "Temporary Contact"})

    assert got["forgotten"] == 1
    assert "Temporary Contact" not in names(api)
    assert len(names(api)) == 3
    assert api("timeline")["events"] == []
    assert not [n for n in api("graph")["nodes"] if n["kind"] in ("encounter", "topic")]


def test_forget_on_an_unknown_name_removes_nothing(api):
    add_trio()
    got = api("forget", {"name": "Never Existed"})
    assert got["forgotten"] == 0
    assert len(names(api)) == 3


def test_forget_with_an_empty_name_removes_nobody(api):
    add_trio()
    assert api("forget", {"name": "  "})["forgotten"] == 0
    assert len(names(api)) == 3


# ------------------------------------------------------------------- errors


def test_a_missing_field_is_reported_in_the_error_envelope(api):
    response = api.raw("recognize", {})
    assert response.status_code == 422
    body = response.json()
    assert body["ok"] is False
    assert "frame_b64" in body["error"]


def test_an_unknown_endpoint_is_reported_in_the_error_envelope(api):
    response = api.raw("no_such_thing")
    assert response.status_code == 404
    assert response.json()["ok"] is False


def test_a_language_model_outage_is_reported_not_crashed_on(api, monkeypatch):
    add_trio()

    def down(*_args):
        raise llm.LLMError("The language model request failed: timeout")

    monkeypatch.setattr(llm, "lookup_card", down)
    response = api.raw("lookup", {"name": "Sarah"})

    assert response.status_code == 503
    assert response.json() == {
        "ok": False,
        "error": "The language model request failed: timeout",
    }


def test_without_an_api_key_the_error_says_what_to_do(api, monkeypatch):
    # The real client code, not a stand-in: no key is configured in tests, and
    # NVIDIA's hosted API needs one, so the request is never sent.
    monkeypatch.setenv("LLM_BASE_URL", "https://integrate.api.nvidia.com/v1")
    monkeypatch.setattr(llm, "caption_line", REAL_TASKS["caption_line"])
    response = api.raw("caption", {"text": "a sentence long enough to need the model"})
    assert response.status_code == 503
    assert "LLM_API_KEY" in response.json()["error"]


def test_an_unexpected_failure_does_not_leak_details(api, monkeypatch):
    def boom(_frame):
        raise RuntimeError("secret internal detail")

    monkeypatch.setattr(faces, "embed_face", boom)
    response = api.raw("recognize", {"frame_b64": "frame"})

    assert response.status_code == 500
    body = response.json()
    assert body["ok"] is False
    assert "secret" not in body["error"]
