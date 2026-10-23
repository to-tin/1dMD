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
