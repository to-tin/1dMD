import json
import logging
from threading import Lock
from uuid import uuid4

from pydantic import JsonValue, TypeAdapter

from .models import Job, JobStatus, TranscriptRequest
from .processing import TranscriptProcessor


logger = logging.getLogger(__name__)
result_adapter = TypeAdapter(dict[str, JsonValue])


class JobStore:
    """Thread-safe, process-local job records. Readers receive snapshots."""

    def __init__(self) -> None:
        self._jobs: dict[str, Job] = {}
        self._lock = Lock()

    def create(self) -> Job:
        job = Job(job_id=str(uuid4()))
        with self._lock:
            self._jobs[job.job_id] = job
        return job.model_copy(deep=True)

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return job.model_copy(deep=True) if job is not None else None

    def update(
        self,
        job_id: str,
        status: JobStatus,
        *,
        result: dict[str, JsonValue] | None = None,
        error: str | None = None,
    ) -> None:
        job = Job(job_id=job_id, status=status, result=result, error=error)
        with self._lock:
            self._jobs[job_id] = job.model_copy(deep=True)


def run_job(
    store: JobStore,
    job_id: str,
    payload: TranscriptRequest,
    processor: TranscriptProcessor,
) -> None:
    try:
        store.update(job_id, "processing")
        result = result_adapter.validate_python(processor(payload))
        # Validate serialization before reporting success to polling clients.
        json.dumps(result, allow_nan=False)
        store.update(job_id, "completed", result=result)
    except Exception:
        logger.exception("Transcript processing failed for job %s", job_id)
        store.update(job_id, "failed", error="Transcript processing failed.")
