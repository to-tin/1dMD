from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, File, HTTPException, Request, UploadFile

from .jobs import run_job
from .models import AcceptedJob, AudioMetadata, Job


router = APIRouter()
ALLOWED_EXTENSIONS = {".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".webm"}
COPY_CHUNK_BYTES = 1024 * 1024


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@router.post("/jobs", status_code=202, response_model=AcceptedJob)
def create_job(
    request: Request,
    background_tasks: BackgroundTasks,
    audio: Annotated[UploadFile, File(description="One audio file, up to 25 MiB")],
) -> AcceptedJob:
    path: Path | None = None
    try:
        filename = audio.filename or ""
        extension = Path(filename).suffix.lower()
        if extension not in ALLOWED_EXTENSIONS:
            raise HTTPException(415, "Unsupported audio file extension.")

        size_bytes = 0
        # Own a separate file: UploadFile is scoped to the HTTP request.
        # The supplied filename is metadata only, never a storage path.
        with NamedTemporaryFile(
            prefix="1dmd-audio-", suffix=extension,
            dir=request.app.state.upload_dir, delete=False,
        ) as destination:
            path = Path(destination.name)
            while chunk := audio.file.read(COPY_CHUNK_BYTES):
                size_bytes += len(chunk)
                if size_bytes > request.app.state.max_upload_bytes:
                    raise HTTPException(413, "Audio file exceeds the upload size limit.")
                destination.write(chunk)

        if size_bytes == 0:
            raise HTTPException(400, "Audio file must not be empty.")

        metadata = AudioMetadata(
            filename=filename, content_type=audio.content_type, size_bytes=size_bytes,
        )
        job = request.app.state.jobs.create()
        background_tasks.add_task(
            run_job, request.app.state.jobs, job.job_id, path,
            metadata, request.app.state.processor,
        )
        return AcceptedJob(job_id=job.job_id, status_url=f"/jobs/{job.job_id}")
    except BaseException:
        if path is not None:
            path.unlink(missing_ok=True)
        raise
    finally:
        audio.file.close()


@router.get("/jobs/{job_id}", response_model=Job)
def get_job(job_id: str, request: Request) -> Job:
    job = request.app.state.jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "Job not found.")
    return job
