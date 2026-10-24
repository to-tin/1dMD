"""Replay a transcript through live mapping, the way the app does, to tune it.

    cd backend
    .venv/bin/python scripts/replay_live.py path/to/transcript.txt [--words 20] \
        [--effort low|medium] [--model ID] [--json out.json]

This calls the real Claude API, so it spends credits and needs ANTHROPIC_API_KEY.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path
from typing import TextIO

if __package__ in (None, ""):  # run as a file: make `app` importable
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import anthropic

from app.live import live_update
from app.models import LiveRequest
from app.topic_map import MODEL, Outline


class _CountingMessages:
    def __init__(self, messages, totals: Counter):
        self._messages, self._totals = messages, totals

    def create(self, *args, **kwargs):
        response = self._messages.create(*args, **kwargs)
        self._totals["input_tokens"] += response.usage.input_tokens
        self._totals["output_tokens"] += response.usage.output_tokens
        return response


class _CountingClient:
    """Wraps a client to add up token usage; everything else passes through."""

    def __init__(self, client, totals: Counter):
        self.messages = _CountingMessages(client.messages, totals)


def batches_of(text: str, size: int) -> list[str]:
    words = text.split()
    return [" ".join(words[i:i + size]) for i in range(0, len(words), size)]


def format_tree(outline: Outline) -> str:
    """The outline as an indented tree: title, description, bullets, NOW marker."""
    children: dict[str, list] = {}
    for n in outline.nodes:
        children.setdefault(n.parent, []).append(n)
    known = {n.id for n in outline.nodes}
    roots = [n for n in outline.nodes if not n.parent or n.parent not in known]
    lines: list[str] = []

    def walk(node, depth: int, seen: frozenset) -> None:
        pad = "  " * depth
        cont = f" (returns to {node.continues})" if node.continues else ""
        now = "  <- NOW" if node.id == outline.current else ""
        lines.append(f"{pad}- {node.title}{cont}{now}")
        if node.description:
            lines.append(f"{pad}    {node.description}")
        for b in node.bullets:
            lines.append(f"{pad}    {'x' if b.talked_about else 'o'} {b.text}")
        for child in children.get(node.id, []):
            if child.id not in seen:
                walk(child, depth + 1, seen | {child.id})

    for root in roots:
        walk(root, 0, frozenset({root.id}))
    return "\n".join(lines)


def run(transcript: str, client, *, words: int = 20, effort: str = "low", model: str = MODEL,
        json_path: str | None = None, out: TextIO | None = None) -> dict:
    """Send the transcript batch by batch, carrying the outline forward like the app."""
    out = out or sys.stdout
    tokens: Counter = Counter()
    counted = _CountingClient(client, tokens)
    outline: Outline | None = None
    previous = ""
    steps = []
    moves: Counter = Counter()
    failure: str | None = None
    started = time.perf_counter()
    for number, batch in enumerate(batches_of(transcript, words), start=1):
        t0 = time.perf_counter()
        try:
            reply = live_update(LiveRequest(outline=outline, previous_words=previous, words=batch),
                                counted, model=model, effort=effort)
        except Exception as error:  # stop here, but keep what the earlier batches produced
            failure = f"batch {number} failed: {type(error).__name__}: {error}".replace("\n", " ")
            print(failure, file=sys.stderr)
            break
        seconds = time.perf_counter() - t0
        outline, previous = reply.outline, batch
        moves[reply.move] += 1
        now = next((n.title for n in outline.nodes if n.id == outline.current), "-")
        print(f"batch {number:>3}  {reply.move:<7} NOW: {now}  ({len(outline.nodes)} nodes, "
              f"{seconds:.1f}s)", file=out)
        steps.append({"batch": number, "words": batch, "move": reply.move, "seconds": round(seconds, 2),
                      "outline": outline.model_dump()})
    total = time.perf_counter() - started
    nodes = len(outline.nodes) if outline else 0
    totals = {"batches": len(steps), "moves": dict(moves), "topics_created": nodes,
              "seconds": round(total, 2), "input_tokens": tokens["input_tokens"],
              "output_tokens": tokens["output_tokens"]}
    if outline:
        print("\nFinal outline:", file=out)
        print(format_tree(outline), file=out)
    kinds = ", ".join(f"{k} {v}" for k, v in moves.items()) or "none"
    print(f"\nMoves: {kinds}\nTopics created: {nodes}\nTotal time: {total:.1f}s\n"
          f"Tokens: {tokens['input_tokens']} in / {tokens['output_tokens']} out", file=out)
    result = {"steps": steps, "totals": totals}
    if failure:
        result["error"] = failure
    if json_path:
        Path(json_path).write_text(json.dumps(result, indent=2))
    return result


def main(argv: list[str] | None = None, client=None) -> int:
    parser = argparse.ArgumentParser(description="Replay a transcript through live mapping.")
    parser.add_argument("transcript", help="text file of the conversation")
    parser.add_argument("--words", type=int, default=20, help="words per batch (default 20)")
    parser.add_argument("--effort", choices=["low", "medium"], default="low")
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--json", dest="json_path", help="save every step and the totals here")
    args = parser.parse_args(argv)
    if args.words < 1:
        parser.error("--words must be at least 1")
    if client is None:
        if not os.environ.get("ANTHROPIC_API_KEY"):
            print("ANTHROPIC_API_KEY is not set. Export it first; replaying calls the real "
                  "API and spends credits.", file=sys.stderr)
            return 1
        client = anthropic.Anthropic()
    try:
        transcript = Path(args.transcript).read_text(encoding="utf-8")
    except OSError as error:
        print(f"Cannot read {args.transcript}: {error.strerror}", file=sys.stderr)
        return 1
    except UnicodeDecodeError:
        print(f"Cannot read {args.transcript}: it is not UTF-8 text", file=sys.stderr)
        return 1
    result = run(transcript, client, words=args.words, effort=args.effort, model=args.model,
                 json_path=args.json_path)
    return 1 if "error" in result else 0


if __name__ == "__main__":
    sys.exit(main())
