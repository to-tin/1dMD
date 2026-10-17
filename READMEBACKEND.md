# READMEBACKEND: what the app expects from the server

The iOS app is ready to talk to the server. Until the server exists, the app uses a stand-in (`ios/OneDMD/PlaceholderBackend.swift`) that follows exactly the steps below. This file is the agreement between the two sides. Nothing here is built on the server yet, and anything marked **(guess)** is open to change.

## The flow

1. The user picks an audio file in the app.
2. The app uploads it. The server replies right away with a **job id**.
3. The app keeps asking "is this job done?" every few seconds.
4. When the job is done, the reply includes the **map JSON**.
5. The app draws the map.

The server's job is everything between steps 2 and 4: transcribe the audio, work out the topics, and build the map JSON.

## Endpoints (guess)

### 1. Start a job

```
POST /jobs
Content-Type: audio/x-m4a      (or audio/mpeg, audio/wav… whatever the file is)
Body: the raw audio file bytes (not multipart)
```

Reply, sent as soon as the file is received (don't wait for processing):

```json
{ "jobId": "abc123" }
```

### 2. Check a job

```
GET /jobs/{jobId}
```

Reply:

```json
{ "status": "processing" }
```

`status` must be exactly one of:

| status | Meaning | Extra fields |
|---|---|---|
| `queued` | Received, not started | none |
| `processing` | Working on it | none |
| `done` | Finished | `result`: the map JSON (below) |
| `failed` | Couldn't do it | `error`: a short reason the user can read |

A finished job looks like this:

```json
{ "status": "done", "result": { "current": "n7", "nodes": [ … ] } }
```

A failed one:

```json
{ "status": "failed", "error": "The recording has no speech." }
```

Any other word (e.g. `"complete"`) is treated as a mistake and shown to the user as an error, so the names need to match exactly.

## The map JSON (`result`)

A full real example is in `ios/OneDMD/PlaceholderMap.json`. It was made from a 72-second test recording.

```json
{
  "current": "n3",
  "nodes": [
    { "id": "n1", "title": "Japan trip", "parent": "", "continues": "", "start": 0,
      "bullets": [ { "text": "Tokyo", "talkedAbout": true }, { "text": "Flights", "talkedAbout": false } ] },
    { "id": "n2", "title": "Tokyo", "parent": "n1", "continues": "", "start": 35, "bullets": [] },
    { "id": "n3", "title": "Japan trip", "parent": "", "continues": "n1", "start": 300, "bullets": [] }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `current` | yes | Id of the node the conversation ended on (gets the "NOW" tag). |
| `nodes` | yes | Every topic, **in the order it was talked about**. |
| `nodes[].id` | yes | Unique id, e.g. `n1`, `n2`, … |
| `nodes[].title` | yes | 1–3 words. |
| `nodes[].parent` | no | Id of the topic this goes one level deeper into. Empty or missing means a new top-level topic. |
| `nodes[].continues` | no | Id of an earlier top-level topic this returns to. The app shows it as a "cont." node. |
| `nodes[].start` | no | Seconds into the audio where this node starts. Shown as times on the arrows. |
| `nodes[].bullets` | no | 1–4 short points said about this node. |
| `bullets[].text` | yes | 1–4 words. If a child node opens from this point, use the child's exact `title`. |
| `bullets[].talkedAbout` | yes | `true` if it was actually discussed, `false` if only mentioned and left hanging. |

The app draws the layout itself (rows, columns, colours, arrows), so the server only describes the conversation.

## Errors and what the user sees

| Server does | App shows |
|---|---|
| `failed` with `error` | The `error` text |
| `GET /jobs/{id}` returns 404 | "The server lost this job. Try again." |
| `done` with no `result` | "The server said it was done but sent no map." |
| `result` with no usable nodes | "Couldn't find any topics in this recording." |
| HTTP 413 on upload | "This recording is too big for the server." |
| HTTP 429 / 502 / 503 / 504 while checking | Retries quietly (up to 5 times in a row) |
| Any other non-2xx | "The server answered with HTTP {code}." plus the start of the body |
| Reply that isn't the JSON above | "The server's reply couldn't be read:" plus the first 200 characters |

## How often the app checks

- The first check is 1 second after the upload. The gap grows to 2, 3, 4, then 5 seconds and stays there.
- On a network hiccup the gap doubles (up to 15 seconds). After 5 failures in a row the app gives up.
- After **10 minutes** the app gives up with "This is taking too long."
- If the user cancels, the app just stops checking. It doesn't tell the server. (Add `DELETE /jobs/{id}` later if needed.)
- The upload is never retried automatically, so the server won't see duplicate jobs from the app.

## Security

- **No API keys in the app.** The server holds its own keys, e.g. for transcription or Claude.
- The app sends no sign-in yet. `authorize(_:)` in `ServerBackend.swift` is the hook for adding a token later.
- **https only.** iOS blocks plain `http://`. To test a server running on a laptop, expose it over https (e.g. `ngrok http 8000`) and use that address.

## Switching the app to the real server

In `ios/OneDMD/MapService.swift`, set:

```swift
static let serverURL: URL? = URL(string: "https://your-server.example.com")
```

That's the only change. If the addresses or field names end up different from the guesses above, update `ios/OneDMD/ServerBackend.swift`, which is the only file that knows them.

## Open questions for the backend engineer

1. Are the addresses `/jobs` and `/jobs/{id}`, and the field `jobId`, OK?
2. Are the status words `queued` / `processing` / `done` / `failed` OK?
3. Should the map come inside the `done` reply (current guess) or from a separate address?
4. What's the largest file the server accepts?
5. Is a raw audio body OK, or do you need multipart?
6. Is checking every 1–5 seconds OK?

## Already tested on the app side

`ServerBackend.swift` was run against a small fake server built to this contract. It uploaded the full 613 KB test recording (`Content-Type: audio/x-m4a`), checked back three times, and drew the map from the `done` reply. A real server that follows this file should work without app changes.
