from fastapi import FastAPI

from .api import router
from .jobs import JobStore
from .processing import TranscriptProcessor, process_transcript


def create_app(
    *,
    processor: TranscriptProcessor = process_transcript,
) -> FastAPI:
    app = FastAPI(title="1DMD transcript backend")
    app.state.jobs = JobStore()
    app.state.processor = processor
    app.include_router(router)
    return app


app = create_app()
