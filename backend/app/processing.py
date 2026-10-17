from collections.abc import Callable
import json
from pathlib import Path

from pydantic import JsonValue

from .models import TranscriptRequest


TranscriptProcessor = Callable[[TranscriptRequest], dict[str, JsonValue]]
MOCK_RESPONSE_PATH = Path(__file__).resolve().parent / "mock_data" / "mock_response_body.json"


def process_transcript(payload: TranscriptRequest) -> dict[str, JsonValue]:
    """Return the mock response until transcript analysis is ready.

    Analyze payload.transcript here when real processing is added.
    Return a JSON-compatible object; raise an exception to fail the job.
    """
    with MOCK_RESPONSE_PATH.open(encoding="utf-8") as mock_file:
        return json.load(mock_file)
