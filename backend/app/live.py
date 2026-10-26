"""Live mapping: one small move per batch of new words.

The app sends the outline it holds, the previous batch, and the new words. Claude picks
one move (stay / deeper / new / back); ``apply_move`` applies it in plain Python, so a
bad answer can never break the outline, and ``layout()`` draws it.
"""

from __future__ import annotations

import re
from typing import Literal

import anthropic
from pydantic import BaseModel

from .models import LiveReply, LiveRequest
from .topic_map import MODEL, Outline, OutlineBullet, OutlineNode, _strict_schema, layout, structured_call


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


def _topic_key(node: OutlineNode, by_id: dict[str, OutlineNode]) -> str:
    """One key per subject: a "(cont.)" topic and the topic it returns to share it."""
    root = _root(node, by_id)
    return root.continues if root.continues in by_id else root.id


def apply_move(outline: Outline | None, move: LiveMove) -> tuple[Outline, str]:
    """Return the outline after ``move``, and the move actually applied."""
    nodes = [n.model_copy(deep=True) for n in outline.nodes] if outline else []
    by_id = {n.id: n for n in nodes}
    current = by_id.get(outline.current) if outline else None

    kind = move.move
    label = move.label.strip()
    target = by_id.get(move.back_to.strip()) if kind == "back" else None
    # deeper may name where the sub-topic goes (back_to): NOW, or a node in NOW's topic,
    # so a sibling sub-topic sits next to NOW instead of under it. A node in the earlier
    # part of a topic that NOW continues puts it under the "(cont.)" node, so the map
    # keeps growing where the conversation is.
    under = current
    if kind == "deeper" and current is not None:
        named = by_id.get(move.back_to.strip())
        if named is not None and _topic_key(named, by_id) == _topic_key(current, by_id):
            same_part = _root(named, by_id) is _root(current, by_id)
            under = named if same_part else _root(current, by_id)

    if current is None:
        kind, label = "new", label or FALLBACK_TITLE
    elif kind in ("deeper", "new") and not label:
        kind = "stay"
    elif kind == "deeper":
        def named_like_label(n: OutlineNode) -> bool:
            return n.title.strip().lower() == label.lower()

        above, seen = under, {under.id}
        while not named_like_label(above) and above.parent in by_id and above.parent not in seen:
            above = by_id[above.parent]
            seen.add(above.id)
        # A sub-topic that already exists in this topic is a return to it.
        key = _topic_key(current, by_id)
        same = next((n for n in nodes if n.parent and named_like_label(n)
                     and _topic_key(n, by_id) == key), None)
        if named_like_label(above):
            kind = "stay"          # named after where it would go: nothing new
        elif same is not None:
            kind, target = "back", same
            if target is current:
                kind = "stay"
    elif kind == "new":
        # A "new" topic that is really an existing top-level topic is a return to it.
        same = next((n for n in nodes if not n.parent and not n.continues
                     and n.title.strip().lower() == label.lower()), None)
        if same is not None:
            kind, target = "back", same
            if target is current:
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
        here = add(label, parent=under.id)
    elif kind == "new":
        here = add(label)
    elif kind == "back":
        root = _root(target, by_id)
        current_root = _root(current, by_id)

        if _topic_key(target, by_id) == _topic_key(current, by_id):
            # Same topic: reuse the node already in use, never add a second "(cont.)".
            here = target if root is current_root else current_root
        else:
            original = root.continues if root.continues in by_id else root.id
            here = add(by_id[original].title, continues=original)
    else:
        here = current

    talked = {text.strip().lower() for text in move.talked_about}
    for bullet in here.bullets:
        if bullet.text.strip().lower() in talked:
            bullet.talked_about = True
    existing = {b.text.strip().lower(): b for b in here.bullets}
    for bullet in move.add_bullets:
        text = bullet.text.strip()
        if not text:
            continue
        stored = existing.get(text.lower())
        if stored is None:
            stored = OutlineBullet(text=text, talked_about=bullet.talked_about)
            here.bullets.append(stored)
            existing[text.lower()] = stored
        elif bullet.talked_about:
            stored.talked_about = True      # never downgrade true -> false
    if move.description.strip():
        here.description = move.description.strip()

    if here is current and kind in ("back", "new"):
        kind = "stay"          # the NOW node did not change
    return Outline(nodes=nodes, current=here.id), kind


LIVE_PROMPT = """\
You keep a live topic map of an in-person conversation for 1DMD, an app that shows \
people where their conversation is, how they got there, and what they came back to.

Every few seconds you get the current map and the newest words. Decide ONE move:
- stay: the new words are still about the node marked NOW. This is the most common \
answer. Choose it whenever you are unsure.
- deeper: the speakers are now focused on one specific part of the current topic (an \
option, a detail, a person, a sub-question) rather than the topic as a whole. Give a \
label. back_to says where the sub-topic goes: "" puts it under NOW; the id of NOW's \
parent makes it a sibling of NOW (they moved from one part of the topic to another \
part); any node in NOW's topic puts it under that node.
- new: the subject changed to something unrelated to the current topic. Give a label.
- back: the speakers returned to a node already on the map (a parent topic, a sibling \
sub-topic, or an earlier topic). Set back_to to its id.

Sub-topics are what make the map useful: when the speakers spend more than a passing \
sentence on one specific part of the topic, go deeper. When NOW is a sub-topic and the \
speakers move to a different part of the same topic, make a sibling (deeper with back_to \
set to the parent), not a child of NOW. When they speak about the topic as a whole \
again, go back to the parent.

Avoid jitter: do not move for a single passing remark or question. new needs a clear \
change of subject; anything related to the current topic is stay, deeper or back.

The words come from on-device speech recognition: no speaker labels, misheard words, \
filler. Read past them. Never make a topic or bullet out of a transcription error.

Fields:
- label: 1 to 4 words, sentence case, the speakers' own terms. "" unless deeper or new.
- back_to: an id from the map. For back, where they returned to. For deeper, where the \
sub-topic goes ("" for under NOW). "" for stay and new.
- add_bullets: 0 to 2 new points raised in these words, 1 to 5 words each, for the node \
the conversation is on after your move. talked_about is true when discussed, false when \
only mentioned. Do not repeat bullets the map already has.
- talked_about: texts of that node's existing bullets that these words actually discussed.
- description: a terse note of the specifics said about the node the conversation is \
on after your move (names, numbers, choices, reasons, what was decided or left open), \
under 25 words, from what was said only. Write like notes, not a report: never start \
with "The speaker", "They", "The conversation" or "Discussion of", and don't restate the \
label. Example: "Rent $2,100 near Capitol Hill; lease starts June 1; parking still \
unsure." Write one for a node you just made or returned to; for stay, "" unless the \
current description is now wrong or missing a key detail just said.\
"""


OTHER_THREADS_SHOWN = 5   # open threads from outside the NOW topic that still get listed


def summarize(outline: Outline | None) -> str:
    """The short map Claude sees: every topic, the NOW topic's tree, NOW, open threads.

    Top-level topics are always listed (back_to may pick any of them). Sub-topics and open
    threads are listed in full only for the NOW topic's tree, plus a few recent threads
    elsewhere, so the size stays flat however long the conversation runs.
    """
    if outline is None or not outline.nodes:
        return "(empty: this is the start of the conversation)"
    by_id = {n.id: n for n in outline.nodes}

    def root(node: OutlineNode) -> OutlineNode:
        seen = {node.id}
        while node.parent in by_id and node.parent not in seen:
            node = by_id[node.parent]
            seen.add(node.id)
        return node

    def depth(node: OutlineNode) -> int:
        d, seen = 0, {node.id}
        while node.parent in by_id and node.parent not in seen:
            node = by_id[node.parent]
            seen.add(node.id)
            d += 1
        return d

    current = by_id.get(outline.current)
    # The NOW topic's tree: its root, the topic it returns to, and topics that return to it.
    # A "(cont.)" topic and its original are one subject.
    in_tree: set[str] = set()
    if current is not None:
        now_root = root(current)
        in_tree.add(now_root.id)
        if now_root.continues in by_id:
            in_tree.add(root(by_id[now_root.continues]).id)
        for n in outline.nodes:
            if n.continues in by_id and root(by_id[n.continues]).id == now_root.id:
                in_tree.add(root(n).id)

    lines = []
    for n in outline.nodes:
        top = root(n)
        if n.id != top.id and top.id not in in_tree:
            continue
        cont = f" (returns to {n.continues})" if n.continues else ""
        now = "  <- NOW" if n.id == outline.current else ""
        lines.append(f"{'  ' * depth(n)}- [{n.id}] {n.title}{cont}{now}")
    if current is not None:
        if current.parent in by_id:
            lines.append(f"NOW node's parent: {current.parent}")
        lines.append(f"NOW node bullets: {', '.join(b.text for b in current.bullets) or '(none)'}")
        lines.append(f"NOW node description: {current.description or '(none)'}")
    here, elsewhere = [], []
    for n in outline.nodes:
        for b in n.bullets:
            if not b.talked_about:
                (here if root(n).id in in_tree else elsewhere).append(f'"{b.text}" ({n.id})')
    shown = elsewhere[-OTHER_THREADS_SHOWN:]      # later nodes are more recent
    threads = here + shown[::-1]                   # most recent first among the others
    text = "Open threads: " + (", ".join(threads) or "(none)")
    if len(elsewhere) > len(shown):
        text += f" (+{len(elsewhere) - len(shown)} more elsewhere)"
    lines.append(text)
    return "\n".join(lines)


def next_move(outline: Outline | None, previous_words: str, words: str,
              client: anthropic.Anthropic, *, model: str = MODEL, effort: str = "low") -> LiveMove:
    content = (f"<map>\n{summarize(outline)}\n</map>\n"
               f"<previous_words>\n{previous_words}\n</previous_words>\n"
               f"<new_words>\n{words}\n</new_words>")
    # effort "low": live updates must be fast; scripts/replay_live.py compares it with "medium".
    return structured_call(client, system=LIVE_PROMPT, content=content, schema=LIVE_SCHEMA,
                           model_cls=LiveMove, max_tokens=2000, effort=effort, model=model)


def live_update(request: LiveRequest, client: anthropic.Anthropic, *, model: str = MODEL,
                effort: str = "low") -> LiveReply:
    """New words in, the updated outline and map out."""
    if not request.words.strip():
        return LiveReply(outline=request.outline,
                         map=layout(request.outline) if request.outline else None, move="none")
    move = next_move(request.outline, request.previous_words, request.words, client,
                     model=model, effort=effort)
    outline, applied = apply_move(request.outline, move)
    return LiveReply(outline=outline, map=layout(outline), move=applied)
