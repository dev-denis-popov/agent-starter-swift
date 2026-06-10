import LiveKitComponents
import SwiftUI
import WakeWord

/// The initial view that is shown when the app is not connected to the server.
struct StartView: View {
    @EnvironmentObject private var session: Session

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var button

    /// Set to `false` to fall back to button-only connect (no wake-word).
    private let wakeWordEnabled = true

    /// Optional hands-free wake-word listener. `nil` if the classifier is
    /// missing. Runs only while this (disconnected) view is shown.
    @State private var wakeword = try? WakewordEngine()

    var body: some View {
        VStack(spacing: 8 * .grid) {
            bars()
            connectButton()
        }
        .padding(.horizontal, horizontalSizeClass == .regular ? 32 * .grid : 16 * .grid)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, content: tip)
        .onAppear { if wakeWordEnabled { startWakeword() } }
        .onDisappear { wakeword?.stopListening() }
        #if os(visionOS)
            .glassBackgroundEffect()
            .frame(maxWidth: 175 * .grid)
        #endif
    }

    /// Listen for "Hey LiveKit"; on detection, release the mic and connect.
    private func startWakeword() {
        guard let wakeword else { return }
        wakeword.onWake = { [weak wakeword] in
            // Stop our engine but leave the audio session active so LiveKit can
            // reconfigure it for the call without a deactivate/activate cycle
            // (which stalls WebRTC's audio unit → publish timeout).
            wakeword?.stopListening(handoff: true)
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await session.start()
            }
        }
        wakeword.startListening()
    }

    private func bars() -> some View {
        HStack(spacing: .grid) {
            let bars = [2, 8, 12, 8, 2].map { $0 * .grid }
            ForEach(0 ..< 5, id: \.self) { index in
                Rectangle()
                    .fill(.fg0)
                    .frame(width: 2 * .grid, height: bars[index])
            }
        }
    }

    private func tip() -> some View {
        VStack(spacing: 2 * .grid) {
            #if targetEnvironment(simulator)
                Text("connect.simulator")
                    .foregroundStyle(.fgModerate)
            #endif
            Text("connect.tip")
                .foregroundStyle(.fg3)
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .safeAreaPadding(.horizontal, horizontalSizeClass == .regular ? 32 * .grid : 16 * .grid)
        .safeAreaPadding(.vertical)
    }

    @ViewBuilder
    private func connectButton() -> some View {
        AsyncButton {
            await session.start()
        } label: {
            HStack {
                Spacer()
                Text("connect.start")
                    .matchedGeometryEffect(id: "connect", in: button)
                Spacer()
            }
            .frame(width: 58 * .grid, height: 11 * .grid)
        } busyLabel: {
            HStack(spacing: 4 * .grid) {
                Spacer()
                Spinner()
                    .transition(.scale.combined(with: .opacity))
                Text("connect.connecting")
                    .matchedGeometryEffect(id: "connect", in: button)
                Spacer()
            }
            .frame(width: 58 * .grid, height: 11 * .grid)
        }
        #if os(visionOS)
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        #else
        .buttonStyle(ProminentButtonStyle())
        #endif
    }
}

#Preview {
    StartView()
}
