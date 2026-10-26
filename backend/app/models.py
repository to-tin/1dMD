from typing import Literal

from pydantic import BaseModel, Field, JsonValue, field_validator

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


MAX_WORDS_CHARS = 20_000
MAX_OUTLINE_NODES = 500
MAX_NODE_BULLETS = 50


class LiveRequest(BaseModel):
    outline: Outline | None = None
    previous_words: str = Field(default="", max_length=MAX_WORDS_CHARS)
    words: str = Field(max_length=MAX_WORDS_CHARS)

    @field_validator("outline")
    @classmethod
    def _outline_not_huge(cls, outline: Outline | None) -> Outline | None:
        if outline is not None:
            if len(outline.nodes) > MAX_OUTLINE_NODES:
                raise ValueError(f"outline has more than {MAX_OUTLINE_NODES} nodes")
            if any(len(n.bullets) > MAX_NODE_BULLETS for n in outline.nodes):
                raise ValueError(f"a node has more than {MAX_NODE_BULLETS} bullets")
        return outline


class LiveReply(BaseModel):
    outline: Outline | None
    map: dict[str, JsonValue] | None
    move: str
