# 1DMD

## What this is
1DMD is an iPhone app that shows a live map of an in-person conversation. The phone sits on the table, listens, and builds a topic outline as people talk, so you can always see where you are, how you got there, and what the main point was.

## Why
Conversations drift into rabbit holes. People lose track of why they started a topic, forget to finish explaining things, and lose the main point. 1DMD makes the shape of the conversation visible.

## How it works
The phone listens and sends only text to a small server on your Mac. The server asks Claude for one small decision, and the phone redraws the map.

1. **Words** (`AudioTranscriber.swift`): the iPhone mic plus Apple `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26+), on-device. It gives draft words instantly (`draftText`) and final words when a phrase ends (`finalText`). Don't rewrite this file.
2. **Batching** (`LiveMapper.swift`): collects finished words and, after about 20 words or a 3 second pause, sends one `POST /live` request. Only ONE request at a time; words that arrive meanwhile ride along on the next one. If the server is offline it keeps the words and retries. On Stop, `finish()` flushes what is left but gives up after about 5 seconds.
3. **Server** (`backend/app/`): `live.py` asks Claude (`claude-haiku-5-5`) for ONE move per batch, as JSON:
   - `stay`: same topic (the default, and the most common answer)
   - `deeper`: a sub-topic of the current one (needs a label)
   - `new`: a new top-level topic (needs a label)
   - `back`: return to an earlier topic (needs `back_to`)
   Python applies the move (`apply_move()`); a move it can't use becomes `stay`. The reply is the updated outline plus the positioned map. The API key lives only on the server.
4. **Screen** (`ContentView.swift`, `NodeMapView.swift`): draws the map (`NodeMapData.swift`) and the outline (`MapOutline.swift`).

### Two paths
- **Fast path:** draft words go straight to the screen, so the app feels instant.
- **Slow path:** finished words are batched and sent to `/live`. The phone keeps showing its current map until a reply arrives; a failed request keeps the map as it was.
- **Paste / import** (`ServerBackend.swift`, `MapService.swift`): a whole transcript goes to `POST /jobs`, and the app polls `/jobs/{id}`. `topic_map.py` outlines the whole transcript in one Claude call, then `layout()` positions it.

## Key design decisions (keep these)
- The AI makes **one small decision per call**. It never regenerates the whole map. This keeps calls fast and the map stable.
- The prompt should bias toward `stay` so the map doesn't fill up with junk topics. Topic jitter is the #1 risk.
- The map summary sent to the AI stays short (ids + labels + current marker + bullets).
- Claude never produces positions; Python lays out the map, so it is always valid.
- Transcription stays on-device. Only text goes to the cloud.
- Never ship the API key in the app. It lives only on the server (`ANTHROPIC_API_KEY`).

## Project files

- `ios/OneDMD/`: iOS app source files and assets.
- `ios/OneDMD.xcodeproj/`: Xcode project; open this to work on the app.
- `backend/`: the Python server (FastAPI). `./1dmd start` runs it. See `backend/README.md`.

App files (under `ios/OneDMD/`):

| File | Job |
| --- | --- |
| `OneDMDApp.swift` | App entry point |
| `ContentView.swift` | The main screen: map, outline, transcript, Start/Stop |
| `PastChatsView.swift` | Saved chats, and the server address setting (Past chats, then Server) |
| `PasteTranscriptView.swift` | Paste a transcript to map it |
| `AudioTranscriber.swift` | Mic + SpeechAnalyzer, audio format conversion |
| `FileTranscriber.swift` | Transcribes an imported audio file on-device |
| `LiveMapper.swift` | Batches finished words, one `/live` request at a time, offline-safe |
| `ServerBackend.swift` | Talks to the server: `/jobs` (paste/import) and `/live` (recording) |
| `MapService.swift`, `TranscriptMapper.swift` | The mapping interface the screens use |
| `ServerMap.swift` | Decoding of the server's replies |
| `ChatStore.swift` | Saves chats as JSON files on the phone (map, outline, transcript) |
| `MapOutline.swift`, `NodeMapData.swift` | Outline and map data |
| `NodeMapView.swift` | Draws the map |
| `WaveformView.swift`, `AudioLevelMonitor.swift` | The mic level display |
| `PlaceholderBackend.swift` | Offline stand-in for UI testing (`-usePlaceholderBackend YES`) |
| `Secrets.swift` | Empty placeholder; the app holds no API key |

Server files (under `backend/app/`):

| File | Job |
| --- | --- |
| `api.py` | Routes: `/health`, `/jobs`, `/jobs/{id}`, `/live` |
| `live.py` | `LIVE_PROMPT`, one move per batch, `apply_move()` |
| `topic_map.py` | `SYSTEM_PROMPT`, whole-transcript outline, `layout()` |
| `processing.py` | Uses Claude when `ANTHROPIC_API_KEY` is set, else a fixed mock map |
| `jobs.py`, `models.py`, `main.py` | Job store, request/reply shapes, app setup |

## Tech constraints
- Swift, SwiftUI, Observation framework. Target: iOS 26.0+.
- Must run on a real iPhone (the simulator mic is unreliable). The phone reaches the Mac over Wi-Fi; see "Testing on a real iPhone" in `backend/README.md`.
- Info.plist needs `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` and `NSLocalNetworkUsageDescription`.
- No third-party dependencies in the app.
- The server has no authentication yet. Use it only on a network you trust.

## v1 scope
In v1: Start/Stop, the live map and outline with the current topic highlighted, the live transcript, saved chats on the phone (continue a chat and it grows), and paste/import of a transcript.

NOT in v1 (don't build yet): speaker identification, accounts or sharing, an on-device LLM, a public server.

## Tunable knobs
- `wordsPerUpdate` and `pause` in `LiveMapper.swift` (20 words, 3 seconds): lower means faster updates but jumpier topics.
- `LIVE_PROMPT` in `backend/app/live.py`: this is where live topic quality is won or lost.
- The `effort` setting in `live.py` (`"low"` now, for speed): measure against `"medium"` before changing.
- `SYSTEM_PROMPT` in `backend/app/topic_map.py`: the same, for pasted and imported transcripts.

## Later / open questions
- Put the server somewhere safe, with sign-in, before anyone else uses it.
- Maybe try Apple Foundation Models (on-device) instead of Haiku, to make it free and offline.
- Tune on real conversations: how fast the map updates, and how often topics jitter.

## Working style
- Keep things simple. The owner wants plain-language explanations.
- Prefer small, working steps over big rewrites.
