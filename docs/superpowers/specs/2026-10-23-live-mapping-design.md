# Live mapping: design

Status: approved by Justin and Toby, 2026-10-23. Source doc: https://claude.ai/artifact/451qRp7tgvk9V3PnHmJBF7

## TL;DR

- **Goal:** the map builds live while people talk. Today recording only replays a sample map.
- **How:** every ~20 words (or after a short pause) the phone sends the new words plus the map so far to a new fast `POST /live` endpoint. Claude makes one small move; the server updates the map and sends it back in a second or two.
- **The phone keeps the map**, not the server. A server restart or bad Wi-Fi loses nothing.
- **Reuses PR #16:** `layout()`, prompt style, API key setup. `/jobs` stays for paste and import.
- **Works on a real iPhone** over the same Wi-Fi as the Mac running the server.
- **Decisions:** send on 20 finished words or ~3 s of silence; keep the live map as-is on stop (no re-mapping); app-held state (approach A).

## How it works

1. **You talk. The phone writes down the words.**
   - On-device Apple speech recognition, unchanged. Audio never leaves the phone.
   - Only finished phrases count. Draft words still show instantly but are not sent.
2. **Every few seconds, the phone sends the new words plus the map so far.**
   - Send when ~20 new finished words have piled up, or after ~3 s of silence if fewer have.
   - One request at a time. Words spoken while one is in flight wait and ride along with the next.
   - The request carries the current outline and the new words.
3. **The AI decides one thing: same topic, deeper, new topic, or back to an old one.**
   - Claude Haiku sees a short summary only: topic ids and titles, the current topic, open threads, and the previous batch of words for context. Cost per update stays flat.
   - The prompt biases hard toward `stay`: topic jitter is the main risk.
   - Claude returns exactly one move as structured JSON.
4. **The server updates the map and sends it back.**
   - Plain Python applies the move to the outline; the model never edits the outline directly.
   - PR #16's `layout()` turns the outline into the map JSON the app already draws.
   - Synchronous reply (no jobs/polling): updated outline + map. Target 1–3 s.
5. **The map on screen changes a little.**
   - The app swaps in the new map; the NOW marker moves and new nodes fade in.
   - Replaces the sample-map replay while recording.
   - The app keeps the returned outline for the next request.
6. **Repeat until stop, then the chat is saved.**
   - Stop sends leftover words once, then saves outline, map, transcript.
   - The live map is kept as-is; nothing re-maps it after stop.
   - Continuing an old chat starts from its saved outline.

## The /live endpoint

Stateless: everything it needs is in the request.

Request `POST /live`:

```json
{
  "outline": { "nodes": [ ... ], "current": "dune" },
  "previous_words": "...the last batch, for context...",
  "words": "the new finished words since the last call"
}
```

- `outline` is `null` on the first call of a new chat. Node shape is PR #16's `Outline` (`id`, `title`, `parent`, `continues`, `description`, `bullets` of `{text, talked_about}`), plus `current`.

Response `200`:

```json
{
  "outline": { "nodes": [ ... ], "current": "dune-actors" },
  "map": { "currentID": "dune-actors", "nodes": [ ... ], "edges": [ ... ] },
  "move": "deeper"
}
```

- `map` is today's map JSON (with node `description`).
- `move` is for logging only.
- `/jobs` results also include the `outline` they built, so a pasted chat can be continued live.

## What the AI returns

| Field | Meaning |
| --- | --- |
| `move` | `stay` (default), `deeper`, `new`, or `back` |
| `label` | Title for the new node; only for `deeper` and `new` |
| `back_to` | Id of the earlier node; only for `back` |
| `add_bullets` | Points raised in the new words, for the node we end up on |
| `talked_about` | Existing bullets the new words discussed |
| `description` | Updated 1–2 sentence description of the node we end up on |

Python applies each move:

- **stay:** add bullets, update description on the current node.
- **deeper:** new node under the current one, titled `label`.
- **new:** new top-level topic, titled `label`.
- **back:** to a node in the current topic's tree → move NOW only; to an earlier topic → add a "(cont.)" node with `continues` set, matching the app's map rules.
- Anything invalid (unknown `back_to`, empty `label`, first call with no outline and `move` other than `new`) → treated as the nearest valid move (`stay`, or `new` with a fallback title on the first call). A bad answer never breaks the map.

## Real iPhone setup

- Server: `./1dmd start --host 0.0.0.0` listens on the Mac's Wi-Fi address.
- App: a server address setting (the Mac's local IP, e.g. `http://192.168.1.23:8000`), defaulting to `127.0.0.1` for the simulator.
- Info.plist: allow plain HTTP to local-network addresses; add the Local Network usage message.
- Caveat: no auth; anyone on the same Wi-Fi could call the server. Fine for home testing; hosting with auth comes later.

## When things go wrong

A failed update never changes or loses the map, and never loses words.

| What happened | What the app does |
| --- | --- |
| Wi-Fi drops / server down | Keeps the map and unsent words; retries with the next batch; shows a small "offline" note |
| Claude refuses, times out, errors | Server returns an error; same as above |
| Claude returns a bad move | Server applies `stay`; map unchanged except bullets |
| No API key | `/live` returns the outline unchanged; words show, map doesn't grow |
| Stop while a request is in flight | Waits for it (a few seconds max), sends leftovers, then saves |

## What changes where

| Where | Change |
| --- | --- |
| Server: new `app/live.py` | Live prompt, move schema, `apply_move()`, Claude call |
| Server: `app/api.py` | `POST /live` route |
| Server: `/jobs` result | Also returns `outline` |
| App: new live mapper | Batching (20 words / ~3 s pause), one request at a time, applying replies |
| App: `ContentView` | Live map replaces sample replay; stop saves outline too |
| App: saved chats | Store the outline so a chat can continue live |
| App: settings | Server address for the real iPhone |

Branch `live-map` (built on PRs #15 and #16); two PRs: server first, then app.

## Testing

- Server: `apply_move()` is pure, so every move and every bad answer gets a unit test. `/live` is tested with the real SDK against a fake network.
- App: batching and one-at-a-time sending tested with a fake server (word counts, pause timer, words mid-request, offline).
- Real use: a live conversation on an iPhone against the Mac server, checking update speed and topic jitter.

## Open (tune during build)

- Batch size and pause length (start 20 words / 3 s).
- Haiku `low` vs `medium` effort for live calls (measure speed and quality).
