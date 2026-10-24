import json

import anthropic
from anthropic import DefaultHttpxClient
from fastapi.testclient import TestClient
import httpx2
import pytest

from app import processing
from app.live import LIVE_PROMPT, LiveMove, apply_move, live_update, next_move, summarize
from app.main import create_app
from app.models import LiveReply, LiveRequest
from app.topic_map import MODEL, Outline, TopicMapError, layout


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


@pytest.mark.parametrize("target", ["dune", "worms"])
def test_back_to_the_topic_already_continued_adds_no_node(target):
    start = outline(node("dune", "Dune"), node("worms", "Worms", parent="dune"), node("nyc", "New York"),
                    node("dune-2", "Dune", continues="dune"), node("spice", "Spice", parent="dune-2"),
                    current="spice")
    result, applied = apply_move(start, move("back", back_to=target))
    assert applied == "back"
    assert len(result.nodes) == 5
    assert result.current == "dune-2"


def test_back_inside_the_current_tree_moves_to_the_target():
    start = outline(node("dune", "Dune"), node("nyc", "New York"),
                    node("dune-2", "Dune", continues="dune"), node("spice", "Spice", parent="dune-2"),
                    current="spice")
    result, _ = apply_move(start, move("back", back_to="dune-2"))
    assert len(result.nodes) == 4 and result.current == "dune-2"


def test_new_with_an_existing_top_level_title_is_a_back():
    result, applied = apply_move(DUNE, move("new", label="dune"))
    assert applied == "back"
    cont = result.nodes[-1]
    assert (cont.title, cont.continues) == ("Dune", "dune")
    assert result.current == cont.id
    assert len(result.nodes) == 4


def test_new_with_the_current_top_level_title_is_a_stay():
    start = outline(node("dune", "Dune"), current="dune")
    result, applied = apply_move(start, move("new", label="DUNE"))
    assert applied == "stay" and len(result.nodes) == 1


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


def claude_reply(text, stop_reason="end_turn", stop_details=None):
    return {"id": "msg_live", "type": "message", "role": "assistant", "model": MODEL,
            "content": [{"type": "text", "text": text}], "stop_reason": stop_reason,
            "stop_sequence": None, "stop_details": stop_details,
            "usage": {"input_tokens": 300, "output_tokens": 60,
                      "cache_read_input_tokens": 250, "cache_creation_input_tokens": 0}}


def fake_client(reply, requests=None):
    def handler(request):
        if requests is not None:
            requests.append(json.loads(request.content))
        return httpx2.Response(200, json=reply)
    return anthropic.Anthropic(api_key="test-key",
                               http_client=DefaultHttpxClient(transport=httpx2.MockTransport(handler)))


def test_summary_of_an_empty_map():
    assert "start of the conversation" in summarize(None)


def test_summary_lists_ids_titles_now_and_open_threads():
    text = summarize(DUNE)
    assert "[dune] Dune" in text
    assert "[worms]" not in text             # a sub-topic of another topic is left out
    assert "[nyc] New York  <- NOW" in text
    assert '"Politics" (dune)' in text       # an open thread
    assert '"Worms"' not in text.split("Open threads")[1]  # talked about, so not open


def test_summary_lists_the_sub_topics_of_the_now_tree():
    text = summarize(DUNE.model_copy(update={"current": "worms"}))
    assert "[dune] Dune" in text and "  - [worms] Worms  <- NOW" in text
    assert "[nyc] New York" in text


def big_outline(now="t0s3", extra=()):
    """40 nodes: 8 topics, each with 4 sub-topics; every node has an open thread."""
    nodes = []
    for i in range(8):
        nodes.append(node(f"t{i}", f"Topic number {i}", description="x" * 150,
                          bullets=[(f"open thread about topic {i}", False)]))
        for j in range(4):
            nodes.append(node(f"t{i}s{j}", f"Sub-topic {j} of {i}", parent=f"t{i}",
                              bullets=[(f"open thread {i}.{j}", False)]))
    return outline(*nodes, *extra, current=now)


SUMMARY_BUDGET = 2000   # chars (~500 tokens); this map is ~670, the old format gave ~2260 and grew with every node


def test_summary_of_a_40_node_map_stays_under_budget():
    text = summarize(big_outline())
    assert len(text) < SUMMARY_BUDGET
    for i in range(8):
        assert f"[t{i}] Topic number {i}" in text            # every topic is listed
    for j in range(4):
        assert f"[t0s{j}]" in text                           # the NOW tree's sub-topics
        assert f'"open thread 0.{j}" (t0s{j})' in text       # and its open threads
    assert '"open thread about topic 0" (t0)' in text
    assert "[t1s0]" not in text and "[t7s3]" not in text     # other topics' sub-topics
    assert "(+" in text and "more elsewhere)" in text
    threads = text.split("Open threads: ")[1]
    assert '"open thread 7.3" (t7s3)' in threads             # most recent elsewhere is kept
    assert threads.index("(t7s3)") < threads.index("(t7s2)") # most recent first
    assert '"open thread 1.0"' not in threads                # an old one is dropped


def test_summary_counts_the_other_threads_left_out():
    text = summarize(big_outline())
    # 40 threads: 5 in the NOW tree, 35 elsewhere, 5 shown
    assert "(+30 more elsewhere)" in text


def test_summary_without_other_threads_has_no_more_note():
    assert "more elsewhere" not in summarize(DUNE)


def test_summary_includes_the_original_tree_when_now_is_in_a_cont_topic():
    base = big_outline(now="t5")
    cont = node("c1", "Topic number 0", continues="t0")
    cont_child = node("c1a", "Fresh angle", parent="c1")
    text = summarize(outline(*base.nodes, cont, cont_child, current="c1a"))
    assert "(returns to t0)" in text and "[c1a] Fresh angle  <- NOW" in text
    for j in range(4):
        assert f"[t0s{j}]" in text                           # the original's tree is "this topic"
    assert "[t1s0]" not in text


def test_next_move_sends_cached_prompt_summary_and_words():
    requests = []
    reply = claude_reply(move("deeper", label="Columbia").model_dump_json())
    result = next_move(DUNE, "we went to New York", "my friend went to Columbia", fake_client(reply, requests))
    body = requests[0]
    assert result.move == "deeper" and result.label == "Columbia"
    assert body["model"] == "claude-haiku-5-5"
    assert body["system"] == [{"type": "text", "text": LIVE_PROMPT, "cache_control": {"type": "ephemeral"}}]
    content = body["messages"][0]["content"]
    assert "<map>" in content and "[nyc] New York  <- NOW" in content
    assert "<previous_words>\nwe went to New York\n</previous_words>" in content
    assert "<new_words>\nmy friend went to Columbia\n</new_words>" in content
    assert body["output_config"]["format"]["type"] == "json_schema"
    assert body["output_config"]["effort"] == "low"


def test_next_move_refusal_fails():
    reply = claude_reply("", stop_reason="refusal",
                         stop_details={"type": "refusal", "category": "cyber", "explanation": None})
    with pytest.raises(TopicMapError, match="declined"):
        next_move(DUNE, "", "words", fake_client(reply))


def test_next_move_invalid_reply_fails():
    with pytest.raises(TopicMapError, match="not a valid"):
        next_move(DUNE, "", "words", fake_client(claude_reply('{"move": "sideways"}')))


def test_live_update_applies_the_move_and_lays_out():
    reply = claude_reply(move("deeper", label="Columbia").model_dump_json())
    result = live_update(LiveRequest(outline=DUNE, words="my friend went to Columbia"), fake_client(reply))
    assert result.move == "deeper"
    assert result.outline.current == "columbia"
    assert result.map == layout(result.outline)


def test_blank_words_change_nothing_and_skip_claude():
    requests = []
    result = live_update(LiveRequest(outline=DUNE, words="   "), fake_client(claude_reply("{}"), requests))
    assert requests == [] and result.move == "none" and result.outline == DUNE


def test_no_api_key_returns_the_outline_unchanged():
    result = processing.process_live(LiveRequest(outline=DUNE, words="hello"))
    assert result.move == "none" and result.outline == DUNE and result.map == layout(DUNE)
    first = processing.process_live(LiveRequest(words="hello"))
    assert first.outline is None and first.map is None


def test_live_route_round_trip():
    seen = []
    def fake_live(request):
        seen.append(request)
        return LiveReply(outline=DUNE, map=layout(DUNE), move="stay")
    with TestClient(create_app(live=fake_live)) as client:
        response = client.post("/live", json={"outline": DUNE.model_dump(), "previous_words": "a", "words": "b"})
    assert response.status_code == 200
    body = response.json()
    assert body["move"] == "stay" and body["map"]["currentID"] == "nyc"
    assert seen[0].outline == DUNE and seen[0].words == "b"


def test_live_route_first_call_without_outline():
    with TestClient(create_app(live=lambda r: LiveReply(outline=None, map=None, move="none"))) as client:
        response = client.post("/live", json={"words": "hello"})
    assert response.status_code == 200 and response.json()["outline"] is None


@pytest.mark.parametrize("body", [{}, {"words": 3}, {"outline": {"nodes": "x"}, "words": "a"}])
def test_live_route_rejects_bad_bodies(body):
    with TestClient(create_app()) as client:
        assert client.post("/live", json=body).status_code == 422


def test_live_route_failure_is_502_and_logged(caplog):
    def broken(request):
        raise TopicMapError("Claude declined (category: cyber).")
    with TestClient(create_app(live=broken)) as client:
        response = client.post("/live", json={"words": "hello"})
    assert response.status_code == 502
    assert response.json() == {"detail": "Live update failed."}
    assert "declined" in caplog.text
