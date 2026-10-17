# App ↔ local Python server

Start the server from the repository root:

```sh
./1dmd start
```

The CLI sets up Python automatically. The simulator app connects to
`http://127.0.0.1:8000`. Tap **+ → Upload audio** to choose a file; the app displays
the returned topic map and logs full JSON responses to the Xcode debug console.

## Actual API contract

| Request | Response |
| --- | --- |
| `GET /health` | `200 {"status":"ok"}` |
| `POST /jobs`, multipart field `audio` | `202 {"job_id":"…","status":"queued","status_url":"/jobs/…"}` |
| `GET /jobs/{job_id}` | `200 {"job_id":"…","status":"queued/processing/completed/failed","result":null,"error":null}` |

For `completed`, `result` contains `currentID`, positioned `nodes`, and `edges`.
Nodes contain `id`, `title`, `isTopic`, `line`, `column`, `bullets`, and optional
`branch`. Bullets contain `text` and optional `branch` /
`talkedAbout`. Edges contain `from`, `to`, and `kind`. Supported edge kinds
are `deeper`, `newTopic`, and `continued`; branch colors are `purple`, `teal`,
`blue`, `pink`, `green`, `yellow`, and `rose`.
Graphs contain no timestamps. Edges are ordered by conversation progression; a
`continued` edge marks its destination as a continuation of an earlier topic.

The app decodes this graph directly into its existing map view. It does not
recalculate the server's layout through the pasted-transcript outline format.
For `failed`, `result` is null and `error` describes the failure. Unknown job IDs
return `404`, including jobs lost after restarting the server.

The processor currently returns fixed mock JSON; it does not analyze the audio.
See the [complete result fixture](backend/app/mock_data/mock_response_body.json)
and [backend documentation](backend/README.md) for setup, simulator instructions,
file limits, errors, debug options, and tests.
