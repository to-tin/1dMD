# Live extras: overnight plan

Written 2026-10-24 while Justin is away (~5 h). He asked: "do a plan of what you want to do, in terms of design, engineering, etc. and keep running."

Branch: `live-extras`, built on `live-map` (PR #17). Push the branch as a backup; open no PRs and merge nothing until Justin is back.
Constraints: no calls to the real Claude API (the key lives only in Justin's terminal); don't modify `AudioTranscriber.swift`; every task gets a fresh implementer and a fresh reviewer; tests stay green; every product decision made without Justin is listed for him at the end.

## Goal

Make what PR #17 built usable and tunable: show the descriptions the AI already writes, give Justin a one-command way to tune live mapping on real transcripts, keep live calls cheap as conversations grow, and let the app demo live mapping without a server.

## Tasks

### 1. Tap a node to see its description (design + app)

The server already sends a 1–2 sentence `description` per node (PR #16), and `/live` updates it. The app throws it away.

- `MapNode` gets `description: String?` (Codable, optional so old saved chats load). `ServerMap` decodes it. `MapOutline(rebuildingFrom:)` and the live outline carry it through unchanged (the outline already has descriptions; the map node shows them).
- **Design (chosen without Justin; his earlier recommended option):** the card grows in place. Nodes with a description show a small chevron in the top-right corner (⌄ closed, ⌃ open). Tapping the card toggles it. The description appears under the bullets, separated by a hairline, in the bullet font, muted colour, wrapping to the card width. Other nodes in the column move down to make room (the layout already stacks by measured height). Tapping again collapses it. Nodes without a description don't show the chevron and don't react to taps.
- Expanded state lives in `NodeMapView` (a set of expanded node ids), resets when a different chat is shown, and survives live updates (the same id stays open).
- Layout: `MapLayout.height(_:)` must include the description's wrapped height when the node is expanded. Compute the line count from the card's text width and the font, not a guess. Unit-test the height for collapsed, expanded, and no-description nodes.
- Sample map (`NodeMapData.sample`) gets short descriptions so the feature can be seen without a server.
- Must not break: pinch and pan on the map (taps must not trigger panning), follow mode, the NOW border.

### 2. Replay script for tuning (engineering)

Justin needs to tune `LIVE_PROMPT`, batch size, and effort on real conversations. Today that needs a phone.

- `backend/scripts/replay_live.py`: reads a transcript text file, splits it into batches of N words (default 20), calls the same `live_update()` the server uses, one batch at a time, carrying the outline forward exactly like the app. Prints one line per batch: batch number, the move, the NOW topic, node count, and seconds taken. At the end prints the final outline as an indented tree with descriptions, plus totals: moves by kind, topics created, total seconds, tokens if available.
- Flags: `--words N`, `--effort low|medium` (override), `--model` (override), `--json out.json` (save every step).
- Uses `ANTHROPIC_API_KEY` from the environment and refuses to run without it, with a clear message.
- Tested with the fake-network client pattern from `tests/test_live.py` (no real calls). Documented in `backend/README.md`.
- Include `backend/scripts/sample_transcripts/` with 2 short made-up conversations (one with a tangent and a return).

### 3. Keep the live summary small (engineering)

The spec says the cost per live update stays flat, but `summarize()` lists every node and every open thread on the whole map.

- Keep listing all topic ids and titles (the AI needs them to pick `back_to`), but list sub-topics only for the NOW topic's tree, and open threads only for the NOW topic's tree plus at most 5 most recent elsewhere.
- Add a test that a 40-node outline produces a summary under a fixed character budget, and that the NOW tree's details are always present.

### 4. Live mapping without a server, for demos (app)

With `-usePlaceholderBackend YES` (the existing debug mode), recording now shows "the map isn't updating" because `/live` has no stand-in.

- `PlaceholderBackend` conforms to `LiveBackend`: each call reveals one more step of `NodeMapData.sample` (outline included), so recording in debug mode shows the map growing like the old demo replay. `MapService.liveBackend` uses it when the debug flag is on.
- Test: successive `update` calls return maps with growing node counts and a valid outline.

### 5. Small fixes from the review backlog (engineering)

From the PR #17 ledger:
- `apply_move`: a bullet re-sent with `talked_about=true` upgrades a stored `false`. Test.
- `LiveMapper`: clear the armed pause-timer handle whenever the timer fires, even if there is nothing to send, so offline retries can't stall. Test.
- `apply_move` reports `stay` (not `back`) when NOW doesn't move. Test.
- `ChatStoreTests`: check for the quoted key `"outline"`, not the word.

### 6. Final review and report

Whole-branch review on the most capable model, one fix pass, then a short report for Justin: what was built, how to try each piece, every decision made without him, and what's left.
