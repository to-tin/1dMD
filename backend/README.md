# Audio upload backend

A local FastAPI server that accepts an audio upload, returns a job ID, and lets
clients poll for JSON. The processor currently returns the object in
[`app/mock_data/mock_response_body.json`](app/mock_data/mock_response_body.json)
as the completed job's `result`; it does not transcribe or analyze audio.

## Setup and run

Install Python 3.11 or newer, then run this from the repository root:

```sh
./1dmd start
```

On first use the CLI creates `backend/.venv` and installs the pinned runtime
requirements. First setup needs access to the Python package index. Later starts
reuse the environment; a change to `requirements.txt` triggers installation again.
A failed installation exits with an error and is retried on the next start.
The launcher also works by absolute path from another working directory.

The server listens at `http://127.0.0.1:8000`. Interactive API documentation is at
[http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs). Stop it with **Ctrl-C**.

```sh
./1dmd --help
./1dmd start --help
./1dmd start --port 8123
./1dmd start --reload
```

`--host` defaults to `127.0.0.1`; `--port` accepts 1–65535. The iOS simulator app is
configured for port **8000**, so keep that default when testing the app.
`--reload` is opt-in. Help commands never create an environment or install packages.

The CLI runs **one worker**. Jobs and results live in this process's memory until
it exits; restarts, including automatic reloads after code edits, clear them.
After a restart, old job IDs return `404` and clients must upload again. This local
prototype has no authentication, persistent queue, or public deployment setup.

## Run the iOS app

1. Start the server with `./1dmd start`.
2. Open `ios/OneDMD.xcodeproj` in Xcode 26 or newer and run the **OneDMD** scheme
   on an iOS 26 simulator.
3. Place a supported audio file in the simulator's Files app (for example, drag a
   file into Simulator and save it to Files).
4. Tap **+ → Upload audio**, then choose that file.

The app uploads multipart field `audio`, polls the returned status URL, and draws
the completed graph in the existing map UI. The current mock result highlights
**Actors**. Debug builds print HTTP status codes and complete JSON response bodies
to the Xcode console. Audio bytes are not logged.

The simulator reaches the Mac at `http://127.0.0.1:8000`; Info.plist permits HTTP
specifically to that address. A real iPhone's loopback address refers to the phone,
so physical-device networking is outside this setup.

Cancel stops client requests and preserves the previous map. It does not cancel a
job already accepted by Python. Uploads are never automatically retried. Polling
retries temporary failures up to five times consecutively, with bounded backoff;
the full polling phase, including retries and in-flight requests, has a ten-minute
deadline. Re-select a file after an error to start a new job. Local copied audio and
multipart bodies are removed when the operation finishes or is canceled.

For explicit offline UI testing, add `-usePlaceholderBackend YES` to the Xcode Run
arguments. Optional arguments `-mapScenario failed`, `neverFinishes`, `networkBlip`,
or `badReply` select stand-in behavior; `-mapMaxWait 15` shortens the deadline.
Without the explicit placeholder flag, uploads always use the Python server.

Pasted transcripts remain a separate development feature. They can use
`ANTHROPIC_API_KEY` set in the Xcode Run scheme's environment variables in Debug
builds. An absent key produces a readable error; no `Secrets.swift` file is needed.
Audio uploads do not require an API key.

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

Install test dependencies once after the CLI has created the environment:

```sh
backend/.venv/bin/python -m pip install -r backend/requirements-dev.txt
cd backend
.venv/bin/python -m pytest
```

Tests cover uploads, validation, cleanup, failed processing, isolated jobs, CLI
bootstrap/reuse/failure, command options, arbitrary working directories, and real
HTTP startup and graceful shutdown. The HTTP tests need permission to bind local
ports; they do not need internet access.

Swift tests run from **Product → Test** in Xcode, or from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios/OneDMD.xcodeproj -scheme OneDMD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO test
```

They cover multipart bodies, wire response decoding, the actual Python graph
fixture, pasted-transcript compatibility, terminal errors, retries, deadlines,
and cancellation. Most Swift tests stub transport. The optional live-server test uploads a valid
WAV to Python from the simulator; start `./1dmd start` before testing to include
it (otherwise it is skipped). Use the simulator steps above to check the picker
and map presentation interactively.
