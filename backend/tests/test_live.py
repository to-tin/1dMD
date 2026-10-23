import pytest

from app.live import LiveMove, apply_move
from app.topic_map import Outline


def node(id, title, parent="", continues="", description="", bullets=()):
    return {"id": id, "title": title, "parent": parent, "continues": continues,
            "description": description,
            "bullets": [{"text": t, "talked_about": a} for t, a in bullets]}


def outline(*nodes, current):
    return Outline.model_validate({"nodes": list(nodes), "current": current})


def move(kind="stay", label="", back_to="", add=(), talked=(), description=""):
    return LiveMove.model_validate({
        "move": kind, "label": label, "back_to": back_to,
        "add_bullets": [{"text": t, "talked_about": a} for t, a in add],
        "talked_about": list(talked), "description": description,
    })


DUNE = outline(
    node("dune", "Dune", bullets=[("Worms", True), ("Politics", False)]),
    node("worms", "Worms", parent="dune"),
    node("nyc", "New York"),
    current="nyc",
)


def test_first_call_starts_a_topic():
    result, applied = apply_move(None, move("new", label="Dune", add=[("Worms", True)], description="About Dune."))
    assert applied == "new"
    assert result.current == "dune"
    assert [(n.id, n.title, n.parent) for n in result.nodes] == [("dune", "Dune", "")]
    assert result.nodes[0].description == "About Dune."
    assert [b.text for b in result.nodes[0].bullets] == ["Worms"]


def test_first_call_with_stay_still_starts_a_topic():
    result, applied = apply_move(None, move("stay", add=[("Hello", True)]))
    assert applied == "new"
    assert result.nodes[0].title == "Conversation"


def test_stay_adds_bullets_marks_talked_about_and_updates_description():
    start = outline(node("dune", "Dune", bullets=[("Politics", False)]), current="dune")
    result, applied = apply_move(start, move(add=[("Spice", True), ("politics", True)],
                                             talked=["Politics"], description="Now spice."))
    assert applied == "stay"
    bullets = [(b.text, b.talked_about) for b in result.nodes[0].bullets]
    assert bullets == [("Politics", True), ("Spice", True)]  # duplicate "politics" not added
    assert result.nodes[0].description == "Now spice."


def test_stay_keeps_description_when_blank():
    start = outline(node("dune", "Dune", description="Old."), current="dune")
    result, _ = apply_move(start, move(description="  "))
    assert result.nodes[0].description == "Old."


def test_deeper_adds_a_child_of_the_current_node():
    result, applied = apply_move(DUNE, move("deeper", label="Columbia"))
    assert applied == "deeper"
    child = result.nodes[-1]
    assert (child.id, child.title, child.parent) == ("columbia", "Columbia", "nyc")
    assert result.current == "columbia"


def test_new_adds_a_top_level_topic():
    result, applied = apply_move(DUNE, move("new", label="Taxes"))
    assert applied == "new"
    assert (result.nodes[-1].parent, result.current) == ("", "taxes")


def test_new_ids_stay_unique():
    result, _ = apply_move(DUNE, move("new", label="Dune"))
    assert result.current == "dune-2"


def test_back_within_the_same_topic_only_moves_now():
    start = outline(node("dune", "Dune"), node("worms", "Worms", parent="dune"), current="worms")
    result, applied = apply_move(start, move("back", back_to="dune"))
    assert applied == "back"
    assert len(result.nodes) == 2 and result.current == "dune"


def test_back_to_an_earlier_topic_adds_a_continued_node():
    result, applied = apply_move(DUNE, move("back", back_to="worms", description="Back to worms."))
    assert applied == "back"
    cont = result.nodes[-1]
    assert (cont.title, cont.parent, cont.continues) == ("Dune", "", "dune")
    assert result.current == cont.id
    assert cont.description == "Back to worms."


def test_back_to_a_continued_topic_links_the_original():
    start = outline(node("dune", "Dune"), node("nyc", "New York"),
                    node("dune-2", "Dune", continues="dune"), node("tax", "Taxes"), current="tax")
    result, _ = apply_move(start, move("back", back_to="dune-2"))
    assert result.nodes[-1].continues == "dune"


@pytest.mark.parametrize("bad", [
    move("back", back_to="missing"),
    move("back", back_to="nyc"),       # already current
    move("deeper", label="   "),
    move("new", label=""),
])
def test_invalid_moves_become_stay(bad):
    result, applied = apply_move(DUNE, bad)
    assert applied == "stay"
    assert [n.id for n in result.nodes] == ["dune", "worms", "nyc"]
    assert result.current == "nyc"


def test_unknown_current_is_treated_as_first_call():
    broken = outline(node("dune", "Dune"), current="gone")
    result, applied = apply_move(broken, move("stay"))
    assert applied == "new"
    assert result.current == result.nodes[-1].id


def test_input_outline_is_not_mutated():
    before = DUNE.model_dump()
    apply_move(DUNE, move("deeper", label="Columbia", add=[("x", True)]))
    assert DUNE.model_dump() == before
