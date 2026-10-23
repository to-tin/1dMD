import logging

from fastapi import APIRouter, BackgroundTasks, HTTPException, Request

from .jobs import run_job
from .models import AcceptedJob, Job, LiveReply, LiveRequest, TranscriptRequest


logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@router.post("/jobs", status_code=202, response_model=AcceptedJob)
def create_job(
    payload: TranscriptRequest,
    request: Request,
    background_tasks: BackgroundTasks,
) -> AcceptedJob:
    job = request.app.state.jobs.create()
    background_tasks.add_task(
        run_job, request.app.state.jobs, job.job_id,
        payload, request.app.state.processor,
    )
    return AcceptedJob(job_id=job.job_id, status_url=f"/jobs/{job.job_id}")


@router.get("/jobs/{job_id}", response_model=Job)
def get_job(job_id: str, request: Request) -> Job:
    job = request.app.state.jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "Job not found.")
    return job


@router.post("/live", response_model=LiveReply)
def live(payload: LiveRequest, request: Request) -> LiveReply:
    # A plain def runs in FastAPI's thread pool, so the blocking Claude call is fine here.
    try:
        return request.app.state.live(payload)
    except Exception:
        logger.exception("Live update failed")
        raise HTTPException(502, "Live update failed.")
