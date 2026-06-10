# WakeWord (optional module)

Self-contained hands-free **"Hey LiveKit"** wake-word detection. The app builds
and runs **without** this package (connect via the button); link it only to add
voice activation. Nothing here depends on the app, LiveKit, or Supabase.

Based on [livekit/livekit-wakeword](https://github.com/livekit/livekit-wakeword)
(ONNX Runtime + CoreML). All models are bundled as package resources:

- `melspectrogram.onnx`, `embedding_model.onnx` — frontend (loaded via `Bundle.module`)
- `hey_livekit.onnx` — the wake-word classifier

## What it does

`WakewordEngine` taps the mic with a private `AVAudioEngine` (`.measurement`
mode, near-raw audio) and runs inference on a rolling 2 s window. When the score
crosses `0.75` it calls `onWake` once, on the main actor. It does **not** decide
what happens next — the host app does (e.g. start a session).

> Audio is captured with a private `AVAudioEngine` on purpose. LiveKit's
> pre-connect recorder delivers no audio before a room is connected, so it can't
> drive detection. See the module source for details.

## Enable it in the app (≈6 lines)

1. **Link the package** to the `VoiceAgent` target:
   Xcode → target *VoiceAgent* → *General* → *Frameworks, Libraries, and
   Embedded Content* → **+** → *Add Other… → Add Package Dependency…* → choose
   the local `Packages/WakeWord` → add the **WakeWord** product.

2. **Drive it from `StartView`** (shown while disconnected):

   ```swift
   import WakeWord

   struct StartView: View {
       @EnvironmentObject private var session: Session
       @State private var wakeword = try? WakewordEngine()
       // ...

       var body: some View {
           VStack { /* bars(), connectButton() */ }
               .onAppear { startWakeword() }
               .onDisappear { wakeword?.stopListening() }
       }

       private func startWakeword() {
           guard let wakeword else { return }
           wakeword.onWake = { [weak wakeword] in
               wakeword?.stopListening()
               Task {
                   // Let the audio HW fully release before LiveKit grabs the mic.
                   try? await Task.sleep(nanoseconds: 400_000_000)
                   await session.start()
               }
           }
           wakeword.startListening()
       }
   }
   ```

To disable wake-word again, remove the WakeWord product from the target — the
app falls back to button-only connect with zero code changes.

## API

```swift
public final class WakewordEngine: ObservableObject {
    public init() throws                      // loads the bundled classifier
    public var onWake: (() -> Void)?          // fired once per detection (main actor)
    @Published public private(set) var isRunning: Bool
    @Published public private(set) var lastError: String?
    @MainActor public func startListening()   // requests mic permission, then listens
    @MainActor public func stopListening()    // stops + releases the mic/session
}
```
