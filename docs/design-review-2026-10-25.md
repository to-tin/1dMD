# 1DMD design and UX review (2026-10-25)

Notes only. No code was changed.

**How this was reviewed:** I read the SwiftUI views (`ContentView.swift`, `NodeMapView.swift`, `PastChatsView.swift`, `PasteTranscriptView.swift`, `WaveformView.swift`) and the code they lean on (`MapService.swift`, `LiveMapper.swift`, `AudioLevelMonitor.swift`, `AudioTranscriber.swift`, the Info.plist keys in the Xcode project). I also looked at the running app on the iPhone 18 Pro simulator: the sample map, opening a card, pinch-zooming out, Follow, the + menu, and the empty drawer. I did not record, paste, change settings or delete anything, and I did not try VoiceOver or larger text sizes on the simulator. The accessibility notes below come from reading the code.

---

## TL;DR

- **The phone will go to sleep on the table.** Nothing keeps the screen awake, so a few minutes into a chat the screen locks and the mic probably stops too. This is the biggest gap for the core use.
- **A first-time user on a real iPhone gets stuck.** The server address defaults to `127.0.0.1` (the phone itself). The warning tells them to "Set Server", but the Server field is in the drawer, and the drawer button is hidden while recording. Nothing on first launch says a server is needed at all.
- **You can't read it from across the table.** The current topic is a 17pt title in a small card. From 1 m away people see a dark screen with grey boxes. A big "NOW: Pizza (from New York)" view would deliver the app's promise at a glance.
- **Some failures are silent or lose work.** If the mic or the server fails, the app can look like it's working but isn't. A pasted transcript, or an imported recording that was already transcribed, is thrown away if the server fails.
- **Polish and accessibility:** a few buttons are under 44pt or don't match the 48pt white circle style. The mic button has no spoken label. Text doesn't grow with Dynamic Type (card rows are a fixed height). One branch colour is too dark to see on black.

---

## P1: hurts the core use

### 1. The screen locks mid-conversation
- **Status:** the screen-awake part is done on `connect-help` (the screen stays on from Start until the chat is saved). Whether recording should survive a manual lock is still open.
- **Where:** app-wide. There is no `isIdleTimerDisabled` anywhere, and the Info.plist has no `UIBackgroundModes` audio entry.
- **What's wrong:** the phone sits untouched on the table, so iOS auto-locks it after 30 s to 5 min. Without background audio, the mic and transcription stop when it locks.
- **Why it matters:** the map is gone right when people want to glance at it. The words after the lock are probably lost, and nobody notices until later.
- **Suggestion:** set `UIApplication.shared.isIdleTimerDisabled = true` while recording (and back to `false` on Done or Pause). Optionally dim the screen after a while instead of letting it lock. Decide whether recording should survive a lock: either add the audio background mode, or show a clear "Recording stopped when the phone locked" note.

### 2. First launch on a real iPhone: no server and no path to fix it
- **Where:** `MapService.swift:6` (default `127.0.0.1:8000`), `ContentView.swift:79-86` (drawer button hidden while recording), `ContentView.swift:63-77` (offline note), `PastChatsView.swift:128` (Server field at the very bottom of "Past chats").
- **What's wrong:** here is what a new user hits:
  1. They open the app and see a finished map about Dune and pizza, with no hint that it's a demo.
  2. They tap the mic. The words appear, but the map goes blank (see #6).
  3. At the bottom of the map, in small grey text, they see "127.0.0.1:8000 is this phone, not your Mac. Set Server to the address…".
  4. They look for Server, but the drawer button is hidden while recording. To find it they have to tap Done, open "Past chats" (an unlikely place for a setting), and scroll to the bottom.
  5. The hint there says to run `./1dmd start --host 0.0.0.0`, a terminal command, with no link or explanation.
- **Why it matters:** the very first recording fails, and there's no clear way out. Most people would give up here.
- **Suggestion:** on first launch on a device, when the server address is empty or fails `/health`, show a one-screen setup card: "1DMD needs its server running on your Mac", one step to copy, an address field, a Test button, and "Try the demo instead". Make the offline note tappable so it opens the Server field directly, even while recording. Longer term, move Server into a small Settings sheet (gear icon) rather than under Past chats.

### 3. You can't tell "where we are" from across the table
- **Where:** `NodeMapView.swift:18-19` (`.headline` titles, `.subheadline` bullets), `NodeMapView.swift:35` (212pt cards), `NodeMapView.swift:455-457` (`NOW` tag, `caption2`).
- **What's wrong:** at zoom 1 the screen shows about 3 cards in 17pt text. The `NOW` tag is about 11pt. The bottom third of the map area is often empty black. From 60-100 cm, which is normal table distance, only "a white-bordered box" can be seen. Nothing shows "how we got here" or "the main point" without panning.
- **Why it matters:** glanceability is the whole product. If people have to pick the phone up, it interrupts the conversation it's meant to help.
- **Suggestion:** add a glance strip above the transcript while recording. Show the current topic in large type (about 34pt bold), with its path in smaller type underneath ("Dune → Timothée → **New York → Pizza**"). Keep the map for detail. Also consider a "fit whole map" button next to Follow, so the shape of the chat is one tap away.

### 4. Silent failures: the app looks like it's listening when it isn't
- **Where:** `AudioLevelMonitor.swift:89-91` (`engine.start()` error is swallowed), `ContentView.swift:310-320` (state becomes `.recording` anyway), `LiveMapper.swift:171-176` (a batch the server rejects is skipped without a word).
- **What's wrong:** if the mic can't start (permission denied, another app holds it, a phone call), the timer still runs and the mic button shows Pause. The waveform stays flat, which only hints at the problem. A batch the server refuses is skipped, so part of the conversation never reaches the map, and nobody is told.
- **Why it matters:** people trust the map to reflect the chat. A silent gap is worse than a visible error.
- **Suggestion:** have `AudioLevelMonitor.start()` report failure. When it fails, don't enter `.recording`; show "Can't use the microphone. Allow it in Settings → 1DMD" with an Open Settings button. Ask for mic permission explicitly (`AVAudioApplication.requestRecordPermission`) before the first start. For skipped batches, show a brief "Part of the chat couldn't be mapped" note, or count them.

### 5. Paste and import throw the words away when the server fails
- **Where:** `ContentView.swift:199-208` (`mapTranscript`) and `ContentView.swift:187-196` (`mapAudio`). They save only on success (`then:`), and the paste sheet is already gone (`PasteTranscriptView.swift:36-39`).
- **What's wrong:** if the server is offline, the user gets an alert and the pasted text is gone. With import it's worse: an audio file the phone just spent minutes transcribing is discarded too.
- **Why it matters:** it's lost work, and it's most likely to happen on first use, when the server isn't set up yet.
- **Suggestion:** save the chat with its transcript first (as live recording already does, showing "No map yet"), then map it. Add a "Make map" retry on chats that have no map.

---

## P2: friction

### 6. The screen goes blank when recording starts
- **Where:** `ContentView.swift:42` (`live?.map ?? openChat?.map ?? .empty`).
- **What's wrong:** starting a new chat swaps the sample map for an empty black canvas until the first server reply, which comes after about 20 words or a 3 s pause. If the server has no API key, the reply has no map, so the screen stays blank with no message.
- **Why it matters:** it looks broken during the first 10-20 seconds, which is exactly when a new user decides whether it works.
- **Suggestion:** show an empty-state message in the map area, such as "Listening… the map appears after the first few sentences", and switch it to "The server has no Claude key" when that's the case.

### 7. The sample map isn't labelled as a sample
- **Where:** `ContentView.swift:14` and `ContentView.swift:280-284` (New chat shows `.sample` again).
- **What's wrong:** on first launch, and after tapping New chat, the user sees a full, real-looking map. The drawer says "No chats yet", which contradicts it.
- **Why it matters:** it's confusing ("whose chat is this?"), and New chat appears to do nothing new.
- **Suggestion:** show a small "Example" tag at the top of the map, plus one line such as "Tap the mic to map your own conversation." Or show an empty state with a "See an example" link.

### 8. Recording, Paused and Stopped look too alike
- **Where:** `ContentView.swift:476-502` (`MicButton`: mic, pause, play), `ContentView.swift:460-474` (`DoneButton` uses `stop.fill` but is called "Done").
- **What's wrong:** the main button changes meaning (start, then pause, then resume). The stop square is labelled "Done" for VoiceOver only. Nothing in the app clearly says "recording" (no red dot or label), and paused looks almost the same as recording apart from the icon.
- **Why it matters:** people at the table need to know at a glance whether the phone is listening. That's a trust and privacy issue too.
- **Suggestion:** add a clear status pill, such as a red dot with "Listening 3:12" or "Paused". Consider making the stop button say "Done" visibly, or using `checkmark`, so it doesn't look like a media stop.

### 9. The offline note is small and easy to miss
- **Where:** `ContentView.swift:63-77`.
- **What's wrong:** two lines of `.footnote` text, the second in muted grey, at the bottom of the map with no background. It sits on top of map content, and nothing appears where people are looking (the NOW card).
- **Why it matters:** this is the main "something's wrong" signal while recording.
- **Suggestion:** show it as a capsule badge like `MappingBadge`, with an icon (`wifi.slash`), "Map paused, words kept", and a tap that opens the server details or setting.

### 10. Error alerts use raw system wording
- **Where:** `ContentView.swift:388-390` (`mapFailed` uses `error.localizedDescription`), `MapService.swift:262` ("The server answered with HTTP 500." plus the raw body).
- **What's wrong:** live recording uses the friendly `MapService.explain()`, but paste and import errors show iOS text such as "Could not connect to the server." or HTTP codes and server bodies.
- **Why it matters:** this breaks your plain-language rule, and the same problem gets two different messages.
- **Suggestion:** route `mapFailed` through `MapService.explain(error)` for network and server errors, and drop raw HTTP bodies from user-facing text.

### 11. Text doesn't grow with Dynamic Type (cards clip)
- **Where:** `NodeMapView.swift:26` (`rowHeight = 22`, fixed), `NodeMapView.swift:35` (fixed 212pt width), `NodeMapView.swift:450,474` (`lineLimit(1)`). Fixed `.system(size: 15)` is used in `ContentView.swift:409,448,531,549` and `PasteTranscriptView.swift:16,22`.
- **What's wrong:** titles and bullets use text styles that scale, but they sit in fixed 22pt rows, so larger sizes get cut off or squeezed (`minimumScaleFactor(0.8)`). The transcript, timer and badges don't scale at all.
- **Why it matters:** this is an Apple HIG and accessibility requirement, and larger text would also help reading from across the table.
- **Suggestion:** use `@ScaledMetric` for `rowHeight`, card width and paddings, and swap the fixed sizes for text styles (`.subheadline`, `.body.monospacedDigit()`). Test at the AX3 text size.

### 12. VoiceOver gaps
- **Where:** `ContentView.swift:476-502` (mic button has no label), `NodeMapView.swift:416-434` (only cards with a description get grouped), map edges (not exposed).
- **What's wrong:** VoiceOver reads the mic button from its icon name, without saying "Start recording", "Pause" or "Resume". Cards without a description are read as loose pieces. The links between topics (deeper, new topic, back to) aren't spoken. When the current topic changes, nothing is announced.
- **Why it matters:** a blind or low-vision user can't follow the conversation's shape, which is the core feature.
- **Suggestion:** give the mic button an `.accessibilityLabel` that changes with state. Group every card (`.combine`) and add "current topic" to the current one. Add an accessibility value such as "under Dune" or "new topic after Dune". Post `AccessibilityNotification.Announcement("Now: Pizza")` when `currentID` changes. Hide the waveform from VoiceOver.

### 13. Touch targets under 44pt
- **Where:** `ContentView.swift:552-559` (cancel ✕ in the mapping badge, 24×24), `PastChatsView.swift:255-262` (Test button, 30pt tall), `PastChatsView.swift:48-57` (New chat, 40×40), the card chevron (11pt icon; the whole card is tappable, so that one is fine).
- **What's wrong:** these are below Apple's 44×44pt minimum.
- **Why it matters:** missed taps, especially on Cancel during a long import.
- **Suggestion:** keep the look but add `.contentShape` and frame them to at least 44×44. For example, the ✕ can stay 24pt visually inside a 44pt hit area.

### 14. The drawer's New chat button doesn't match the round-button style
- **Where:** `PastChatsView.swift:48-57` (dark grey `MapStyle.button` circle, 40pt, white icon).
- **What's wrong:** every other round button (menu, Follow, +, mic, Done) is a 48pt white circle with a black icon.
- **Why it matters:** you asked for one consistent round-button style.
- **Suggestion:** make it 48pt white with a black icon, or make a shared `RoundButton` view so the five copies can't drift apart. Today the size, fill and icon weight are copy-pasted in 5 places, and only two use `ScaleButtonStyle` (the menu and Follow don't, so they press differently).

### 15. The Server field doesn't look like a field
- **Where:** `PastChatsView.swift:246-254`.
- **What's wrong:** on the simulator, the field is grey monospaced placeholder text on a dark background with no border or fill. It reads as a label. The hint underneath mentions a terminal command.
- **Why it matters:** this is the one setting a new user must change.
- **Suggestion:** give it a filled rounded background like the Test capsule, and a clear label such as "Mac's address (e.g. 192.168.1.20:8000)". Show the last successful test result ("Connected ✓") persistently, not only until the next edit.

---

## P3: polish

### 16. One branch colour disappears on black
- **Where:** `NodeMapView.swift:61` (`.rose` = `#5800FF`), also used for edges.
- **What's wrong:** it has about 2.3:1 contrast on the card colour `#1C1C1E` and about 2.9:1 on black, below the 3:1 WCAG minimum for graphics. The "My friend" dot and its arrow are hard to see in the screenshots. The 1.5pt dotted lines are also faint once zoomed out.
- **Suggestion:** lighten it to about `#8A5CFF`, and check all 7 branch colours plus `jump` and `continued` at 3:1 or better against both backgrounds. (Side note: the case names don't match the colours. `.teal` is green, `.yellow` is blue, `.blue` is pink. Renaming them would make this easier to maintain.)

### 17. Nothing explains what the map's lines mean
- **Where:** `NodeMapView.swift:13-16`, `NodeMapView.swift:664-667`.
- **What's wrong:** solid coloured = deeper, red dotted = new topic, orange dotted with "cont." = back to. Nowhere in the app says so.
- **Suggestion:** add a tiny legend, either in the drawer or as a one-time tooltip on the first real map.

### 18. The map scrolls under the status bar, and the menu button covers cards
- **Where:** `NodeMapView.swift:248` (`contentInsetAdjustmentBehavior = .never`), `ContentView.swift:79-86`.
- **What's wrong:** card titles slide under the clock and Dynamic Island and get cut off (seen in the simulator after Follow). The floating menu and Follow buttons sit directly on top of card text, with no backdrop.
- **Suggestion:** add a short black-to-clear fade at the top edge of the map, and a subtle shadow or dark ring around the floating buttons so they separate from the cards.

### 19. Follow resets the zoom, and its icon suggests GPS
- **Where:** `NodeMapView.swift:198`, `NodeMapView.swift:269` (`zoomToOne: true`), `NodeMapView.swift:403` (`location.fill`).
- **What's wrong:** if you zoomed out to see the whole chat, Follow snaps back to 1×. The location arrow suggests maps or GPS.
- **Suggestion:** keep the user's zoom when re-centring, or only zoom in if the current card would be too small to read. Consider `scope` or `dot.viewfinder` as the icon.

### 20. Delete has no undo, and landscape is allowed
- **Where:** `PastChatsView.swift:114-120` (swipe, then Delete at once), project settings (landscape orientations on).
- **What's wrong:** one swipe permanently deletes a chat with no confirmation or undo. On a phone lying flat, iOS may flip orientation when someone nudges it, and the layout isn't designed for landscape.
- **Suggestion:** add a confirmation dialog or a 5-second "Undo" toast. Lock the app to portrait for v1.

---

### What's already good
- The night palette is calm and right for a table. White text on `#1C1C1E` passes AA easily, and the muted grey (about 6:1) passes too.
- One accent (the white border plus the `NOW` tag) for the current topic is a clear, simple hierarchy.
- The Test button and `MapService.explain()` messages are already plain and specific. Use them everywhere (#10).
- Tap to open a description, pinch to zoom, and Follow all felt smooth in the simulator.
