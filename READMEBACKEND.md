# App ↔ local Python server

Start the server from the repository root:

```sh
./1dmd start
```

The CLI sets up Python automatically. The simulator app connects to
`http://127.0.0.1:8000`. Tap **+ → Paste transcript**, or **+ → Import audio** to transcribe a file locally; the app displays
the returned topic map and logs full JSON responses to the Xcode debug console.

## Actual API contract

| Request | Response |
| --- | --- |
| `GET /health` | `200 {"status":"ok"}` |
| `POST /jobs`, JSON `{"transcript":"…"}` | `202 {"job_id":"…","status":"queued","status_url":"/jobs/…"}` |
| `GET /jobs/{job_id}` | `200 {"job_id":"…","status":"queued/processing/completed/failed","result":null,"error":null}` |

For `completed`, `result` contains `currentID`, positioned `nodes`, and `edges`.
Nodes contain `id`, `title`, `isTopic`, `line`, `column`, `bullets`, and optional
`branch` and `description` (1–2 sentences about that part of the conversation, shown
when a node is tapped; the mock map has none). Bullets contain `text` and optional `branch` /
`talkedAbout`. Edges contain `from`, `to`, and `kind`. Supported edge kinds
are `deeper`, `newTopic`, and `continued`; branch colors are `purple`, `teal`,
`blue`, `pink`, `green`, `yellow`, and `rose`.
Graphs contain no timestamps. Edges are ordered by conversation progression; a
`continued` edge marks its destination as a continuation of an earlier topic.

The app decodes this graph directly into its existing map view. Both pasted and locally transcribed text use this same response format.
For `failed`, `result` is null and `error` describes the failure. Unknown job IDs
return `404`, including jobs lost after restarting the server.

With `ANTHROPIC_API_KEY` set, the processor maps each transcript with Claude Haiku 5.5;
without it, it returns fixed mock JSON. See the [complete result fixture](backend/app/mock_data/mock_response_body.json)
and [backend documentation](backend/README.md) for setup, simulator instructions,
input validation, errors, debug options, and tests.

The backend processor is `process_transcript(payload)` in `backend/app/processing.py`;
`payload.transcript` contains the submitted text. The app no longer calls Anthropic
directly, and Python no longer accepts multipart audio uploads.
