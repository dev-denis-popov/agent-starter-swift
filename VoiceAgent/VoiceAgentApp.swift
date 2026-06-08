import LiveKit
import SwiftUI

private struct SupabaseTokenSource: EndpointTokenSource {
    let url: URL
}

@main
struct VoiceAgentApp: App {
    private let tokenSource: CachingTokenSource
    private let session: Session

    init() {
        let ts = SupabaseTokenSource(
            url: URL(string: "https://vcxwsuawqenaecvyvsnd.supabase.co/functions/v1/livekit-token")!
        ).cached()
        tokenSource = ts
        session = Session(
            tokenSource: ts,
            options: SessionOptions(room: Room(roomOptions: RoomOptions(
                defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(useBroadcastExtension: true)
            )))
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(LocalMedia(session: session))
                .environment(\.voiceEnabled, true)
                .environment(\.videoEnabled, true)
                .environment(\.textEnabled, true)
                .onChange(of: session.isConnected) { _, isConnected in
                    if !isConnected {
                        Task { await tokenSource.invalidate() }
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 900)
        #endif
        #if os(visionOS)
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1500, height: 500)
        #endif
    }
}
