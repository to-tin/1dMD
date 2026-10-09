# 1DMD

## This branch: `1-front-end-design`
Frontend-only work. Scope is `ContentView.swift` and any new SwiftUI views/components. Do NOT change `TopicBrain.swift`, `AudioTranscriber.swift`, `TopicMap.swift`, or `SessionController.swift` logic — read from them, don't rewrite them. If the UI needs data that isn't exposed yet, surface it via a read-only property rather than refactoring the underlying type.

## What this is
1DMD is an iPhone app that shows a live map of an in-person conversation. The phone sits on the table, listens, and builds a topic outline as people talk, so you can always see where you are, how you got there, and what the main point was.

## Why
Conversations drift into rabbit holes. People lose track of why they started a topic, forget to finish explaining things, and lose the main point. 1DMD makes the shape of the conversation visible.

## How it works
It's a loop with 3 steps:

1. **Words** (`AudioTranscriber.swift`): the iPhone mic plus Apple `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26+), running on-device. It emits draft (volatile) results instantly and final results when a phrase ends.
2. **Topic brain** (`TopicBrain.swift`): after about 20 new final words, it sends the current map summary plus the newest words to Claude Haiku (`claude-haiku-4-5`) through the Anthropic Messages API. The model returns ONE move as JSON:
   - `stay`: same topic (the default, and the most common answer)
   - `deeper`: a sub-topic of the current topic (needs `label`)
   - `new`: a new top-level topic (needs `label`)
   - `back`: return to an earlier topic (needs `backTo` id)
   - plus `newOpenLoops` (strings) and `closedLoops` (ids)
3. **Map** (`TopicMap.swift`): applies the move to a topic tree (ids `t1`, `t2`, …), tracks the current topic and the open loops (ids `L1`, …). `ContentView.swift` renders it.

`SessionController.swift` (`@MainActor @Observable`) wires everything together.

### Two paths
- **Fast path:** draft words go straight to the screen, so the app feels instant.
- **Slow path:** final words are batched and sent to the AI. Only ONE AI call runs at a time, and words that arrive meanwhile wait and ride along on the next call.

## Key design decisions (keep these)
- The AI makes **one small decision per call**. It never regenerates the whole map. This keeps calls fast and the map stable.
- The prompt should bias toward `stay` so the map doesn't fill up with junk topics. Topic jitter is the #1 risk.
- The map summary sent to the AI stays short (ids + labels + current marker + open loops).
- Transcription stays on-device. Only text goes to the cloud.

## Deeper vs. new topic (the hardest call)
`deeper` is only right while the new subject is still about the current topic's **root** (the first node of its row). Once the root no longer fits, it is `new`, even if it grew out of the last thing said.

Example: Dune → worms → the main character → Timothée Chalamet are all `deeper` (still Dune). "He's from NYC" is `new` (New York): it came from Timothée but it isn't about Dune any more. Then Columbia → my friend are `deeper` inside New York. "I love New York" is `back` to New York (no new node), and "pizza" is `deeper` from New York again.

How each move shows on the map:
- `stay`: nothing changes.
- `deeper`: a child node to the right of the current one. A second child of the same node stacks below the first.
- `new`: a new row below, joined by a dotted line.
- `back` to a node in the **same row**: only the current marker moves; no node is added.
- `back` to a topic in an **earlier row**: a new "(cont.)" row, linked to the original.

Rows should rarely go past 3–4 nodes deep. A longer chain usually means a `new` was missed.

### Draft wording for `instructions` in `TopicBrain.swift`
> Pick ONE move. Prefer `stay` unless the subject clearly changed.
> Use `deeper` only if the new subject is still about the ROOT topic of the current row (shown first in the map summary), not just related to the last thing said.
> If it no longer fits the root topic, use `new`, even if it grew out of the last sentence.
> Use `back` when the speakers return to something already on the map, including going back up to a parent inside the same topic.

## Project files

- `ios/OneDMD/`: iOS app source files and assets.
- `ios/OneDMD.xcodeproj/`: Xcode project; open this to work on the app.
- `backend/`: reserved for the backend.

The filenames below refer to files under `ios/OneDMD/`.

| File | Job |
| --- | --- |
| `OneDMDApp.swift` | App entry point |
| `ContentView.swift` | The one screen: topic outline, open loops, transcript, Start/Stop |
| `SessionController.swift` | Connects everything, batching, one AI call at a time |
| `AudioTranscriber.swift` | Mic + SpeechAnalyzer, audio format conversion |
| `TopicBrain.swift` | Anthropic API call + the system prompt (`instructions`) |
| `TopicMap.swift` | Topic tree, open loops, `TopicDecision` model, outline + AI summary |
| `Secrets.swift` | API key for LOCAL TESTING ONLY |

## Tech constraints
- Swift, SwiftUI, Observation framework. Target: iOS 26.0+.
- Must run on a real iPhone (the simulator mic is unreliable).
- Info.plist needs `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
- No third-party dependencies in v1.
- The starter code has not been compiled yet, so expect small API fixes (especially in `AudioTranscriber.swift` around SpeechAnalyzer and Swift 6 concurrency).

## v1 scope
In v1: Start/Stop, the topic outline with the current topic highlighted, the open loops list, and the live transcript.

NOT in v1 (don't build yet): speaker identification, saving conversations, accounts or sharing, an animated graph view, an on-device LLM.

## Tunable knobs
- `wordsPerAICall` in `SessionController.swift`: lower means faster updates but jumpier topics.
- `instructions` in `TopicBrain.swift`: this is where topic quality is won or lost.

## Later / open questions
- Move the API key to a small backend before shipping. Never ship the key in the app.
- Maybe try Apple Foundation Models (on-device) instead of Haiku, to make it free and offline.
- Add a timer flush so leftover words get sent after a pause, not only when the session stops.
- A graph view once the outline feels right.

## Working style
- Keep things simple. The owner wants plain-language explanations.
- Prefer small, working steps over big rewrites.
