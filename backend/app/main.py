from pathlib import Path

from fastapi import FastAPI

from .api import router
from .jobs import JobStore
from .processing import AudioProcessor, process_audio


MAX_UPLOAD_BYTES = 25 * 1024 * 1024


def create_app(
    *,
    processor: AudioProcessor = process_audio,
    max_upload_bytes: int = MAX_UPLOAD_BYTES,
    upload_dir: Path | None = None,
) -> FastAPI:
    app = FastAPI(title="1DMD audio backend")
    app.state.jobs = JobStore()
    app.state.processor = processor
    app.state.max_upload_bytes = max_upload_bytes
    app.state.upload_dir = upload_dir
    app.include_router(router)
    return app


app = create_app()
