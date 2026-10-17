from collections.abc import Callable
import json
from pathlib import Path

from pydantic import JsonValue

from .models import AudioMetadata


AudioProcessor = Callable[[Path, AudioMetadata], dict[str, JsonValue]]
MOCK_RESPONSE_PATH = Path(__file__).resolve().parent / "mock_data" / "mock_response_body.json"


def process_audio(path: Path, metadata: AudioMetadata) -> dict[str, JsonValue]:
    """Return the mock response until transcription or analysis is ready.

    The server owns the file and removes it after this function returns.
    Return a JSON-compatible object; raise an exception to fail the job.
    """
    with MOCK_RESPONSE_PATH.open(encoding="utf-8") as mock_file:
        return json.load(mock_file)
