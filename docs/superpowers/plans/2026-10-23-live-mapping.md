# Live Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the topic map build live while people talk: the app sends batches of new words to a new `POST /live` endpoint, Claude makes one small move, and the map updates on screen.

**Architecture:** The app holds the map (an outline plus the drawn map). Each batch it sends the outline, the previous batch, and the new words to a stateless `/live` route. The server asks Claude Haiku for one move, applies it to the outline with plain Python (`apply_move`), lays it out with PR #16's `layout()`, and returns outline + map synchronously. On stop the app saves the chat with its outline, so it can be continued live.

**Tech Stack:** Python 3.11+, FastAPI, Pydantic 2, `anthropic==2.2.0` (structured outputs), pytest with `httpx2.MockTransport`; Swift 5 / SwiftUI / Observation, iOS 26, XCTest with `URLProtocol` stubs.

**Spec:** `docs/superpowers/specs/2026-10-23-live-mapping-design.md`

## Global Constraints

- Branch: `live-map` (contains PRs #15 and #16). Two PRs: server (Tasks 1–4), then app (Tasks 5–10).
- Model: `claude-haiku-5-5`. Never hardcode an API key; the server reads `ANTHROPIC_API_KEY`.
- Send a batch on ~20 new finished words, or ~3 s of silence if fewer.
- One `/live` request in flight at a time; words arriving meanwhile ride along with the next.
- A failed update never changes or loses the map and never loses words.
- On stop: send leftover words once, then save outline + map + transcript. No re-mapping.
- `/live` is synchronous and stateless; `/jobs` keeps its contract and also returns `outline`.
- Audio never leaves the phone; only text is sent.
- Do not modify `AudioTranscriber.swift` (CLAUDE.md); read `finalText` from it.
- Tests never call the real API (`tests/conftest.py` unsets the key).

## Review Focus

- Words spoken while a request is in flight must be sent with the next batch, never dropped or sent twice → test in Task 8 (`testWordsDuringRequestRideAlongNext`).
- Wi-Fi drops mid-conversation: map unchanged, words kept, no tight retry loop, catches up when back → Task 8 (`testOfflineKeepsMapAndRetriesOnPause`).
- Claude answers `back` to the current node or an unknown id, or `deeper`/`new` with an empty label → treated as `stay` → Task 1.
- Continuing a chat saved before outlines existed must keep its map, not restart from empty → Task 5 (`testOutlineRebuiltFromOldMap`).
- Stop pressed while a request is in flight: the last words still reach the saved chat → Task 8 (`testFinishWaitsAndSendsLeftovers`).

## File Structure

Server (`backend/`):
- `app/live.py` (new): live prompt, `LiveMove` schema, `apply_move()`, `summarize()`, `next_move()`, `live_update()`.
- `app/topic_map.py` (modify): extract shared `structured_call()`; `map_transcript()` also returns `outline`.
- `app/models.py` (modify): `LiveRequest`, `LiveReply`.
- `app/processing.py` (modify): `process_live()` (Claude or no-key passthrough).
- `app/api.py`, `app/main.py` (modify): `POST /live` route, `live` processor on app state.
- `tests/test_live.py` (new), `tests/test_topic_map.py`, `tests/test_api.py` (modify).
- `README.md`, `../READMEBACKEND.md` (modify): `/live` contract, iPhone setup.

App (`ios/`):
- `OneDMD/MapOutline.swift` (new): `MapOutline` model + rebuild from an old `NodeMapData`.
- `OneDMD/NodeMapData.swift` (modify): `outline` field.
- `OneDMD/ServerMap.swift` (modify): decode `outline`.
- `OneDMD/LiveMapper.swift` (new): batching, one-at-a-time sending, offline handling, `finish()`.
- `OneDMD/ServerBackend.swift`, `OneDMD/MapService.swift` (modify): `LiveBackend`, `POST /live`, server address setting.
- `OneDMD/ContentView.swift` (modify): live map while recording, save on stop, offline note.
- `OneDMD/PastChatsView.swift` (modify): server address field.
- `OneDMD/Info.plist` (modify): local-network HTTP + usage text.
- `OneDMDTests/LiveMapperTests.swift` (new), `OneDMDTests/ChatStoreTests.swift`, `OneDMDTests/IntegrationTests.swift` (modify).

### Commands used throughout

- Server tests: `cd backend && .venv/bin/python -m pytest -q` (install dev deps once: `.venv/bin/python -m pip install -r requirements-dev.txt`).
- App tests: `cd ios && xcodebuild test -project OneDMD.xcodeproj -scheme OneDMD -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:OneDMDTests/<Class>/<test>`.
- Adding a Swift file to the Xcode project (needed for every new `.swift` file; the project does not auto-include files). Run from `ios/`, replacing `NAME.swift` and `TARGET` (`app` or `tests`):

```bash
python3 - NAME.swift TARGET <<'EOF'
import sys, uuid
name, target = sys.argv[1], sys.argv[2]
p = 'OneDMD.xcodeproj/project.pbxproj'
s = open(p).read()
assert name not in s, 'already in project'
ref, bf = uuid.uuid4().hex[:24].upper(), uuid.uuid4().hex[:24].upper()
anchor_ref, anchor_bf, anchor_name = (
    ('2FFC49423074143900D87AAA', '2FFC49433074143900D87AAA', 'WaveformView.swift') if target == 'app'
    else ('C20000000000000000000001', 'C10000000000000000000001', 'IntegrationTests.swift'))
out = []
for line in s.split('\n'):
    out.append(line)
    if (anchor_ref in line or anchor_bf in line) and anchor_name in line and 'children' not in line and 'files = (' not in line:
        out.append(line.replace(anchor_ref, ref).replace(anchor_bf, bf).replace(anchor_name, name))
s = '\n'.join(out)
if target == 'tests':  # the tests group and sources phase are single-line lists
    s = s.replace(f'{anchor_ref} /* {anchor_name} */, ', f'{anchor_ref} /* {anchor_name} */, {ref} /* {name} */, ', 1)
    s = s.replace(f'{anchor_bf} /* {anchor_name} in Sources */, ', f'{anchor_bf} /* {anchor_name} in Sources */, {bf} /* {name} in Sources */, ', 1)
open(p, 'w').write(s)
print('added', name, 'to', target, 'with', s.count(name), 'references')
EOF
```

Expected output: `added NAME.swift to app with 4 references` (or `tests`).

---

## PR A: Server

### Task 1: `apply_move()` and the move schema

**Files:**
- Create: `backend/app/live.py`
- Test: `backend/tests/test_live.py`

**Interfaces:**
- Consumes: `Outline`, `OutlineNode`, `OutlineBullet`, `_strict_schema` from `app/topic_map.py`.
- Produces: `LiveMove` (Pydantic: `move: Literal["stay","deeper","new","back"]`, `label: str`, `back_to: str`, `add_bullets: list[OutlineBullet]`, `talked_about: list[str]`, `description: str`); `LIVE_SCHEMA: dict`; `apply_move(outline: Outline | None, move: LiveMove) -> tuple[Outline, str]` returning the new outline and the move actually applied.

- [ ] **Step 1: Write the failing tests**

`backend/tests/test_live.py`:

```python
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && .venv/bin/python -m pytest tests/test_live.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.live'`.

- [ ] **Step 3: Write `backend/app/live.py`**

```python
"""Live mapping: one small move per batch of new words.

The app sends the outline it holds, the previous batch, and the new words. Claude picks
one move (stay / deeper / new / back); ``apply_move`` applies it in plain Python, so a
bad answer can never break the outline, and ``layout()`` draws it.
"""

from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel

from .topic_map import Outline, OutlineBullet, OutlineNode, _strict_schema


FALLBACK_TITLE = "Conversation"


class LiveMove(BaseModel):
    move: Literal["stay", "deeper", "new", "back"]
    label: str
    back_to: str
    add_bullets: list[OutlineBullet]
    talked_about: list[str]
    description: str


LIVE_SCHEMA = _strict_schema(LiveMove.model_json_schema())


def _slug(title: str, taken: set[str]) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "topic"
    candidate, n = base, 2
    while candidate in taken:
        candidate, n = f"{base}-{n}", n + 1
    return candidate


def _root(node: OutlineNode, by_id: dict[str, OutlineNode]) -> OutlineNode:
    seen = {node.id}
    while node.parent and node.parent in by_id and node.parent not in seen:
        node = by_id[node.parent]
        seen.add(node.id)
    return node


def apply_move(outline: Outline | None, move: LiveMove) -> tuple[Outline, str]:
    """Return the outline after ``move``, and the move actually applied."""
    nodes = [n.model_copy(deep=True) for n in outline.nodes] if outline else []
    by_id = {n.id: n for n in nodes}
    current = by_id.get(outline.current) if outline else None

    kind = move.move
    label = move.label.strip()
    target = by_id.get(move.back_to.strip()) if kind == "back" else None

    if current is None:
        kind, label = "new", label or FALLBACK_TITLE
    elif kind in ("deeper", "new") and not label:
        kind = "stay"
    elif kind == "back" and (target is None or target is current):
        kind = "stay"

    def add(title: str, parent: str = "", continues: str = "") -> OutlineNode:
        created = OutlineNode(id=_slug(title, set(by_id)), title=title, parent=parent,
                              continues=continues, description="", bullets=[])
        nodes.append(created)
        by_id[created.id] = created
        return created

    if kind == "deeper":
        here = add(label, parent=current.id)
    elif kind == "new":
        here = add(label)
    elif kind == "back":
        root = _root(target, by_id)
        if root is _root(current, by_id):
            here = target
        else:
            original = root.continues if root.continues in by_id else root.id
            here = add(by_id[original].title, continues=original)
    else:
        here = current

    talked = {text.strip().lower() for text in move.talked_about}
    for bullet in here.bullets:
        if bullet.text.lower() in talked:
            bullet.talked_about = True
    existing = {b.text.lower() for b in here.bullets}
    for bullet in move.add_bullets:
        text = bullet.text.strip()
        if text and text.lower() not in existing:
            here.bullets.append(OutlineBullet(text=text, talked_about=bullet.talked_about))
            existing.add(text.lower())
    if move.description.strip():
        here.description = move.description.strip()

    return Outline(nodes=nodes, current=here.id), kind
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd backend && .venv/bin/python -m pytest tests/test_live.py -q`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/live.py backend/tests/test_live.py
git commit -m "Live: apply one map move per batch in plain Python"
```

### Task 2: Ask Claude for the move

**Files:**
- Modify: `backend/app/topic_map.py` (extract `structured_call`; use it in `outline_transcript`)
- Modify: `backend/app/live.py` (add `LIVE_PROMPT`, `summarize`, `next_move`)
- Test: `backend/tests/test_live.py`

**Interfaces:**
- Consumes: `apply_move`, `LiveMove`, `LIVE_SCHEMA` (Task 1); `MODEL`, `TopicMapError` from `topic_map.py`.
- Produces: `structured_call(client, *, system: str, content: str, schema: dict, model_cls: type[T], max_tokens: int, effort: str) -> T` in `topic_map.py`; `summarize(outline: Outline | None) -> str`; `next_move(outline: Outline | None, previous_words: str, words: str, client) -> LiveMove`.

- [ ] **Step 1: Write the failing tests** (append to `backend/tests/test_live.py`)

```python
import json

import anthropic
from anthropic import DefaultHttpxClient
import httpx2

from app.live import LIVE_PROMPT, next_move, summarize
from app.topic_map import MODEL, TopicMapError


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
    assert "[dune] Dune" in text and "  - [worms] Worms" in text
    assert "[nyc] New York  <- NOW" in text
    assert '"Politics" (dune)' in text       # an open thread
    assert '"Worms"' not in text.split("Open threads")[1]  # talked about, so not open


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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd backend && .venv/bin/python -m pytest tests/test_live.py -q`
Expected: FAIL with `ImportError: cannot import name 'LIVE_PROMPT'`.

- [ ] **Step 3: Extract `structured_call` in `backend/app/topic_map.py`**

Add after `class TopicMapError`:

```python
from typing import TypeVar

T = TypeVar("T", bound=BaseModel)


def structured_call(client: anthropic.Anthropic, *, system: str, content: str, schema: dict,
                    model_cls: type[T], max_tokens: int, effort: str) -> T:
    """One Claude call whose reply is forced into ``model_cls``; raises TopicMapError."""
    response = client.messages.create(
        model=MODEL,
        max_tokens=max_tokens,
        # The prompt never changes, so it is cached across calls (cache reads cost 0.1x).
        system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        messages=[{"role": "user", "content": content}],
        output_config={"effort": effort, "format": {"type": "json_schema", "schema": schema}},
    )
    # Check why Claude stopped before reading the reply: a declined or cut-off reply
    # is not valid JSON, and the caller should say which it was.
    if response.stop_reason == "refusal":
        category = response.stop_details.category if response.stop_details else None
        raise TopicMapError(f"Claude declined (category: {category}).")
    if response.stop_reason == "max_tokens":
        raise TopicMapError("The reply was cut off at the token limit.")
    text = next((block.text for block in response.content if block.type == "text"), "")
    try:
        result = model_cls.model_validate_json(text)
    except ValidationError as error:
        raise TopicMapError("Claude's reply was not a valid " + model_cls.__name__ + ".") from error
    usage = response.usage
    logger.info("%s: %d input / %d cached / %d output tokens (request %s)", model_cls.__name__,
                usage.input_tokens, usage.cache_read_input_tokens or 0, usage.output_tokens,
                response._request_id)
    return result
```

Replace the body of `outline_transcript` after the empty check with:

```python
    outline = structured_call(
        client, system=SYSTEM_PROMPT,
        content=f"<transcript>\n{transcript}\n</transcript>",
        schema=OUTLINE_SCHEMA, model_cls=Outline, max_tokens=MAX_TOKENS,
        # effort: Haiku 5.5's default, pinned so it can't drift.
        effort="medium",
    )
    if not outline.nodes:
        raise TopicMapError("Claude returned no topics.")
    return outline
```

Update the two message assertions in `tests/test_topic_map.py` that changed wording: `match="declined"` still matches; change `match="cut off"` (still matches) and `match="not a valid outline"` → `match="not a valid Outline"`.

- [ ] **Step 4: Add the live prompt and calls to `backend/app/live.py`**

```python
import anthropic

from .topic_map import TopicMapError, structured_call

LIVE_PROMPT = """\
You keep a live topic map of an in-person conversation for 1DMD, an app that shows \
people where their conversation is, how they got there, and what they came back to.

Every few seconds you get the current map and the newest words. Decide ONE move:
- stay: still the same topic as the node marked NOW. This is the right answer most of \
the time. Choose it whenever you are unsure.
- deeper: the speakers started digging into one part of the NOW node. Give a label.
- new: the subject clearly changed to something unrelated. Give a label.
- back: the speakers returned to an earlier node. Set back_to to its id.

Topic jitter is the main way this goes wrong. Do not move for a passing remark, a \
question, or a few words. Only move when the new words are clearly about something else.

The words come from on-device speech recognition: no speaker labels, misheard words, \
filler. Read past them. Never make a topic or bullet out of a transcription error.

Fields:
- label: 1 to 4 words, sentence case, the speakers' own terms. "" unless deeper or new.
- back_to: an id from the map. "" unless back.
- add_bullets: 0 to 2 new points raised in these words, 1 to 5 words each, for the node \
the conversation is on after your move. talked_about is true when discussed, false when \
only mentioned. Do not repeat bullets the map already has.
- talked_about: texts of that node's existing bullets that these words actually discussed.
- description: 1 to 2 plain sentences describing the node the conversation is on after \
your move, from what was said only. "" to keep the current description.\
"""


def summarize(outline: Outline | None) -> str:
    """The short map Claude sees: ids, titles, nesting, NOW, open threads."""
    if outline is None or not outline.nodes:
        return "(empty: this is the start of the conversation)"
    by_id = {n.id: n for n in outline.nodes}

    def depth(node: OutlineNode) -> int:
        d, seen = 0, {node.id}
        while node.parent in by_id and node.parent not in seen:
            node = by_id[node.parent]
            seen.add(node.id)
            d += 1
        return d

    lines = []
    for n in outline.nodes:
        cont = f" (returns to {n.continues})" if n.continues else ""
        now = "  <- NOW" if n.id == outline.current else ""
        lines.append(f"{'  ' * depth(n)}- [{n.id}] {n.title}{cont}{now}")
    current = by_id.get(outline.current)
    if current is not None:
        lines.append(f"NOW node bullets: {', '.join(b.text for b in current.bullets) or '(none)'}")
        lines.append(f"NOW node description: {current.description or '(none)'}")
    open_threads = [f'"{b.text}" ({n.id})' for n in outline.nodes for b in n.bullets if not b.talked_about]
    lines.append("Open threads: " + (", ".join(open_threads) or "(none)"))
    return "\n".join(lines)


def next_move(outline: Outline | None, previous_words: str, words: str,
              client: anthropic.Anthropic) -> LiveMove:
    content = (f"<map>\n{summarize(outline)}\n</map>\n"
               f"<previous_words>\n{previous_words}\n</previous_words>\n"
               f"<new_words>\n{words}\n</new_words>")
    # effort "low": live updates must be fast; measure against "medium" before changing.
    return structured_call(client, system=LIVE_PROMPT, content=content, schema=LIVE_SCHEMA,
                           model_cls=LiveMove, max_tokens=2000, effort="low")
```

(`OutlineNode` and `TopicMapError` imports: extend the existing `from .topic_map import ...` line.)

- [ ] **Step 5: Run all server tests**

Run: `cd backend && .venv/bin/python -m pytest -q`
Expected: all PASS (Task 1 tests, new tests, existing topic_map tests).

- [ ] **Step 6: Commit**

```bash
git add backend/app/live.py backend/app/topic_map.py backend/tests/test_live.py backend/tests/test_topic_map.py
git commit -m "Live: ask Claude Haiku for one move with a cached prompt and map summary"
```

### Task 3: `POST /live`

**Files:**
- Modify: `backend/app/models.py`, `backend/app/live.py`, `backend/app/processing.py`, `backend/app/api.py`, `backend/app/main.py`
- Test: `backend/tests/test_live.py`

**Interfaces:**
- Consumes: `next_move`, `apply_move` (Tasks 1–2); `layout` from `topic_map.py`.
- Produces: `LiveRequest(outline: Outline | None = None, previous_words: str = "", words: str)`; `LiveReply(outline: Outline | None, map: dict[str, JsonValue] | None, move: str)`; `live_update(request: LiveRequest, client) -> LiveReply`; `process_live(request: LiveRequest) -> LiveReply`; `create_app(*, processor=..., live=process_live)`; HTTP `POST /live` → 200 `LiveReply` JSON, 422 bad body, 502 on any failure.

- [ ] **Step 1: Write the failing tests** (append to `backend/tests/test_live.py`)

```python
from fastapi.testclient import TestClient

from app import processing
from app.live import live_update
from app.main import create_app
from app.models import LiveReply, LiveRequest
from app.topic_map import layout


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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd backend && .venv/bin/python -m pytest tests/test_live.py -q`
Expected: FAIL with `ImportError: cannot import name 'LiveReply' from 'app.models'`.

- [ ] **Step 3: Add the models to `backend/app/models.py`**

```python
from .topic_map import Outline


class LiveRequest(BaseModel):
    outline: Outline | None = None
    previous_words: str = ""
    words: str


class LiveReply(BaseModel):
    outline: Outline | None
    map: dict[str, JsonValue] | None
    move: str
```

- [ ] **Step 4: Add `live_update` to `backend/app/live.py`**

```python
from .models import LiveReply, LiveRequest
from .topic_map import layout


def live_update(request: LiveRequest, client: anthropic.Anthropic) -> LiveReply:
    """New words in, the updated outline and map out."""
    if not request.words.strip():
        return LiveReply(outline=request.outline,
                         map=layout(request.outline) if request.outline else None, move="none")
    move = next_move(request.outline, request.previous_words, request.words, client)
    outline, applied = apply_move(request.outline, move)
    return LiveReply(outline=outline, map=layout(outline), move=applied)
```

- [ ] **Step 5: Add `process_live` to `backend/app/processing.py`**

```python
from .live import live_update
from .models import LiveReply, LiveRequest
from .topic_map import layout

LiveProcessor = Callable[[LiveRequest], LiveReply]


def process_live(request: LiveRequest) -> LiveReply:
    """Claude when a key is set; otherwise hand the outline back unchanged."""
    if not os.environ.get("ANTHROPIC_API_KEY"):
        logger.warning("ANTHROPIC_API_KEY is not set; /live returns the map unchanged.")
        return LiveReply(outline=request.outline,
                         map=layout(request.outline) if request.outline else None, move="none")
    return live_update(request, _client())
```

- [ ] **Step 6: Add the route to `backend/app/api.py`**

```python
import logging

from .models import LiveReply, LiveRequest

logger = logging.getLogger(__name__)


@router.post("/live", response_model=LiveReply)
def live(payload: LiveRequest, request: Request) -> LiveReply:
    # A plain def runs in FastAPI's thread pool, so the blocking Claude call is fine here.
    try:
        return request.app.state.live(payload)
    except Exception:
        logger.exception("Live update failed")
        raise HTTPException(502, "Live update failed.")
```

And in `backend/app/main.py`: import `LiveProcessor, process_live`; add `live: LiveProcessor = process_live` to `create_app`'s keyword arguments and `app.state.live = live`.

- [ ] **Step 7: Run all server tests**

Run: `cd backend && .venv/bin/python -m pytest -q`
Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add backend/app backend/tests/test_live.py
git commit -m "Live: add synchronous POST /live"
```

### Task 4: `/jobs` returns its outline; server docs

**Files:**
- Modify: `backend/app/topic_map.py` (`map_transcript`), `backend/tests/test_topic_map.py`, `backend/README.md`, `READMEBACKEND.md`

**Interfaces:**
- Produces: `/jobs` completed `result` gains an `"outline"` key (same shape as `/live`'s `outline`) when mapped by Claude. The mock result has none.

- [ ] **Step 1: Update the test** in `tests/test_topic_map.py::test_request_uses_haiku_cached_prompt_and_schema`: replace `assert result == layout(DUNE)` with

```python
    assert result == {**layout(DUNE), "outline": DUNE.model_dump()}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd backend && .venv/bin/python -m pytest tests/test_topic_map.py -q`
Expected: FAIL (`outline` missing).

- [ ] **Step 3: Implement** in `topic_map.py`:

```python
def map_transcript(transcript: str, client: anthropic.Anthropic) -> dict[str, JsonValue]:
    """Transcript in, the app's positioned map out, plus the outline behind it
    (so the app can continue the chat live)."""
    outline = outline_transcript(transcript, client)
    return {**layout(outline), "outline": outline.model_dump()}
```

- [ ] **Step 4: Run all server tests** — Run: `cd backend && .venv/bin/python -m pytest -q` — Expected: all PASS.

- [ ] **Step 5: Docs.** In `backend/README.md` add a section after "AI mapping":

````markdown
## Live mapping

`POST /live` updates the map while people talk. It is synchronous and stateless: the app
sends the outline it holds plus the newest words, and gets the updated outline and map back
(target 1–3 s).

```json
{"outline": {"nodes": [], "current": "dune"} , "previous_words": "…", "words": "…"}
```

`outline` is `null` on a chat's first call. The reply is
`{"outline": …, "map": …, "move": "stay|deeper|new|back|none"}`. Claude picks one move;
`app/live.py::apply_move()` applies it in Python, so an invalid move becomes `stay`.
Failures return `502` and the app keeps its map. Without an API key the outline comes back
unchanged (`move: "none"`).

### Testing on a real iPhone

Run `./1dmd start --host 0.0.0.0` so the phone can reach the Mac over Wi-Fi, and set the
app's server address (Past chats → Server) to `http://<the Mac's local IP>:8000`. There is
no authentication: anyone on the same network can call the server and spend the key.
````

In `READMEBACKEND.md`, add a table row: ``| `POST /live`, JSON `{"outline":…|null,"previous_words":"…","words":"…"}` | `200 {"outline":…,"map":…,"move":"…"}` or `502` |`` and a sentence: "Completed `/jobs` results mapped by Claude also include `outline`."

- [ ] **Step 6: Commit and open PR A**

```bash
git add backend READMEBACKEND.md
git commit -m "Jobs return their outline; document /live and iPhone setup"
git push
```

Open a PR from a branch cut at this commit (`live-server`, base `ai-topic-map` until #16 merges), TL;DR-first description.

---

## PR B: App

### Task 5: `MapOutline` on the map, saved with chats

**Files:**
- Create: `ios/OneDMD/MapOutline.swift` (add to project: `app`)
- Modify: `ios/OneDMD/NodeMapData.swift`, `ios/OneDMD/ServerMap.swift`
- Test: `ios/OneDMDTests/ChatStoreTests.swift`

**Interfaces:**
- Produces: `struct MapOutline: Codable, Sendable, Equatable { struct Bullet { text: String; talkedAbout: Bool } (JSON key "talked_about"); struct Node { id, title, parent, continues, description: String; bullets: [Bullet] }; nodes: [Node]; current: String; init(rebuildingFrom map: NodeMapData) }`; `NodeMapData.outline: MapOutline?` (default `nil`); `NodeMapData.liveOutline: MapOutline?` = `outline ?? (nodes.isEmpty ? nil : MapOutline(rebuildingFrom: self))`.

- [ ] **Step 1: Write the failing tests** (append to `ChatStoreTests`)

```swift
    func testOutlineSavedWithTheMap() throws {
        var map = NodeMapData.sample
        map.outline = MapOutline(nodes: [.init(id: "dune", title: "Dune", parent: "", continues: "",
                                               description: "About Dune.", bullets: [.init(text: "Worms", talkedAbout: true)])],
                                 current: "dune")
        try store.save(SavedChat(transcript: "x", map: map))
        XCTAssertEqual(try XCTUnwrap(store.all().first).map?.outline, map.outline)
    }

    func testChatSavedBeforeOutlinesStillLoads() throws {
        var chat = SavedChat(transcript: "x", map: .sample)
        chat.map?.outline = nil
        try store.save(chat)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("outline"))
        XCTAssertNil(try XCTUnwrap(store.all().first).map?.outline)
    }

    func testOutlineRebuiltFromOldMap() throws {
        let rebuilt = try XCTUnwrap(NodeMapData.sample.liveOutline)
        XCTAssertEqual(rebuilt.current, "pizza")
        XCTAssertEqual(rebuilt.nodes.map(\.id), NodeMapData.sample.nodes.map(\.id))
        let pizza = try XCTUnwrap(rebuilt.nodes.first { $0.id == "pizza" })
        XCTAssertEqual(pizza.parent, "nyc")
        let dune = try XCTUnwrap(rebuilt.nodes.first { $0.id == "dune" })
        XCTAssertEqual(dune.bullets.map(\.text), ["Worms", "Spice", "Politics"])
        XCTAssertEqual(dune.bullets.map(\.talkedAbout), [true, false, false])
        XCTAssertNil(NodeMapData.empty.liveOutline)
    }

    func testServerOutlineDecodes() throws {
        let json = #"{"currentID":"a","nodes":[{"id":"a","title":"A","isTopic":true,"line":0,"column":0,"bullets":[]}],"edges":[],"outline":{"nodes":[{"id":"a","title":"A","parent":"","continues":"","description":"d","bullets":[{"text":"x","talked_about":false}]}],"current":"a"}}"#
        let map = try JSONDecoder().decode(ServerMap.self, from: Data(json.utf8)).mapData()
        XCTAssertEqual(map.outline?.nodes.first?.bullets.first, .init(text: "x", talkedAbout: false))
    }
```

- [ ] **Step 2: Run to verify they fail** — Run: `cd ios && xcodebuild test … -only-testing:OneDMDTests/ChatStoreTests` — Expected: build FAIL, `cannot find 'MapOutline' in scope`.

- [ ] **Step 3: Create `ios/OneDMD/MapOutline.swift`**

```swift
import Foundation

/// The server's outline behind a map: what the live endpoint reads and returns.
/// Kept with the map (and saved with the chat) so a chat can be continued live.
struct MapOutline: Codable, Sendable, Equatable {
    struct Bullet: Codable, Sendable, Equatable {
        var text: String
        var talkedAbout: Bool
        enum CodingKeys: String, CodingKey { case text, talkedAbout = "talked_about" }
    }

    struct Node: Codable, Sendable, Equatable {
        var id: String
        var title: String
        /// Id of the node this went deeper from; "" for a topic.
        var parent: String
        /// Id of the earlier topic this returns to; "" otherwise.
        var continues: String
        var description: String
        var bullets: [Bullet]
    }

    var nodes: [Node]
    var current: String
}

extension MapOutline {
    /// For maps saved before outlines existed: parents from `deeper` edges, returns from
    /// `continued` edges. Descriptions were never kept, so they start empty.
    init(rebuildingFrom map: NodeMapData) {
        let parents = Dictionary(map.edges.filter { $0.kind == .deeper }.map { ($0.to, $0.from) },
                                 uniquingKeysWith: { first, _ in first })
        let returns = Dictionary(map.edges.filter { $0.kind == .continued }.map { ($0.to, $0.from) },
                                 uniquingKeysWith: { first, _ in first })
        nodes = map.nodes.map { node in
            Node(id: node.id, title: node.title, parent: parents[node.id] ?? "",
                 continues: returns[node.id] ?? "", description: "",
                 bullets: node.bullets.map { Bullet(text: $0.text, talkedAbout: $0.isFilled) })
        }
        current = map.currentID ?? map.nodes.last?.id ?? ""
    }
}
```

Add to project: `cd ios && python3 - MapOutline.swift app <<'EOF' … EOF` (script in "Commands used throughout"), passing the path relative to the group: the app group's `path` is `OneDMD`, so the file name alone is correct.

- [ ] **Step 4: Add the field.** In `NodeMapData.swift`, inside `struct NodeMapData`, after `currentID`:

```swift
    /// The outline behind this map, when the server sent one. Saved with the chat so it
    /// can be continued live.
    var outline: MapOutline? = nil

    /// What to send to the live endpoint: the server's outline, or one rebuilt from an
    /// older map; nil for an empty map.
    var liveOutline: MapOutline? {
        outline ?? (nodes.isEmpty ? nil : MapOutline(rebuildingFrom: self))
    }
```

In `ServerMap.swift`: add `var outline: MapOutline?` to `struct ServerMap`, and in `mapData()` change the final line to:

```swift
        var map = NodeMapData(nodes: mappedNodes, edges: mappedEdges, currentID: currentID)
        map.outline = outline
        return map
```

- [ ] **Step 5: Run the tests** — Run: `cd ios && xcodebuild test … -only-testing:OneDMDTests` — Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add ios
git commit -m "App: keep the server's outline with the map and saved chats"
```

### Task 6: Server address setting and local-network access

**Files:**
- Modify: `ios/OneDMD/MapService.swift`, `ios/OneDMD/PastChatsView.swift`, `ios/OneDMD/Info.plist`
- Test: `ios/OneDMDTests/IntegrationTests.swift`

**Interfaces:**
- Produces: `MapService.serverURL: URL` (computed: `UserDefaults` `"serverURL"` if it is a valid `http(s)` URL with a host, else `http://127.0.0.1:8000`); `MapService.serverAddressKey = "serverURL"`.

- [ ] **Step 1: Write the failing test** (append to `IntegrationTests`)

```swift
    func testServerAddressSetting() {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: MapService.serverAddressKey) }
        defaults.removeObject(forKey: MapService.serverAddressKey)
        XCTAssertEqual(MapService.serverURL.absoluteString, "http://127.0.0.1:8000")
        defaults.set(" http://192.168.1.23:8000 ", forKey: MapService.serverAddressKey)
        XCTAssertEqual(MapService.serverURL.absoluteString, "http://192.168.1.23:8000")
        defaults.set("not a url", forKey: MapService.serverAddressKey)
        XCTAssertEqual(MapService.serverURL.absoluteString, "http://127.0.0.1:8000")
    }
```

- [ ] **Step 2: Run to verify it fails** — Expected: build FAIL, `type 'MapService' has no member 'serverAddressKey'`.

- [ ] **Step 3: Implement** in `MapService.swift`, replacing `static let serverURL = URL(string: "http://127.0.0.1:8000")!`:

```swift
    static let serverAddressKey = "serverURL"
    static let defaultServerURL = URL(string: "http://127.0.0.1:8000")!

    /// The simulator reaches the Mac at 127.0.0.1; a real iPhone needs the Mac's Wi-Fi
    /// address, set under Past chats → Server.
    static var serverURL: URL {
        let text = UserDefaults.standard.string(forKey: serverAddressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme), url.host != nil else {
            return defaultServerURL
        }
        return url
    }
```

- [ ] **Step 4: Add the field to the drawer.** In `PastChatsView.swift`, add to `PastChatsDrawer`:

```swift
    @AppStorage(MapService.serverAddressKey) private var serverAddress = ""
```

and at the end of the panel's `VStack` (after the list / empty state):

```swift
            VStack(alignment: .leading, spacing: 4) {
                Text("Server")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MapStyle.muted)
                TextField("http://127.0.0.1:8000", text: $serverAddress)
                    .font(.footnote.monospaced())
                    .foregroundStyle(MapStyle.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
```

- [ ] **Step 5: Info.plist.** Inside `NSAppTransportSecurity`, add `<key>NSAllowsLocalNetworking</key><true/>`. At the top level add:

```xml
    <key>NSLocalNetworkUsageDescription</key>
    <string>1DMD connects to your map server on this Wi-Fi network to build the map as you talk.</string>
```

- [ ] **Step 6: Run the tests** — Expected: all PASS. Then build and run on a real iPhone, set the server field to `http://<Mac IP>:8000` with the server started as `./1dmd start --host 0.0.0.0`, paste a transcript, and confirm a map arrives (accept the Local Network prompt).

- [ ] **Step 7: Commit**

```bash
git add ios
git commit -m "App: server address setting and local-network access for a real iPhone"
```

### Task 7: The live endpoint client

**Files:**
- Modify: `ios/OneDMD/MapService.swift` (types), `ios/OneDMD/ServerBackend.swift`
- Test: `ios/OneDMDTests/IntegrationTests.swift`

**Interfaces:**
- Consumes: `MapOutline`, `ServerMap.outline` (Task 5); `MapService.serverURL` (Task 6).
- Produces: `struct LiveRequest: Encodable, Sendable { outline: MapOutline?; previousWords: String; words: String }` (JSON keys `outline`, `previous_words`, `words`); `struct LiveReply: Sendable { map: NodeMapData?; move: String }` (`map.outline` carries the outline); `protocol LiveBackend: Sendable { func update(_ request: LiveRequest) async throws -> LiveReply }`; `extension ServerBackend: LiveBackend`; `MapService.liveBackend: any LiveBackend`.

- [ ] **Step 1: Write the failing test** (append to `IntegrationTests`; reuses its `session(_:)` and `StubProtocol`)

```swift
    func testLiveUpdateRoundTrip() async throws {
        let reply = #"{"outline":{"nodes":[{"id":"a","title":"A","parent":"","continues":"","description":"d","bullets":[]}],"current":"a"},"map":{"currentID":"a","nodes":[{"id":"a","title":"A","isTopic":true,"line":0,"column":0,"bullets":[]}],"edges":[]},"move":"new"}"#
        var sent: [String: Any] = [:]
        let backend = ServerBackend(base: base, session: session { request in
            XCTAssertEqual(request.url?.path, "/live")
            XCTAssertEqual(request.httpMethod, "POST")
            sent = try JSONSerialization.jsonObject(with: request.httpBodyStreamData()) as? [String: Any] ?? [:]
            return (200, Data(reply.utf8))
        })
        let result = try await backend.update(LiveRequest(outline: nil, previousWords: "", words: "hello there"))
        XCTAssertEqual(result.move, "new")
        XCTAssertEqual(result.map?.currentID, "a")
        XCTAssertEqual(result.map?.outline?.current, "a")
        XCTAssertEqual(sent["words"] as? String, "hello there")
        XCTAssertTrue(sent["outline"] is NSNull)
        XCTAssertEqual(sent["previous_words"] as? String, "")
    }

    func testLiveUpdateServerErrorThrows() async {
        let backend = ServerBackend(base: base, session: session { _ in (502, Data(#"{"detail":"Live update failed."}"#.utf8)) })
        do {
            _ = try await backend.update(LiveRequest(outline: nil, previousWords: "", words: "x"))
            XCTFail("Expected an error")
        } catch let MapServiceError.server(status, _) {
            XCTAssertEqual(status, 502)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }
```

If `IntegrationTests` has no `httpBodyStreamData()` helper, add this at file scope (URLProtocol stubs see the body as a stream):

```swift
extension URLRequest {
    func httpBodyStreamData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
```

(Check first with `grep -n "httpBodyStream" ios/OneDMDTests/IntegrationTests.swift`; reuse an existing helper if present.)

- [ ] **Step 2: Run to verify it fails** — Expected: build FAIL, `cannot find 'LiveRequest' in scope`.

- [ ] **Step 3: Types** in `MapService.swift` (in `// MARK: - Types`):

```swift
struct LiveRequest: Encodable, Sendable {
    var outline: MapOutline?
    var previousWords: String
    var words: String
    enum CodingKeys: String, CodingKey { case outline, previousWords = "previous_words", words }

    // Always send "outline" (as null on a chat's first call), matching the server contract.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outline, forKey: .outline)
        try c.encode(previousWords, forKey: .previousWords)
        try c.encode(words, forKey: .words)
    }
}

struct LiveReply: Sendable {
    /// nil only when the server has nothing to draw yet (no API key, first call).
    var map: NodeMapData?
    var move: String
}

protocol LiveBackend: Sendable {
    func update(_ request: LiveRequest) async throws -> LiveReply
}
```

And in `enum MapService`: `static var liveBackend: any LiveBackend { ServerBackend(base: serverURL) }`.

- [ ] **Step 4: Client** in `ServerBackend.swift`:

```swift
extension ServerBackend: LiveBackend {
    func update(_ payload: LiveRequest) async throws -> LiveReply {
        var request = URLRequest(url: base.appending(path: "live"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        Self.log(request, response, data)
        try Self.check(response, data, expected: 200)
        let reply: LiveServerReply = try Self.decode(data)
        // The server sends the outline beside the map; keep it on the map for the next call.
        var map = try reply.map?.mapData()
        map?.outline = reply.outline
        return LiveReply(map: map, move: reply.move)
    }

    private struct LiveServerReply: Decodable {
        var outline: MapOutline?
        var map: ServerMap?
        var move: String
    }
}
```

Change `log`, `check`, `decode` in `ServerBackend` from `private static` to `fileprivate static` so the extension can use them.

- [ ] **Step 5: Run the tests** — Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add ios
git commit -m "App: client for POST /live"
```

### Task 8: `LiveMapper`: batching, one request at a time, offline, finish

**Files:**
- Create: `ios/OneDMD/LiveMapper.swift` (project: `app`)
- Test: `ios/OneDMDTests/LiveMapperTests.swift` (project: `tests`)

**Interfaces:**
- Consumes: `LiveBackend`, `LiveRequest`, `LiveReply` (Task 7); `NodeMapData.liveOutline` (Task 5).
- Produces: `@MainActor @Observable final class LiveMapper { init(backend: any LiveBackend, startingMap: NodeMapData?, wordsPerUpdate: Int = 20, pause: Duration = .seconds(3)); private(set) var map: NodeMapData?; private(set) var isOffline: Bool; func heard(_ finalText: String); func finish() async -> NodeMapData? }`.

- [ ] **Step 1: Write the failing tests** — `ios/OneDMDTests/LiveMapperTests.swift`:

```swift
import XCTest
@testable import OneDMD

/// Scripted stand-in for the server. Each call answers with the next result; it records
/// requests and can hold a reply until released.
actor FakeLive: LiveBackend {
    var requests: [LiveRequest] = []
    var results: [Result<LiveReply, Error>] = []
    var gate: CheckedContinuation<Void, Never>?
    var holdNext = false

    func script(_ results: [Result<LiveReply, Error>]) { self.results = results }
    func hold() { holdNext = true }
    func release() { gate?.resume(); gate = nil }

    func update(_ request: LiveRequest) async throws -> LiveReply {
        requests.append(request)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        let next = results.isEmpty ? .success(LiveReply(map: request.outline.map { _ in .sample }, move: "stay")) : results.removeFirst()
        return try next.get()
    }
}

@MainActor
final class LiveMapperTests: XCTestCase {
    private func reply(_ current: String) -> LiveReply {
        var map = NodeMapData.sample
        map.currentID = current
        map.outline = MapOutline(nodes: [.init(id: current, title: current, parent: "", continues: "", description: "", bullets: [])], current: current)
        return LiveReply(map: map, move: "stay")
    }

    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(for: .seconds(seconds)) }

    func testSendsOnceEnoughWordsArrive() async {
        let fake = FakeLive()
        await fake.script([.success(reply("a"))])
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 5, pause: .seconds(10))
        mapper.heard("one two three")
        await settle()
        var count = await fake.requests.count
        XCTAssertEqual(count, 0)
        mapper.heard("one two three four five")
        await settle()
        count = await fake.requests.count
        XCTAssertEqual(count, 1)
        let first = await fake.requests[0]
        XCTAssertEqual(first.words, "one two three four five")
        XCTAssertNil(first.outline)
        XCTAssertEqual(mapper.map?.currentID, "a")
    }

    func testPauseSendsFewerWords() async {
        let fake = FakeLive()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 20, pause: .milliseconds(100))
        mapper.heard("just three words")
        await settle()
        let count = await fake.requests.count
        XCTAssertEqual(count, 1)
    }

    func testWordsDuringRequestRideAlongNext() async {
        let fake = FakeLive()
        await fake.script([.success(reply("a")), .success(reply("b"))])
        await fake.hold()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .milliseconds(100))
        mapper.heard("one two")
        await settle(0.1)
        mapper.heard("one two three four")          // arrives while the first is held
        mapper.heard("one two three four five six")
        await settle(0.1)
        var count = await fake.requests.count
        XCTAssertEqual(count, 1)                     // still one at a time
        await fake.release()
        await settle()
        count = await fake.requests.count
        XCTAssertEqual(count, 2)
        let second = await fake.requests[1]
        XCTAssertEqual(second.words, "three four five six")   // nothing dropped, nothing repeated
        XCTAssertEqual(second.previousWords, "one two")
        XCTAssertEqual(second.outline?.current, "a")
        XCTAssertEqual(mapper.map?.currentID, "b")
    }

    func testOfflineKeepsMapAndRetriesOnPause() async {
        let fake = FakeLive()
        await fake.script([.success(reply("a")), .failure(URLError(.notConnectedToInternet)), .success(reply("b"))])
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .milliseconds(150))
        mapper.heard("one two")
        await settle(0.1)
        mapper.heard("one two three four")
        await settle(0.05)
        XCTAssertTrue(mapper.isOffline)
        XCTAssertEqual(mapper.map?.currentID, "a")           // map unchanged
        var count = await fake.requests.count
        XCTAssertEqual(count, 2)                              // no instant retry loop
        await settle(0.3)
        count = await fake.requests.count
        XCTAssertEqual(count, 3)
        let retry = await fake.requests[2]
        XCTAssertEqual(retry.words, "three four")             // words kept
        XCTAssertFalse(mapper.isOffline)
        XCTAssertEqual(mapper.map?.currentID, "b")
    }

    func testFinishWaitsAndSendsLeftovers() async {
        let fake = FakeLive()
        await fake.script([.success(reply("a")), .success(reply("b"))])
        await fake.hold()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .seconds(10))
        mapper.heard("one two")
        await settle(0.1)
        mapper.heard("one two three")
        Task { try? await Task.sleep(for: .milliseconds(100)); await fake.release() }
        let final = await mapper.finish()
        XCTAssertEqual(final?.currentID, "b")
        let last = await fake.requests.last
        XCTAssertEqual(last?.words, "three")
    }

    func testFinishNeverSendsLeftoversTwice() async {
        let fake = FakeLive()
        await fake.hold()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .seconds(10))
        mapper.heard("one two")
        await settle(0.1)
        mapper.heard("one two three four five")   // enough for its own batch once the first lands
        Task { try? await Task.sleep(for: .milliseconds(100)); await fake.release() }
        _ = await mapper.finish()
        await settle()
        let words = await fake.requests.map(\.words)
        XCTAssertEqual(words, ["one two", "three four five"])
    }

    func testContinuingStartsFromTheSavedOutline() async {
        let fake = FakeLive()
        let mapper = LiveMapper(backend: fake, startingMap: .sample, wordsPerUpdate: 1, pause: .seconds(10))
        XCTAssertEqual(mapper.map?.currentID, "pizza")
        mapper.heard("hello")
        await settle()
        let first = await fake.requests.first
        XCTAssertEqual(first?.outline?.current, "pizza")
    }

    func testNoMapFromServerKeepsCurrentMap() async {
        let fake = FakeLive()
        await fake.script([.success(LiveReply(map: nil, move: "none"))])
        let mapper = LiveMapper(backend: fake, startingMap: .sample, wordsPerUpdate: 1, pause: .seconds(10))
        mapper.heard("hello")
        await settle()
        XCTAssertEqual(mapper.map?.currentID, "pizza")
    }
}
```

- [ ] **Step 2: Add the test file to the project and run to verify it fails**

Run: `cd ios && python3 - LiveMapperTests.swift tests <<'EOF' … EOF` then `xcodebuild test … -only-testing:OneDMDTests/LiveMapperTests`
Expected: build FAIL, `cannot find 'LiveMapper' in scope`.

- [ ] **Step 3: Create `ios/OneDMD/LiveMapper.swift`** and add it to the project (`app`)

```swift
import Foundation
import Observation

/// Builds the map while people talk. Feed it the transcriber's finished text; it sends new
/// words to the live endpoint once ~20 have piled up or after a pause, one request at a
/// time, and keeps the latest map. A failed request keeps the map and the words, and is
/// retried after the next pause rather than straight away.
@MainActor
@Observable
final class LiveMapper {
    private(set) var map: NodeMapData?
    private(set) var isOffline = false

    private let backend: any LiveBackend
    private let wordsPerUpdate: Int
    private let pause: Duration
    /// Everything heard so far (the transcriber's finalText) and how much of it was sent.
    private var heardText = ""
    private var sentCount = 0
    private var previousWords = ""
    private var inFlight: Task<Void, Never>?
    private var pauseTimer: Task<Void, Never>?
    /// Set by finish(): from then on only finish() sends, so leftovers can't go out twice.
    private var finishing = false

    init(backend: any LiveBackend, startingMap: NodeMapData?, wordsPerUpdate: Int = 20,
         pause: Duration = .seconds(3)) {
        self.backend = backend
        self.map = startingMap.flatMap { $0.nodes.isEmpty ? nil : $0 }
        self.wordsPerUpdate = wordsPerUpdate
        self.pause = pause
    }

    private var pending: String {
        String(heardText.dropFirst(sentCount)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Call whenever the transcriber's finished text changes.
    func heard(_ finalText: String) {
        heardText = finalText
        if sentCount > heardText.count { sentCount = 0 }   // transcriber restarted
        decide()
    }

    /// Send the leftover words once (after any request in flight), then return the map.
    func finish() async -> NodeMapData? {
        finishing = true
        pauseTimer?.cancel()
        while let task = inFlight { await task.value }
        if !pending.isEmpty { await send() }
        return map
    }

    private func decide() {
        guard !finishing, inFlight == nil, !pending.isEmpty else { return }
        if !isOffline, Self.wordCount(pending) >= wordsPerUpdate {
            startSending()
        } else {
            restartPauseTimer()
        }
    }

    private func restartPauseTimer() {
        pauseTimer?.cancel()
        pauseTimer = Task { [weak self, pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self, !self.finishing, self.inFlight == nil, !self.pending.isEmpty else { return }
            self.startSending()
        }
    }

    private func startSending() {
        pauseTimer?.cancel()
        inFlight = Task { [weak self] in
            await self?.send()
            self?.inFlight = nil
            self?.decide()
        }
    }

    private func send() async {
        let words = pending
        let upTo = heardText.count
        let request = LiveRequest(outline: map?.liveOutline, previousWords: previousWords, words: words)
        do {
            let reply = try await backend.update(request)
            if let newMap = reply.map { map = newMap }
            previousWords = words
            sentCount = upTo
            isOffline = false
        } catch {
            isOffline = true   // keep map and words; decide() waits for the pause timer
        }
    }
}
```

- [ ] **Step 4: Run the tests** — Run: `xcodebuild test … -only-testing:OneDMDTests/LiveMapperTests` — Expected: all 8 PASS. If a timing test is flaky, raise its `settle` waits, not the logic.

- [ ] **Step 5: Commit**

```bash
git add ios
git commit -m "App: LiveMapper batches words, one request at a time, survives offline"
```

### Task 9: Live map on screen; save on stop

**Files:**
- Modify: `ios/OneDMD/ContentView.swift`

**Interfaces:**
- Consumes: `LiveMapper` (Task 8), `MapService.liveBackend` (Task 7), `SavedChat.setMap` (existing).

- [ ] **Step 1: State.** Replace `@State private var demoStep = 0` (and its doc comment) with:

```swift
    /// Builds the map while recording; nil when not recording.
    @State private var live: LiveMapper?
```

- [ ] **Step 2: The map while recording.** Replace the `NodeMapView(...)` line and its `.task(id: state) { … demoStep … }` modifier with:

```swift
            // Idle: the open chat's map (or the sample). Recording: the live map.
            NodeMapView(data: state == .idle ? mapData : (live?.map ?? .empty))
```

Delete the old comment lines above it about the sample replay.

- [ ] **Step 3: Offline note.** In the same `.overlay { … }` chain, add a bottom overlay on the map:

```swift
                .overlay(alignment: .bottom) {
                    if state != .idle, live?.isOffline == true {
                        Text("Can't reach the server. The map will catch up.")
                            .font(.footnote)
                            .foregroundStyle(MapStyle.muted)
                            .padding(.bottom, 12)
                    }
                }
```

- [ ] **Step 4: Feed words.** On the root view (next to `.onAppear`), add:

```swift
        .onChange(of: transcriber.finalText) { _, text in live?.heard(text) }
```

- [ ] **Step 5: Start.** In `toggle()`, `case .idle:` add before `state = .recording` (and delete `demoStep = 0`):

```swift
                live = LiveMapper(backend: MapService.liveBackend, startingMap: openChat?.map)
```

- [ ] **Step 6: Stop.** In `finish()`, after the word-settling loop computes `words`, replace

```swift
            isFinishing = false
            guard !words.isEmpty else { return }
            saveRecording(words, recorded: recorded, into: continuing, started: started)
```

with

```swift
            let liveMap = await live?.finish()
            live = nil
            isFinishing = false
            guard !words.isEmpty else { return }
            saveRecording(words, recorded: recorded, into: continuing, started: started, map: liveMap)
```

Note `finish()` must call `live?.heard(transcriber.finalText)` once before `live?.finish()` so the settled final words are included:

```swift
            live?.heard(transcriber.finalText)
```

- [ ] **Step 7: Save the live map, no re-mapping.** Replace `saveRecording(...)` entirely with:

```swift
    /// Saves the words and the live map together. No re-mapping: what you watched is what's kept.
    private func saveRecording(_ words: String, recorded: TimeInterval, into continuing: SavedChat?,
                               started: Date, map: NodeMapData?) {
        var chat = continuing ?? SavedChat(transcript: "", now: started)
        chat.append(words: words, recorded: recorded)
        if let map, !map.nodes.isEmpty { chat.setMap(map) }
        guard persist(chat) else { return }
        openChat = chat
        mapData = chat.map ?? .empty
    }
```

Remove the now-unused `wordsSaved` parameter from `makeMap` and `AlertInfo.mapFailed` (and its extra message), and update the "No map yet" overlay text to: `"The words are saved. Record more in this chat once the server is reachable."`

- [ ] **Step 8: Build and run all app tests** — Run: `xcodebuild test … -only-testing:OneDMDTests` — Expected: build succeeds, all PASS.

- [ ] **Step 9: Simulator check** with the server running and a key set: start recording, speak (or play audio near the Mac's mic), confirm nodes appear within a few seconds, tap stop, confirm the chat in Past chats shows the same map; reopen it, record more, confirm it grows from the old map.

- [ ] **Step 10: Commit**

```bash
git add ios
git commit -m "App: live map while recording, saved as-is on stop"
```

### Task 10: Real iPhone run, docs, PR B

**Files:**
- Modify: `CLAUDE.md` (project files table and "How it works" now match the code), `backend/README.md` "Run the iOS app" (real iPhone steps)

- [ ] **Step 1: Real iPhone.** `./1dmd start --host 0.0.0.0` with the key set; on the phone set Server to `http://<Mac IP>:8000`; hold a 3–5 minute conversation with at least one tangent and one return. Record: typical seconds from speaking to the map updating, number of topics created, and any obviously wrong moves.

- [ ] **Step 2: Tune if needed.** If updates take > 3 s, try `wordsPerUpdate: 25`; if topics jitter, strengthen the `stay` paragraph in `LIVE_PROMPT` (server). Re-run Step 1 after each change; commit each change separately with the before/after numbers in the message.

- [ ] **Step 3: Docs.** In `CLAUDE.md`, replace the `AudioTranscriber / TopicBrain / TopicMap / SessionController` descriptions with the real pieces: `AudioTranscriber.swift`, `LiveMapper.swift`, `ServerBackend.swift` (`/jobs`, `/live`), `ChatStore.swift`, `backend/app/live.py`, `backend/app/topic_map.py`. Keep the design rules (one small move per call, bias to stay, short summary, on-device transcription).

- [ ] **Step 4: Commit, push, open PR B** (base: the server PR's branch until it merges; TL;DR-first description including the Step 1 numbers).

```bash
git add CLAUDE.md backend/README.md
git commit -m "Docs: live mapping on a real iPhone; CLAUDE.md matches the code"
git push
```
