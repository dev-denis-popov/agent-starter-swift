# Wake-word ("Hey LiveKit") — design & gotchas

Hands-free activation: while the app is on the disconnected `StartView`, it
listens for **"Hey LiveKit"**; on detection it starts the LiveKit `Session`
(same as tapping the connect button). Everything is **optional** — the app works
with the feature off, and removing the module changes nothing else.

> ⚠️ Read the **Design decisions** section before changing anything here. Each
> point is a bug we already hit and fixed. It's easy to "simplify" the code
> straight back into a crash or a broken connection.

---

## 1. Where it lives

| Piece | Location |
| --- | --- |
| Detection + engine + models (the whole feature) | `Packages/WakeWord/` (local SPM package, module `WakeWord`) |
| Public engine API | `Packages/WakeWord/Sources/WakeWord/WakewordEngine.swift` |
| Vendored detector (from livekit/livekit-wakeword) | `Packages/WakeWord/Sources/WakeWord/LiveKitWakeWord/` |
| ONNX models (mel, embedding, **classifier**) | `Packages/WakeWord/Sources/WakeWord/Resources/` (loaded via `Bundle.module`) |
| App integration (the only app-side code) | `VoiceAgent/App/StartView.swift` |
| Module README / enable steps | `Packages/WakeWord/README.md` |

The app integration is tiny: linking the `WakeWord` product + a hook in
`StartView`. No classifier or model files live in the app target.

## 2. Enable / disable

- **Disable at runtime:** set `wakeWordEnabled = false` in `StartView.swift`.
  The app falls back to button-only connect. (Engine is constructed but never
  started.)
- **Remove entirely:** unlink the `WakeWord` product from the `VoiceAgent`
  target (Xcode → target → *Frameworks, Libraries, and Embedded Content*) and
  delete the wake-word code from `StartView`. The app is back to the stock
  template. The `Packages/WakeWord` folder can stay; if unlinked it isn't built.
- **Re-enable:** see `Packages/WakeWord/README.md` (link product + ~6-line hook).

## 3. Runtime flow

```
StartView appears (disconnected)
        │  wakeWordEnabled == true
        ▼
WakewordEngine.startListening()
        │  request mic permission, build model OFF the main thread,
        │  AVAudioEngine taps mic @ .measurement (near-raw audio)
        ▼
rolling 2 s window → WakeWordModel.predict() on a background queue (~20 Hz)
        │  score ≥ 0.75  →  onWake() (main actor, once)
        ▼
StartView.onWake:
   wakeword.stopListening(handoff: true)   // stop engine, KEEP session active
   sleep ~300 ms                           // let our audio unit release
   session.start()                         // LiveKit reconfigures the session
        ▼
session connected → AppView swaps StartView out → onDisappear → stopListening()
```

## 4. Design decisions (a.k.a. do-not-regress)

1. **Audio comes from a private `AVAudioEngine`, not LiveKit's recorder.**
   `LocalAudioTrackRecorder` / `PreConnectAudioBuffer` deliver **zero audio
   before the room connects** (verified on simulator *and* device: no audio
   chunks, preconnect "Sent 0KB"), so they cannot drive detection. The private
   `AVAudioEngine` in `.measurement` mode gives near-raw audio and detection
   works (score reaches 0.8+).

2. **Audio-thread code is `nonisolated`.** The app builds with
   `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. If the realtime tap callback is
   inferred main-actor-isolated, `AVAudioEngine` running it on its render thread
   trips a `dispatch_assert_queue` **crash**. So the tap/inference path and the
   shared ring buffer are `nonisolated` / `nonisolated(unsafe)` (guarded by
   `ringLock`); only `@Published` UI state stays `@MainActor`.

3. **The model is built off the main thread.** Creating the ORT/CoreML sessions
   compiles the CoreML models (hundreds of ms). Doing it on the main actor
   freezes the UI and logs "should not be called on the main thread". `buildModel()`
   runs on a background queue.

4. **On handoff, do NOT deactivate the `AVAudioSession`.** Calling
   `setActive(false, .notifyOthersOnDeactivation)` right before `session.start()`
   stalled WebRTC's audio unit → mic publish timed out → **"Connection failed:
   Timed out"**. Fix: `stopListening(handoff: true)` leaves the session active so
   LiveKit reconfigures it for the call. Only the non-handoff stop (leaving the
   screen without triggering) deactivates, to release the mic.

5. **Test on a real device.** LiveKit's WebRTC media (ICE/DTLS) does **not**
   establish on the iOS Simulator — you'll see `iOSSimulatorAudioDevice …
   Abandoning I/O cycle`, ICE timeouts, and "Connection failed" regardless of
   this feature. Wake-word *detection* works on the simulator (our AVAudioEngine
   taps the Mac mic), but the call won't connect there.

## 5. Tuning & customization

In `WakewordEngine.swift`:

- `triggerThreshold` (0.75) — score needed to fire.
- `predictInterval` (0.05 s) — min time between inferences.
- `windowSeconds` (2.0) — rolling window length fed to the model.
- Handoff delay (~300 ms) lives in `StartView.onWake`.

**Swap the wake word:** replace
`Packages/WakeWord/Sources/WakeWord/Resources/hey_livekit.onnx` with another
exported classifier of the same name (or add more and load them — the underlying
`WakeWordModel` accepts multiple classifier URLs). See
[livekit/livekit-wakeword](https://github.com/livekit/livekit-wakeword) for how
to train/export a classifier.

## 6. Diagnostics

The engine prints `[WAKEWORD] …` lines (filter the Xcode console by `WAKEWORD`):

| Log | Meaning |
| --- | --- |
| `listening (AVAudioEngine, hwRate=…)` | capture started |
| `first audio chunk: N samples` | audio is flowing |
| `score=…` (printed when ≥ 0.3) | detection running; values approaching 1.0 = good |
| `mic permission denied` / `start failed: …` | engine couldn't start |

These are debug aids; remove or gate them behind a flag for release if desired.

## 7. Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Trigger never fires, no `first audio chunk` | No mic audio. On simulator via LiveKit recorder this is expected — we use AVAudioEngine instead; check mic permission. |
| `dispatch_assert_queue` crash on the audio thread | An audio-path method/closure lost its `nonisolated` (see decision #2). |
| UI freezes ~1 s when listening starts | Model is being built on the main thread (see decision #3). |
| "Connection failed: Timed out" after a trigger | Handoff is deactivating the session — use `stopListening(handoff: true)` (see decision #4). |
| Everything fails to connect even with wake-word off | Not this feature — test on a real device / check network (UDP) and the `livekit-token` Supabase function (see decision #5). |
