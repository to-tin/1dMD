# Audio upload backend

A local FastAPI server that accepts an audio upload, returns a job ID, and lets
clients poll for JSON. The processor currently returns the object in
[`app/mock_data/mock_response_body.json`](app/mock_data/mock_response_body.json)
as the completed job's `result`; it does not transcribe or analyze audio.

## Setup and run

Use Python 3.11 or newer. From the repository root:

```sh
cd backend
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
python -m uvicorn app.main:app --reload
```

The server listens at `http://127.0.0.1:8000`. Interactive API documentation is at
[http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs).
Use `requirements.txt` if you only need to run the server without tests.

Run **one worker**. Jobs and results live in this process's memory until it exits;
restarts, including automatic reloads after code edits, clear them. After a restart,
old job IDs return `404` and clients must upload again. This local prototype has no
authentication, persistent queue, automatic retry, or public deployment setup.

## Upload and poll

Check that the server is running:

```sh
curl http://127.0.0.1:8000/health
```

Upload one file using the multipart field `audio` (replace the file path):

```sh
curl -i http://127.0.0.1:8000/jobs \
  -F 'audio=@/absolute/path/recording.m4a;type=audio/mp4'
```

The upload must finish before the server returns HTTP `202`:

```json
{
  "job_id": "<job-id>",
  "status": "queued",
  "status_url": "/jobs/<job-id>"
}
```

Poll the returned `status_url`, relative to the same server, about once per second:

```sh
curl 'http://127.0.0.1:8000/jobs/<job-id>'
```

Replace `<job-id>` with the actual ID (omit the angle brackets). The status is
`queued`, `processing`, `completed`, or `failed`. Stop polling on either terminal
state. The mock processor is quick, so the first poll may already be completed.
The example below abbreviates `nodes` and `edges`; the actual result includes the
entire object from the mock JSON file:

```json
{
  "job_id": "<job-id>",
  "status": "completed",
  "result": {
    "currentID": "actors",
    "nodes": [],
    "edges": []
  },
  "error": null
}
```

Pending jobs have `result: null` and `error: null`. Failed jobs have `result: null`
and `error: "Audio processing failed."`; details are logged on the server.
Each accepted upload creates a new job, even if the same file was uploaded before.
The mock file is read for each job, so edits apply to subsequent jobs. Results
already stored for completed jobs remain unchanged.

## File handling and errors

- Accepted extensions: `.wav`, `.mp3`, `.m4a`, `.aac`, `.flac`, `.ogg`, `.webm`
  (case-insensitive).
- Maximum file size: 25 MiB (26,214,400 bytes). Checks use actual file bytes.
- Missing `audio`: `422`; empty file: `400`; oversized file: `413`;
  unsupported extension: `415`; unknown job: `404`.
- Validation checks metadata only; an accepted file is not guaranteed to contain
  valid audio. No audio decoder or external service is used yet.
- Uploads are copied in chunks to uniquely named files in the operating system's
  temporary directory. Client filenames are never used as storage paths.
- Temporary files are removed after processing succeeds or fails and when an
  upload is rejected. Abrupt process termination can leave temporary files behind.
- FastAPI parses multipart uploads before the endpoint's size check. The 25 MiB
  limit is an accepted-file limit, not a network ingress limit.

## Replace the processor

Implement `process_audio(path, metadata)` in `app/processing.py`. It runs in a
background worker thread after the upload response is sent. Read the file during
this call and return a JSON-compatible dictionary; raise an exception to mark the
job failed. The server deletes the file when processing ends. Keep the endpoint
and polling contract as you add real processing.

## Tests

From `backend`, with the virtual environment activated:

```sh
python -m pytest
```

Tests cover uploads, validation, cleanup, failed processing, and isolated jobs.
The concurrency test starts a local HTTP server on an available port and verifies
that uploads return `202` while processing is still running.
