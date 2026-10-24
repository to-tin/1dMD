from typing import Literal

from pydantic import BaseModel, JsonValue

from .topic_map import Outline


JobStatus = Literal["queued", "processing", "completed", "failed"]


class TranscriptRequest(BaseModel):
    transcript: str


class AcceptedJob(BaseModel):
    job_id: str
    status: Literal["queued"] = "queued"
    status_url: str


class Job(BaseModel):
    job_id: str
    status: JobStatus = "queued"
    result: dict[str, JsonValue] | None = None
    error: str | None = None


class LiveRequest(BaseModel):
    outline: Outline | None = None
    previous_words: str = ""
    words: str


class LiveReply(BaseModel):
    outline: Outline | None
    map: dict[str, JsonValue] | None
    move: str
