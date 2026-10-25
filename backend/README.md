# Transcript backend

A local FastAPI server that accepts a JSON transcript object, returns a job ID, and lets
clients poll for JSON. With an Anthropic API key set, each transcript is mapped by
Claude Haiku 5.5 (see [AI mapping](#ai-mapping)). Without a key, the completed job's
`result` is the fixed object in
[`app/mock_data/mock_response_body.json`](app/mock_data/mock_response_body.json).

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
After a restart, old job IDs return `404` and clients must submit again. This local
prototype has no authentication, persistent queue, or public deployment setup.

## Run the iOS app

1. Start the server with `./1dmd start`.
2. Open `ios/OneDMD.xcodeproj` in Xcode 26 or newer and run the **OneDMD** scheme
   on an iOS 26 simulator.
3. Tap **+ → Paste transcript**, paste a conversation, and tap **Done**.
4. Or tap **+ → Import audio** to select a file. The app transcribes it on-device
   with Apple SpeechAnalyzer before sending the transcript. Allow speech recognition
   when prompted; the speech model may require a one-time download. File transcription
   requires a supported language and an audio format Apple can decode.

Both paths send `POST /jobs` with `Content-Type: application/json` and a body of
`{"transcript": "the conversation text"}`, poll the returned status URL, and draw
the completed graph. No audio bytes are sent to Python. Without an API key, the mock
result highlights **Actors**. Debug builds print HTTP status codes and complete JSON
response bodies to the Xcode console; request transcripts are not logged.

The simulator reaches the Mac at `http://127.0.0.1:8000`; Info.plist permits HTTP
specifically to that address. A real iPhone's loopback address refers to the phone,
so a real iPhone needs the steps below.

To run on a real iPhone (needed for live recording, since the simulator mic is
unreliable): start the server with `./1dmd start --host 0.0.0.0`, run the **OneDMD**
scheme on the phone from Xcode, allow the microphone, speech recognition and Local
Network prompts, and set Past chats → Server to `http://<the Mac's local IP>:8000`.
Details and the no-authentication warning are in
[Testing on a real iPhone](#testing-on-a-real-iphone). Then tap Start and talk; the map
updates as you speak (see [Live mapping](#live-mapping)).

Cancel stops client requests and preserves the previous map. It does not cancel a
job already accepted by Python. Submissions are never automatically retried. Polling
retries temporary failures up to five times consecutively, with bounded backoff;
the full polling phase, including retries and in-flight requests, has a ten-minute
deadline. Submit again after an error to start a new job. Local copied audio is removed
when transcription and mapping finish or are canceled.

For explicit offline UI testing, add `-usePlaceholderBackend YES` to the Xcode Run
arguments. Optional arguments `-mapScenario failed`, `neverFinishes`, `networkBlip`,
or `badReply` select stand-in behavior; `-mapMaxWait 15` shortens the deadline.
The flag also drives live recording; of the scenarios only `-mapScenario failed` affects
live. Warning: continuing a real saved chat in placeholder mode replaces its map with the
sample and saves it when you tap Done.
Without the explicit placeholder flag, transcripts always use the Python server.

The app never holds an Anthropic API key; all mapping goes through Python.

## AI mapping

Start the server with a key in its environment:

```sh
export ANTHROPIC_API_KEY=sk-ant-...   # from console.anthropic.com → API keys
./1dmd start
```

Keep the key out of the repository and out of the app. Without `ANTHROPIC_API_KEY`
the server logs a warning and returns the mock map, so the app still works offline.

[`app/topic_map.py`](app/topic_map.py) does the work in two steps:

1. **Outline (Claude).** One `claude-haiku-5-5` call with `SYSTEM_PROMPT` and the
   transcript. Structured outputs force the reply into `Outline`: nodes in the order
   they came up, each with `title`, `parent` (what it went deeper into), `continues`
   (an earlier topic it returns to), `bullets`, and a 1–2 sentence `description`.
   The system prompt is cached, so repeat jobs pay about a tenth for it.
2. **Layout (Python).** `layout()` turns the outline into the positioned graph below:
   lines, columns, branch colours, and edges, with the same rules as the app's own
   mapper. The model never produces positions, so the graph is always valid; nodes
   with a blank title, a duplicate id, or an unknown parent are dropped or promoted.

A refusal, a cut-off reply, an invalid outline, or an API error fails the job, and the
reason is logged. The SDK retries rate limits and server errors twice. Each job logs its
token use. Cost is roughly $0.003 per hour of conversation.

Tune map quality in `SYSTEM_PROMPT`: it biases toward fewer topics, because a map full
of near-duplicate topics is the main way this goes wrong.

## Live mapping

`POST /live` updates the map while people talk. It is synchronous and stateless: the app
sends the outline it holds plus the newest words, and gets the updated outline and map back
(target 1–3 s).

```json
{"outline": {"nodes": [], "current": "dune"}, "previous_words": "…", "words": "…"}
```

`outline` is `null` on a chat's first call, and that call always creates a topic (`new`). The reply is
`{"outline": …, "map": …, "move": "stay|deeper|new|back|none"}`. Claude picks one move;
`app/live.py::apply_move()` applies it in Python, and a move it cannot use (a blank label
or an unknown `back_to`) becomes `stay`.
A request over the limits (20,000 characters of words, 500 nodes, 50 bullets per node)
returns `422`, and so does a Claude refusal or a cut-off or unusable reply. Upstream
trouble (Anthropic unreachable, timeouts, rate limits, overload) returns `502`. The app
retries 502/503/429 and skips a 422 batch; either way it keeps its map. Without an API key the outline comes back
unchanged (`move: "none"`).

### Testing on a real iPhone

Run `./1dmd start --host 0.0.0.0` so the phone can reach the Mac over Wi-Fi, and set the
app's server address (Past chats → Server) to `http://<the Mac's local IP>:8000`. There is
no authentication: anyone on the same network can call the server and spend the key.

## Submit and poll

Check that the server is running:

```sh
curl http://127.0.0.1:8000/health
```

Submit a transcript object:

```sh
curl -i http://127.0.0.1:8000/jobs \
  -H 'Content-Type: application/json' \
  -d '{"transcript":"We discussed Dune, its actors, and the soundtrack."}'
```

The server accepts the transcript and returns HTTP `202`:

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
and `error: "Transcript processing failed."`; details are logged on the server.
Each accepted submission creates a new job, even if the same transcript was sent before.
Without an API key, the mock file is read for each job, so edits apply to subsequent jobs. Results
already stored for completed jobs remain unchanged.

## Input and errors

- `POST /jobs` requires a JSON object with a string `transcript` field. Text,
  including whitespace, line breaks, and Unicode, is passed unchanged to the processor.
- Missing or non-string `transcript`, malformed JSON, and multipart uploads return
  `422`; unknown jobs return `404`. Empty strings are accepted; with an API key, an
  empty transcript fails its job without calling Claude.
- The backend no longer receives or stores audio files.
- The app retains a 25 MiB limit for local audio imports and accepts the extensions
  `.wav`, `.mp3`, `.m4a`, `.aac`, `.flac`, `.ogg`, and `.webm`. Actual decoding depends
  on Apple audio support. Files with no recognized speech report an error locally.

## The processor

`process_transcript(payload)` in `app/processing.py` picks Claude or the mock. It receives a
`TranscriptRequest` object; read `payload.transcript` to analyze the conversation.
It runs in a background worker thread after the acceptance response is sent.
Return a JSON-compatible dictionary or raise an exception to mark the job failed.
Keep the endpoint and polling contract as you add real processing.

## Tuning live mapping

`scripts/replay_live.py` replays a transcript through the same `live_update()` the server
uses, in batches of words, carrying the outline forward exactly like the app does. It lets
you tune `LIVE_PROMPT`, batch size and effort without a phone.

```sh
cd backend
export ANTHROPIC_API_KEY=...
.venv/bin/python scripts/replay_live.py scripts/sample_transcripts/trip_tangent_return.txt \
  --words 20 --effort low --json /tmp/replay.json
```

Options: `--words N` (batch size, default 20), `--effort low|medium`, `--model ID`, and
`--json FILE` to save every step (batch words, move, outline) plus the totals. Two made-up
conversations are in `scripts/sample_transcripts/`; the trip one has a tangent and a return.

It prints one line per batch, then the final outline as a tree and the totals. Look at:
topics created (too many means jittery topics), wrong moves (a tangent that stayed, or a
passing remark that opened a topic), and seconds per batch (live updates should feel fast).

This calls the real API, so it spends credits. Without `ANTHROPIC_API_KEY` it refuses to run.

## Tests

Install test dependencies once after the CLI has created the environment:

```sh
backend/.venv/bin/python -m pip install -r backend/requirements-dev.txt
cd backend
.venv/bin/python -m pytest
```

Tests cover JSON validation, exact transcript delivery, failed processing, isolated jobs, CLI
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

They cover transcript JSON encoding, wire response decoding, the actual Python
graph fixture, debug placeholder layout, terminal errors, retries, deadlines,
and cancellation. Most Swift tests stub transport. The optional live-server test
submits a transcript to Python from the simulator; start `./1dmd start` before
testing to include it (otherwise it is skipped). Check imported-audio transcription
on a device with speech recognition support and an installed speech model.
