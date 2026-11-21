"""Ask as an agent: the tools it reads the network with, the loop that lets
the model use them, and the checks on what it answers.

The model is the scripted FakeLLM from conftest: each test lists the replies
it gives, one per step.
"""

import pytest

from server import agent, llm
from server.store import Interaction, Person, session


def call(tool: str, n: int = 0, /, **args) -> llm.ToolCall:
    return llm.ToolCall(id=f"call-{tool}-{n}", name=tool, args=args)


def answer(text: str, people: list[str], links: list[dict] | None = None) -> llm.Turn:
    args = {"text": text, "people": people}
    if links is not None:
        args["links"] = links
    return llm.Turn(calls=[call("answer", **args)])


@pytest.fixture
def net() -> agent.Network:
    """Three people: two who talked about payments, one at the same company
    as another, and a few meetings."""
    with session() as db:
        sarah = db.add_person(Person(name="Sarah Chen", role="VP Product", org="Acme",
                                     relationship="met at demo day", interests=["pricing"],
                                     followups=["send the metrics deck"]))  # fmt: skip
        dana = db.add_person(Person(name="Dana Okafor", role="Design", org="Lumen"))
        omar = db.add_person(Person(name="Omar Haddad", role="Engineer", org="Acme"))
        for who, label in ((sarah, "payments"), (sarah, "Series B"), (dana, "payments"),
                           (dana, "API docs"), (omar, "robotics")):  # fmt: skip
            db.add_topic(who.id, label)
        db.add_interaction(sarah.id, Interaction(timestamp="2026-11-20 09:00:00",
                                                 summary="coffee about pricing", kind="conversation",
                                                 transcript="We should talk about embedded payments."))  # fmt: skip
        db.add_interaction(dana.id, Interaction(timestamp="2026-11-21 11:12:00",
                                                summary="recognised in frame"))  # fmt: skip
        db.add_interaction(sarah.id, Interaction(timestamp="2026-11-21 08:30:00",
                                                 summary="hallway hello"))  # fmt: skip
        return agent.Network.load(db)


# -------------------------------------------------------------------- tools


def test_the_outline_lists_everyone_with_what_they_talked_about(net):
    text = agent.outline(net)
    assert text.startswith("Your network has 3 people.")
    assert "- Sarah Chen (VP Product, Acme); talked about payments, Series B; met 2 times" in text


def test_the_outline_lists_who_shares_what_most_first(net):
    text = agent.outline(net)
    assert "Who shares what, from the record:\n- Dana Okafor & Sarah Chen: payments\n" in text
    assert "- Omar Haddad & Sarah Chen: both at Acme" in text
    assert "Dana Okafor & Omar Haddad" not in text


def test_related_topics_count_as_common_ground():
    a = agent.Known(Person(name="Dana", id=1), ["embedded payments", "API docs"], [])
    b = agent.Known(Person(name="Lena", id=2), ["payments infrastructure", "fintech"], [])
    c = agent.Known(Person(name="Omar", id=3), ["robotics"], [])
    assert agent.common(a, b) == ["embedded payments / payments infrastructure"]
    assert agent.common(a, c) == []


def test_being_asked_to_send_something_is_a_follow_up_you_owe():
    assert agent.owed_by("Send me anything in embedded payments") == "you"
    assert agent.owed_by("send you our demo video") == "them"
    assert agent.owed_by("send the metrics deck") == ""
    # their own words kept: "your" is in it, and it is still the wearer's to do
    assert agent.owed_by("Send me your resume tonight") == "you"
    assert agent.owed_by("send them your resume") == "you"
    assert agent.owed_by("send you my slides") == "them"


def test_find_people_searches_topics_promises_and_meetings(net):
    assert "Dana Okafor" in agent.find_people(net, "api docs")
    assert "Sarah Chen (VP Product, Acme): matched in promises" in agent.find_people(net, "deck")
    assert agent.find_people(net, "submarines") == "Nobody matches “submarines”."


def test_person_gives_their_page_with_meetings_newest_first(net):
    page = agent.person(net, "Sarah")
    assert page.splitlines()[0] == "Sarah Chen (VP Product, Acme)"
    assert "Follow-ups where it isn't clear who owes whom:\n- Sarah Chen: send the metrics deck" in page
    assert page.index("hallway hello") < page.index("coffee about pricing")
    assert "Last conversation, as heard: We should talk about embedded payments." in page
    assert agent.person(net, "Quinn") == "Nobody called “Quinn” is on record."


def test_connections_names_what_links_two_people(net):
    sarah = agent.connections(net, "Sarah Chen")
    assert "- Dana Okafor (Design, Lumen): payments" in sarah
    assert "- Omar Haddad (Engineer, Acme): both at Acme" in sarah
    assert "- Sarah Chen (VP Product, Acme): both at Acme" in agent.connections(net, "Omar Haddad")
    assert agent.connections(net, "Quinn") == "Nobody called “Quinn” is on record."


def test_topic_finds_who_talked_about_it(net):
    got = agent.topic(net, "Payments")
    assert "Sarah Chen" in got and "Dana Okafor" in got and "Omar" not in got
    assert agent.topic(net, "knitting") == "Nobody talked about “knitting”."


def test_recent_meetings_are_newest_first_and_the_limit_is_kept_in_range(net):
    lines = agent.recent_meetings(net, 2).splitlines()
    assert lines == [
        "- 2026-11-21 11:12, Dana Okafor, sighting: recognised in frame",
        "- 2026-11-21 08:30, Sarah Chen, sighting: hallway hello",
    ]
    assert len(agent.recent_meetings(net, 500).splitlines()) == 3
    assert len(agent.recent_meetings(net, "lots").splitlines()) == 3


def test_follow_ups_are_listed_by_person_without_saying_who_owes_them(net):
    assert agent.promises(net) == (
        "Follow-ups where it isn't clear who owes whom:\n- Sarah Chen: send the metrics deck"
    )


def test_follow_ups_are_grouped_by_who_owes_them(net):
    with session() as db:
        omar, lena = db.add_person(Person(name="Omar")), db.add_person(Person(name="Lena"))
        omar.followups, lena.followups = ["send you our demo video"], ["send them the repo link"]
        db.save_person(omar)
        db.save_person(lena)
        bigger = agent.Network.load(db)
    got = agent.promises(bigger)
    assert "You owe these people (you said you'd do it):\n- Lena: send them the repo link" in got
    assert "These people owe you (they said they'd do it for you):\n- Omar: send you our demo video" in got


def test_the_outline_carries_follow_ups_so_they_are_never_guessed(net):
    assert agent.outline(net).endswith("- Sarah Chen: send the metrics deck")


# --------------------------------------------------------------------- loop


def test_the_model_looks_someone_up_then_answers(net, fake):
    fake.turns = [
        llm.Turn(calls=[call("person", name="Sarah")]),
        answer("Sarah Chen owes nothing; you owe her the metrics deck.", ["Sarah Chen"]),
    ]
    got = agent.ask(net, "What do I owe Sarah?")

    assert [p.name for p in got.people] == ["Sarah Chen"]
    assert got.steps == ["Read about Sarah Chen"]
    # the second step saw the tool call and its result
    messages = fake.agent_steps[1][0]
    assert messages[-2]["tool_calls"][0]["function"]["name"] == "person"
    assert messages[-1]["role"] == "tool" and messages[-1]["tool_call_id"] == "call-person-0"
    assert "send the metrics deck" in messages[-1]["content"]


def test_the_question_goes_with_the_outline_and_the_wearer_is_named(net, fake):
    fake.turns = [answer("Nobody.", [])]
    agent.ask(net, "Who works in robotics?", wearer="Alex")
    messages, tools, finish_with = fake.agent_steps[0]
    assert "The wearer's own name is Alex" in messages[0]["content"]
    assert messages[1]["content"].endswith("Question: Who works in robotics?")
    assert "Omar Haddad" in messages[1]["content"]
    assert tools == ["find_people", "person", "connections", "topic",
                     "recent_meetings", "promises", "answer"]  # fmt: skip
    assert finish_with == ""


def test_after_a_few_rounds_of_looking_the_model_must_answer(net, fake):
    fake.turns = [llm.Turn(calls=[call("promises", n)]) for n in range(agent.MAX_ROUNDS)]
    fake.turns.append(answer("You owe Sarah the deck.", ["Sarah Chen"]))
    agent.ask(net, "What do I owe?")
    finishes = [finish for _, _, finish in fake.agent_steps]
    assert finishes == [""] * agent.MAX_ROUNDS + ["answer"]


def test_an_answer_in_words_is_asked_for_again_through_the_answer_tool(net, fake):
    fake.turns = [
        llm.Turn(content="Introduce Sarah Chen to Dana Okafor: both talk payments."),
        answer("Introduce Sarah Chen to Dana Okafor: both talk payments.", ["Sarah Chen"],
               [{"from": "Sarah Chen", "to": "Dana Okafor"}]),
    ]  # fmt: skip
    got = agent.ask(net, "Who should meet?")
    assert fake.agent_steps[1][2] == "answer"
    assert fake.agent_steps[1][0][-2] == {
        "role": "assistant", "content": "Introduce Sarah Chen to Dana Okafor: both talk payments."
    }
    assert got.links == [{"from": "Sarah Chen", "to": "Dana Okafor", "kind": "person", "via": "payments"}]


def test_an_answer_in_words_is_used_as_it_is_when_asking_again_fails(net, fake):
    fake.turns = [llm.Turn(content="**Dana Okafor** is your payments person, not Dana.")]
    got = agent.ask(net, "Who knows payments?")
    assert got.text == "Dana Okafor is your payments person, not Dana."
    # whoever it names in full is who the answer is about
    assert [p.name for p in got.people] == ["Dana Okafor"]


def test_a_reply_with_neither_a_tool_call_nor_words_is_an_error(net, fake):
    fake.turns = [llm.Turn()]
    with pytest.raises(llm.LLMError):
        agent.ask(net, "Who?")


def test_an_unknown_tool_is_told_which_ones_exist(net, fake):
    fake.turns = [llm.Turn(calls=[call("search_web", q="x")]), answer("Nobody.", [])]
    agent.ask(net, "Who?")
    told = fake.agent_steps[1][0][-1]["content"]
    assert told.startswith("There is no tool called search_web. Use one of: find_people")


# ------------------------------------------------------------ the checking


def test_people_who_are_not_on_record_are_left_out(net, fake):
    fake.turns = [answer("Quinn and Sarah.", ["Quinn Halloway", "Sarah Chen", "Sarah"])]
    got = agent.ask(net, "Who?")
    assert [p.name for p in got.people] == ["Sarah Chen"]


def test_links_must_join_people_or_a_topic_on_record(net, fake):
    fake.turns = [
        answer(
            "Introduce Sarah to Dana: both talk payments.",
            ["Sarah Chen"],
            [
                {"from": "Sarah Chen", "to": "Dana Okafor", "via": "payments"},
                {"from": "Dana Okafor", "to": "Sarah Chen", "via": "the same link again"},
                {"from": "Sarah Chen", "to": "payments"},
                {"from": "Sarah Chen", "to": "Sarah Chen"},
                {"from": "Quinn Halloway", "to": "Dana Okafor"},
                {"from": "Omar Haddad", "to": "underwater basket weaving"},
                "not a link",
            ],
        )
    ]
    got = agent.ask(net, "Who should Sarah meet?")
    assert got.links == [
        {"from": "Sarah Chen", "to": "Dana Okafor", "kind": "person", "via": "payments"},
        {"from": "Sarah Chen", "to": "payments", "kind": "topic", "via": ""},
    ]
    # whoever a link joins is part of the answer
    assert [p.name for p in got.people] == ["Sarah Chen", "Dana Okafor"]


def test_an_empty_answer_still_says_something(net, fake):
    fake.turns = [answer("", [])]
    assert agent.ask(net, "Who?").text == "No one fits that yet."


def test_arguments_of_the_wrong_type_are_read_as_text(net, fake):
    fake.turns = [
        llm.Turn(calls=[call("person", 0, name=["Sarah"]), call("topic", 1, label=7)]),
        answer("Nobody.", []),
    ]
    agent.ask(net, "Who?")
    results = [m["content"] for m in fake.agent_steps[1][0] if m["role"] == "tool"]
    assert results == ["Nobody called “['Sarah']” is on record.", "Nobody talked about “7”."]


def test_only_a_few_tools_run_per_round_and_the_rest_are_told_so(net, fake):
    many = [call("topic", n, label=f"t{n}") for n in range(agent.MAX_CALLS + 3)]
    fake.turns = [llm.Turn(calls=many), answer("Nobody.", [])]
    got = agent.ask(net, "Who?")
    results = [m["content"] for m in fake.agent_steps[1][0] if m["role"] == "tool"]
    assert len(results) == agent.MAX_CALLS + 3          # every call gets a reply
    assert results[agent.MAX_CALLS:] == [f"Not run: use at most {agent.MAX_CALLS} tools at a time."] * 3
    assert len(got.steps) == agent.MAX_CALLS


def test_a_long_list_of_steps_is_shortened(net, fake):
    rounds = [[call("topic", r * 10 + n, label=f"t{r}{n}") for n in range(agent.MAX_CALLS)]
              for r in range(2)]  # fmt: skip
    fake.turns = [llm.Turn(calls=c) for c in rounds] + [answer("Nobody.", [])]
    steps = agent.ask(net, "Who?").steps
    hidden = 2 * agent.MAX_CALLS - agent.MAX_STEPS + 1
    assert len(steps) == agent.MAX_STEPS and steps[-1] == f"and {hidden} more lookups"


def test_an_empty_search_is_not_reported_as_a_step(net, fake):
    fake.turns = [llm.Turn(calls=[call("find_people", text=""), call("topic", 1, label=" ")]),
                  answer("Nobody.", [])]  # fmt: skip
    assert agent.ask(net, "Who?").steps == []


def test_a_link_between_two_people_says_what_the_record_shows_not_what_the_model_said(net, fake):
    fake.turns = [
        answer("Sarah and Omar; Dana and Omar.", [], [
            {"from": "Sarah Chen", "to": "Omar Haddad", "via": "old friends"},
            {"from": "Dana Okafor", "to": "Omar Haddad", "via": "design could help robotics"},
            {"from": "Omar Haddad", "to": "payments"},
        ])
    ]  # fmt: skip
    got = agent.ask(net, "Who should meet?")
    # Sarah and Omar are both at Acme; Dana and Omar share nothing on record,
    # and Omar never talked about payments
    assert got.links == [
        {"from": "Sarah Chen", "to": "Omar Haddad", "kind": "person", "via": "both at Acme"}
    ]


def test_being_introduced_by_someone_links_two_people(net, fake):
    with session() as db:
        db.add_person(Person(name="Priya Raman", relationship="introduced by Dana"))
        bigger = agent.Network.load(db)
    fake.turns = [answer("Dana introduced Priya.", [], [{"from": "Priya Raman", "to": "Dana Okafor"}])]
    [link] = agent.ask(bigger, "Who knows Dana?").links
    assert link["via"] == "introduced by Dana"


def test_a_long_answer_is_cut_at_a_sentence(net, fake):
    sentence = "Sarah Chen is the person to ask about payments at Acme these days. "
    fake.turns = [answer(sentence * 10, ["Sarah Chen"])]
    text = agent.ask(net, "Who?").text
    assert len(text) <= 360 and text.endswith("days.") and "…" not in text


def test_a_numbered_list_is_not_cut_after_its_number(net, fake):
    fake.turns = [answer("Two pairs. 1. Sarah and Dana. 2. Omar and Sarah.", [])]
    assert agent.ask(net, "Who?").text == "Two pairs. 1. Sarah and Dana. 2. Omar and Sarah."


def test_generic_words_are_not_common_ground():
    a = agent.Known(Person(name="Jonah", id=1), ["embedded systems", "hiring ml interns"], [])
    b = agent.Known(Person(name="Priscilla", id=2), ["distributed systems", "hiring backend interns"], [])
    assert agent.common(a, b) == []
