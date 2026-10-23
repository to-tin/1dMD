"""Turn a conversation transcript into the app's topic map with Claude.

Two steps:
1. Claude reads the transcript and returns a simple outline (``Outline``): topics in the
   order they came up, what each one went deeper into, and a short description of each.
2. ``layout()`` turns that outline into the positioned graph the app draws
   (``line``/``column``, branch colours, edges). This step is plain code, not the model,
   so the graph is always valid: one wrong number from the model would break the map.
"""

from __future__ import annotations

import logging
from typing import Any, TypeVar

import anthropic
from pydantic import BaseModel, JsonValue, ValidationError


logger = logging.getLogger(__name__)

MODEL = "claude-haiku-5-5"
MAX_TOKENS = 16000

BRANCH_COLOURS = ["purple", "teal", "blue", "pink", "green", "yellow", "rose"]

SYSTEM_PROMPT = """\
You map a spoken conversation into a topic outline for 1DMD, an app that shows people \
where their conversation has been: what they talked about, what they went deeper into, \
and what they came back to.

The transcript comes from on-device speech recognition. It has no speaker labels and \
contains misheard words, filler ("um", "like"), and run-on sentences. Read past those: \
when a word is clearly misheard, use the word the speaker meant, and never turn a \
transcription error into a topic or a bullet.

Build the outline as a list of nodes in the order the conversation reached them.

A node is either:
- a top-level topic: a genuinely separate subject. Set parent to "".
- a sub-topic: the speakers went deeper into one part of an earlier node. Set parent to \
that node's id.

Rules:
- Prefer fewer, broader topics. Start a new top-level topic only when the subject \
clearly changes, not for every passing remark. A cluttered map is worse than a sparse \
one. A short conversation usually has 1 to 4 topics.
- Go deeper (make a sub-topic) only when the speakers spent real time on one part of a \
node. Brief mentions stay as bullets.
- When the conversation returns to a topic it already covered, add a new top-level node \
for the return and set continues to the id of the original topic. Otherwise set \
continues to "".
- Titles: 1 to 4 words, in the speakers' own terms. Sentence case.
- Bullets: 1 to 5 per node, each 1 to 5 words, naming the points raised in that node. \
Set talked_about to true when the point was discussed, false when it was only mentioned \
in passing (an open thread). When a node has a sub-topic, include a bullet whose text \
matches the sub-topic's title.
- Description: 1 to 2 plain sentences saying what was said about this node, from the \
transcript only. Do not add facts, opinions, or advice that were not in the conversation.
- ids: short lowercase slugs, unique across the outline (for example "dune", \
"dune-actors", "dune-2" for a return).
- current: the id of the node the conversation is on at the very end.

If the transcript has no real content (silence, only filler, one or two words), return \
a single topic titled "Short conversation" with no bullets, a description saying there \
was not enough to map, and current set to its id.\
"""


class OutlineBullet(BaseModel):
    text: str
    talked_about: bool


class OutlineNode(BaseModel):
    id: str
    title: str
    parent: str
    continues: str
    description: str
    bullets: list[OutlineBullet]


class Outline(BaseModel):
    nodes: list[OutlineNode]
    current: str


def _strict_schema(schema: Any) -> Any:
    """Pydantic's JSON schema with every object closed, as structured outputs requires."""
    if isinstance(schema, dict):
        schema = {key: _strict_schema(value) for key, value in schema.items()}
        if schema.get("type") == "object":
            schema["additionalProperties"] = False
            schema["required"] = list(schema.get("properties", {}))
        return schema
    if isinstance(schema, list):
        return [_strict_schema(value) for value in schema]
    return schema


OUTLINE_SCHEMA = _strict_schema(Outline.model_json_schema())


class TopicMapError(Exception):
    """The transcript could not be turned into a map; the job should fail."""


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


def outline_transcript(transcript: str, client: anthropic.Anthropic) -> Outline:
    """Ask Claude for the outline of one transcript."""
    if not transcript.strip():
        raise TopicMapError("The transcript is empty.")

    outline = structured_call(
        client, system=SYSTEM_PROMPT,
        content=f"<transcript>\n{transcript}\n</transcript>",
        schema=OUTLINE_SCHEMA, model_cls=Outline, max_tokens=MAX_TOKENS,
        # effort: Haiku 5.5's default, pinned so it can't drift. "low" is faster and
        # cheaper; try it against real transcripts before switching.
        effort="medium",
    )
    if not outline.nodes:
        raise TopicMapError("Claude returned no topics.")
    return outline


def layout(outline: Outline) -> dict[str, JsonValue]:
    """Place the outline on the map grid, using the same rules as the app.

    - Each top-level topic starts a new line. Going deeper moves one column right.
    - A node's first sub-topic stays on its line; later ones start new lines below.
    - The bullet that led to a sub-topic gets that branch's colour.
    - Returning to a topic gets a "(cont.)" node linked back to the original.

    Nodes that would break the map (blank title, duplicate id, unknown parent) are skipped.
    """
    nodes: list[dict[str, JsonValue]] = []
    edges: list[dict[str, JsonValue]] = []
    index: dict[str, int] = {}
    child_count: dict[str, int] = {}
    next_line = 0
    next_branch = 0
    previous_id: str | None = None

    for item in outline.nodes:
        node_id = item.id.strip()
        title = item.title.strip()
        if not node_id or not title or node_id in index:
            continue

        seen: set[str] = set()
        bullets: list[dict[str, JsonValue]] = []
        for bullet in item.bullets:
            text = bullet.text.strip()
            if text and text.lower() not in seen:
                seen.add(text.lower())
                bullets.append({"text": text, "talkedAbout": bullet.talked_about})

        parent_id = item.parent.strip()
        if parent_id and parent_id != node_id and parent_id in index:
            parent = nodes[index[parent_id]]
            first_child = child_count.get(parent_id, 0) == 0
            line = parent["line"] if first_child else next_line
            child_count[parent_id] = child_count.get(parent_id, 0) + 1
            next_line = max(next_line, line + 1)

            branch = BRANCH_COLOURS[next_branch % len(BRANCH_COLOURS)]
            next_branch += 1
            parent_bullets = parent["bullets"]
            match = next((b for b in parent_bullets if b["text"].lower() == title.lower()), None)
            if match is not None:
                match["branch"] = branch
            else:
                parent_bullets.append({"text": title, "talkedAbout": True, "branch": branch})

            index[node_id] = len(nodes)
            nodes.append({
                "id": node_id, "title": title, "isTopic": False,
                "line": line, "column": parent["column"] + 1, "branch": branch,
                "bullets": bullets, "description": item.description.strip(),
            })
            edges.append({"from": parent_id, "to": node_id, "kind": "deeper"})
        else:
            line = next_line
            next_line += 1
            original = item.continues.strip()
            original = original if original in index and original != node_id else None

            index[node_id] = len(nodes)
            nodes.append({
                "id": node_id, "title": title, "isTopic": True,
                "line": line, "column": 0,
                "bullets": bullets, "description": item.description.strip(),
            })
            if previous_id is not None and previous_id != original:
                edges.append({"from": previous_id, "to": node_id, "kind": "newTopic"})
            if original is not None:
                edges.append({"from": original, "to": node_id, "kind": "continued"})
        previous_id = node_id

    if not nodes:
        raise TopicMapError("The outline had no usable topics.")

    current = outline.current.strip()
    return {
        "currentID": current if current in index else previous_id,
        "nodes": nodes,
        "edges": edges,
    }


def map_transcript(transcript: str, client: anthropic.Anthropic) -> dict[str, JsonValue]:
    """Transcript in, the app's positioned map out."""
    return layout(outline_transcript(transcript, client))
