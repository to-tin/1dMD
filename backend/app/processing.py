from collections.abc import Callable
from functools import cache
import json
import logging
import os
from pathlib import Path

import anthropic
from pydantic import JsonValue

from .live import live_update
from .models import LiveReply, LiveRequest, TranscriptRequest
from .topic_map import layout, map_transcript


logger = logging.getLogger(__name__)

TranscriptProcessor = Callable[[TranscriptRequest], dict[str, JsonValue]]
LiveProcessor = Callable[[LiveRequest], LiveReply]
MOCK_RESPONSE_PATH = Path(__file__).resolve().parent / "mock_data" / "mock_response_body.json"


@cache
def _client() -> anthropic.Anthropic:
    # Reads ANTHROPIC_API_KEY from the environment. One client is reused across jobs.
    return anthropic.Anthropic()


def process_transcript(payload: TranscriptRequest) -> dict[str, JsonValue]:
    """Map the transcript with Claude, or return the mock map when no API key is set.

    Return a JSON-compatible object; raise an exception to fail the job.
    """
    if not os.environ.get("ANTHROPIC_API_KEY"):
        logger.warning("ANTHROPIC_API_KEY is not set; returning the mock map.")
        return mock_response()
    return map_transcript(payload.transcript, _client())


def mock_response() -> dict[str, JsonValue]:
    with MOCK_RESPONSE_PATH.open(encoding="utf-8") as mock_file:
        return json.load(mock_file)


def process_live(request: LiveRequest) -> LiveReply:
    """Claude when a key is set; otherwise hand the outline back unchanged."""
    if not os.environ.get("ANTHROPIC_API_KEY"):
        logger.warning("ANTHROPIC_API_KEY is not set; /live returns the map unchanged.")
        return LiveReply(outline=request.outline,
                         map=layout(request.outline) if request.outline else None, move="none")
    return live_update(request, _client())
