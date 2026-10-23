import logging

from fastapi import FastAPI

from .api import router
from .jobs import JobStore
from .processing import TranscriptProcessor, process_transcript


def _show_app_logs() -> None:
    """Print this package's info lines in the server terminal.

    Uvicorn only configures its own loggers, so without a handler here Python prints
    warnings and errors from `app.*` but drops info lines such as per-job token use.
    """
    logger = logging.getLogger("app")
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter("%(levelname)s:     %(name)s: %(message)s"))
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)


def create_app(
    *,
    processor: TranscriptProcessor = process_transcript,
) -> FastAPI:
    _show_app_logs()
    app = FastAPI(title="1DMD transcript backend")
    app.state.jobs = JobStore()
    app.state.processor = processor
    app.include_router(router)
    return app


app = create_app()
