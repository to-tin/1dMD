import json

import anthropic
from anthropic import DefaultHttpxClient
import httpx2
import pytest

from app import processing
from app.models import TranscriptRequest
from app.topic_map import (
    MODEL, SYSTEM_PROMPT, Outline, TopicMapError, layout, map_transcript, outline_transcript,
)


def node(id, title, parent="", continues="", description="", bullets=()):
    return {
        "id": id, "title": title, "parent": parent, "continues": continues,
        "description": description,
        "bullets": [{"text": text, "talked_about": talked} for text, talked in bullets],
    }


def outline(*nodes, current):
    return Outline.model_validate({"nodes": list(nodes), "current": current})


# Same conversation as the app's sample map: Dune, deeper into Worms, drift to New York.
DUNE = outline(
    node("dune", "Dune", description="They talked about the film.",
         bullets=[("Worms", True), ("Politics", False)]),
    node("worms", "Worms", parent="dune", description="The worm scenes stood out.",
         bullets=[("Sound design", False)]),
    node("nyc", "New York", bullets=[("Columbia", True), ("Pizza", True)]),
    node("columbia", "Columbia", parent="nyc"),
    node("pizza", "Pizza", parent="nyc"),
    current="pizza",
)


def claude_reply(text, stop_reason="end_turn", stop_details=None):
    return {
        "id": "msg_test", "type": "message", "role": "assistant", "model": MODEL,
        "content": [{"type": "text", "text": text}],
        "stop_reason": stop_reason, "stop_sequence": None, "stop_details": stop_details,
        "usage": {"input_tokens": 900, "output_tokens": 200,
                  "cache_read_input_tokens": 800, "cache_creation_input_tokens": 0},
    }


def fake_client(reply, requests=None):
    """A real SDK client whose HTTP calls are answered locally, never sent."""
    def handler(request):
        if requests is not None:
            requests.append(json.loads(request.content))
        return httpx2.Response(200, json=reply)
    return anthropic.Anthropic(
        api_key="test-key", http_client=DefaultHttpxClient(transport=httpx2.MockTransport(handler)),
    )


# Layout

def test_layout_places_topics_and_subtopics():
    result = layout(DUNE)
    nodes = {n["id"]: n for n in result["nodes"]}

    assert (nodes["dune"]["line"], nodes["dune"]["column"], nodes["dune"]["isTopic"]) == (0, 0, True)
    assert (nodes["worms"]["line"], nodes["worms"]["column"], nodes["worms"]["isTopic"]) == (0, 1, False)
    assert (nodes["nyc"]["line"], nodes["nyc"]["column"]) == (1, 0)
    # First sub-topic stays on its parent's line; the second starts a new one.
    assert (nodes["columbia"]["line"], nodes["columbia"]["column"]) == (1, 1)
    assert (nodes["pizza"]["line"], nodes["pizza"]["column"]) == (2, 1)
    assert result["currentID"] == "pizza"


def test_layout_colours_the_bullet_that_led_deeper():
    nodes = {n["id"]: n for n in layout(DUNE)["nodes"]}
    worms_bullet = next(b for b in nodes["dune"]["bullets"] if b["text"] == "Worms")
    assert worms_bullet["branch"] == nodes["worms"]["branch"]
    assert "branch" not in next(b for b in nodes["dune"]["bullets"] if b["text"] == "Politics")
    branches = [n["branch"] for n in nodes.values() if not n["isTopic"]]
    assert len(set(branches)) == len(branches)


def test_layout_keeps_descriptions_and_talked_about():
    nodes = {n["id"]: n for n in layout(DUNE)["nodes"]}
    assert nodes["dune"]["description"] == "They talked about the film."
    assert nodes["columbia"]["description"] == ""
    assert nodes["dune"]["bullets"][1] == {"text": "Politics", "talkedAbout": False}


def test_layout_edges():
    assert layout(DUNE)["edges"] == [
        {"from": "dune", "to": "worms", "kind": "deeper"},
        {"from": "worms", "to": "nyc", "kind": "newTopic"},
        {"from": "nyc", "to": "columbia", "kind": "deeper"},
        {"from": "nyc", "to": "pizza", "kind": "deeper"},
    ]


def test_layout_return_to_earlier_topic():
    result = layout(outline(
        node("dune", "Dune"), node("nyc", "New York"),
        node("dune-2", "Dune", continues="dune"),
        current="dune-2",
    ))
    assert {"from": "dune", "to": "dune-2", "kind": "continued"} in result["edges"]
    assert {"from": "nyc", "to": "dune-2", "kind": "newTopic"} in result["edges"]


def test_layout_return_right_after_the_original_has_no_duplicate_edge():
    result = layout(outline(node("dune", "Dune"), node("dune-2", "Dune", continues="dune"), current="dune-2"))
    assert result["edges"] == [{"from": "dune", "to": "dune-2", "kind": "continued"}]


def test_layout_skips_nodes_that_would_break_the_map():
    result = layout(outline(
        node("a", "Alpha", bullets=[("x", True), ("X", True), ("  ", False)]),
        node("a", "Duplicate id"),
        node("blank", "   "),
        node("orphan", "Orphan", parent="missing"),
        node("self", "Self", parent="self"),
        current="nope",
    ))
    nodes = {n["id"]: n for n in result["nodes"]}
    assert list(nodes) == ["a", "orphan", "self"]
    assert nodes["a"]["title"] == "Alpha"
    assert nodes["a"]["bullets"] == [{"text": "x", "talkedAbout": True}]
    # A node whose parent is unknown (or itself) becomes a topic instead of vanishing.
    assert nodes["orphan"]["isTopic"] and nodes["self"]["isTopic"]
    # An unknown current falls back to the last node.
    assert result["currentID"] == "self"


def test_layout_adds_a_bullet_for_an_unlisted_subtopic():
    result = layout(outline(node("a", "Alpha"), node("b", "Beta", parent="a"), current="b"))
    parent = result["nodes"][0]
    assert parent["bullets"] == [{"text": "Beta", "talkedAbout": True, "branch": result["nodes"][1]["branch"]}]


def test_layout_with_no_usable_nodes_fails():
    with pytest.raises(TopicMapError):
        layout(outline(node("", "Untitled"), node("x", ""), current=""))


# Calling Claude

def test_request_uses_haiku_cached_prompt_and_schema():
    requests = []
    client = fake_client(claude_reply(DUNE.model_dump_json()), requests)

    result = map_transcript("We talked about Dune and then New York.", client)

    body = requests[0]
    assert body["model"] == "claude-haiku-5-5"
    assert body["system"] == [{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}]
    assert body["messages"] == [{"role": "user", "content":
                                 "<transcript>\nWe talked about Dune and then New York.\n</transcript>"}]
    assert body["output_config"]["format"]["type"] == "json_schema"
    assert result == {**layout(DUNE), "outline": DUNE.model_dump()}


def test_empty_transcript_fails_without_calling_claude():
    requests = []
    with pytest.raises(TopicMapError, match="empty"):
        outline_transcript("  \n ", fake_client(claude_reply("{}"), requests))
    assert requests == []


def test_refusal_fails_the_job():
    reply = claude_reply("", stop_reason="refusal",
                         stop_details={"type": "refusal", "category": "cyber", "explanation": None})
    with pytest.raises(TopicMapError, match="declined"):
        outline_transcript("Some transcript.", fake_client(reply))


def test_cut_off_outline_fails_the_job():
    with pytest.raises(TopicMapError, match="cut off"):
        outline_transcript("Some transcript.", fake_client(claude_reply('{"nodes": [', stop_reason="max_tokens")))


def test_invalid_outline_fails_the_job():
    with pytest.raises(TopicMapError, match="not a valid Outline"):
        outline_transcript("Some transcript.", fake_client(claude_reply('{"nodes": "nope"}')))


def test_api_errors_reach_the_job_runner():
    def handler(request):
        return httpx2.Response(401, json={"type": "error", "error": {"type": "authentication_error",
                                                                      "message": "invalid x-api-key"}})
    client = anthropic.Anthropic(api_key="bad", max_retries=0,
                                 http_client=DefaultHttpxClient(transport=httpx2.MockTransport(handler)))
    with pytest.raises(anthropic.AuthenticationError):
        outline_transcript("Some transcript.", client)


# Choosing Claude or the mock

def test_no_api_key_returns_the_mock_map():
    assert processing.process_transcript(TranscriptRequest(transcript="Hi")) == processing.mock_response()


def test_api_key_uses_claude(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    calls = []
    monkeypatch.setattr(processing, "_client", lambda: "client")
    monkeypatch.setattr(processing, "map_transcript", lambda text, client: calls.append((text, client)) or {"ok": True})
    assert processing.process_transcript(TranscriptRequest(transcript="Hi")) == {"ok": True}
    assert calls == [("Hi", "client")]
