import io
import json

import anthropic
from anthropic import DefaultHttpxClient
import httpx2

from app.topic_map import MODEL
from scripts import replay_live
from test_live import claude_reply, move

TEXT = " ".join(f"w{i}" for i in range(1, 46))  # 45 words -> batches of 20, 20, 5


def scripted_client(moves, requests):
    """A real Anthropic client whose replies are the given moves, in order."""
    replies = iter(moves)

    def handler(request):
        requests.append(json.loads(request.content))
        return httpx2.Response(200, json=claude_reply(next(replies).model_dump_json()))
    return anthropic.Anthropic(api_key="test-key",
                               http_client=DefaultHttpxClient(transport=httpx2.MockTransport(handler)))


MOVES = [move("new", label="Trip", add=[("Route", True)], description="Planning a trip."),
         move("deeper", label="Campsite"),
         move("back", back_to="trip")]


def replay(**kwargs):
    requests, out = [], io.StringIO()
    result = replay_live.run(TEXT, scripted_client(MOVES, requests), out=out, **kwargs)
    return result, requests, out.getvalue()


def test_splits_words_into_batches():
    assert [len(b.split()) for b in replay_live.batches_of(TEXT, 20)] == [20, 20, 5]


def test_carries_previous_words_and_outline_forward():
    _, requests, _ = replay()
    contents = [r["messages"][0]["content"] for r in requests]
    assert "start of the conversation" in contents[0]
    assert "<previous_words>\n\n</previous_words>" in contents[0]
    assert "<new_words>\nw1 w2" in contents[0] and "w20\n</new_words>" in contents[0]
    assert "<previous_words>\nw1 w2" in contents[1] and "w20\n</previous_words>" in contents[1]
    assert "<new_words>\nw21" in contents[1]
    assert "[trip] Trip  <- NOW" in contents[1]            # outline from batch 1
    assert "[campsite] Campsite  <- NOW" in contents[2]    # and from batch 2
    assert "<new_words>\nw41 w42 w43 w44 w45\n</new_words>" in contents[2]


def test_prints_a_line_per_batch_tree_and_totals():
    result, _, text = replay()
    lines = text.splitlines()
    assert lines[0].startswith("batch   1  new") and "NOW: Trip" in lines[0] and "1 nodes" in lines[0]
    assert "batch   2  deeper" in lines[1] and "NOW: Campsite" in lines[1] and "2 nodes" in lines[1]
    assert "batch   3  back" in lines[2]
    assert "- Trip  <- NOW" in text            # back to the same topic reuses the node
    assert "    Planning a trip." in text
    assert "  - Campsite" in text              # nested under Trip
    assert "x Route" in text
    assert "Moves: new 1, deeper 1, back 1" in text
    assert "Topics created: 2" in text
    assert "Tokens: 900 in / 180 out" in text
    assert result["totals"]["topics_created"] == 2


def test_model_and_effort_overrides_reach_the_request():
    _, requests, _ = replay(effort="medium", model="claude-test-model")
    assert {r["model"] for r in requests} == {"claude-test-model"}
    assert {r["output_config"]["effort"] for r in requests} == {"medium"}


def test_defaults_match_the_server():
    _, requests, _ = replay()
    assert requests[0]["model"] == MODEL and requests[0]["output_config"]["effort"] == "low"


def test_json_output_shape(tmp_path):
    path = tmp_path / "out.json"
    replay(json_path=str(path))
    data = json.loads(path.read_text())
    assert [s["batch"] for s in data["steps"]] == [1, 2, 3]
    step = data["steps"][1]
    assert set(step) == {"batch", "words", "move", "seconds", "outline"}
    assert step["move"] == "deeper" and step["words"].startswith("w21 ")
    assert step["outline"]["current"] == "campsite"
    totals = data["totals"]
    assert totals["moves"] == {"new": 1, "deeper": 1, "back": 1}
    assert totals["topics_created"] == 2 and totals["batches"] == 3
    assert totals["input_tokens"] == 900 and totals["output_tokens"] == 180
    assert "seconds" in totals


def test_refuses_without_an_api_key(tmp_path, capsys):
    transcript = tmp_path / "t.txt"
    transcript.write_text("hello there")
    assert replay_live.main([str(transcript)]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.count("\n") == 1 and "ANTHROPIC_API_KEY" in captured.err


def test_main_runs_with_an_injected_client(tmp_path, capsys):
    transcript = tmp_path / "t.txt"
    transcript.write_text(TEXT)
    code = replay_live.main([str(transcript), "--words", "30"], client=scripted_client(MOVES, []))
    assert code == 0
    assert capsys.readouterr().out.count("batch ") == 2


def test_sample_transcripts_are_a_sensible_length():
    from pathlib import Path
    files = sorted((Path(replay_live.__file__).parent / "sample_transcripts").glob("*.txt"))
    assert len(files) == 2
    assert all(150 <= len(f.read_text().split()) <= 300 for f in files)


class FailingClient:
    """Delegates to a scripted client but raises on the 2nd call."""

    def __init__(self, error):
        self.messages = self
        self._inner, self._calls, self._error = scripted_client(MOVES, []), 0, error

    def create(self, *args, **kwargs):
        self._calls += 1
        if self._calls == 2:
            raise self._error
        return self._inner.messages.create(*args, **kwargs)


def _api_error():
    return anthropic.APIConnectionError(request=httpx2.Request("POST", "http://x"))


def test_a_failing_batch_stops_but_keeps_earlier_results(tmp_path, capsys):
    path = tmp_path / "out.json"
    out = io.StringIO()
    result = replay_live.run(TEXT, FailingClient(_api_error()), json_path=str(path), out=out)
    assert len(result["steps"]) == 1 and "batch 2" in result["error"]
    assert "- Trip" in out.getvalue() and "Moves: new 1" in out.getvalue()
    err = capsys.readouterr().err
    assert err.count("\n") == 1 and "batch 2" in err
    data = json.loads(path.read_text())
    assert len(data["steps"]) == 1 and "batch 2" in data["error"]


def test_any_exception_is_caught_and_main_exits_non_zero(tmp_path, capsys):
    transcript = tmp_path / "t.txt"
    transcript.write_text(TEXT)
    code = replay_live.main([str(transcript)], client=FailingClient(RuntimeError("boom")))
    captured = capsys.readouterr()
    assert code == 1 and "batch 2" in captured.err and "boom" in captured.err
    assert "batch   1" in captured.out


def test_non_utf8_transcript_gives_one_line_error(tmp_path, capsys):
    transcript = tmp_path / "t.txt"
    transcript.write_bytes(b"\xff\xfe\x00bad")
    assert replay_live.main([str(transcript)], client=scripted_client(MOVES, [])) == 1
    captured = capsys.readouterr()
    assert captured.out == "" and captured.err.count("\n") == 1 and "UTF-8" in captured.err
