import LiveKit
import SwiftUI

private struct SupabaseTokenSource: EndpointTokenSource {
    let url: URL
}

@main
struct VoiceAgentApp: App {
    private let session = Session(
        tokenSource: SupabaseTokenSource(
            url: URL(string: "https://vcxwsuawqenaecvyvsnd.supabase.co/functions/v1/livekit-token")!
        ).cached(),
        options: SessionOptions(room: Room(roomOptions: RoomOptions(
            defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(useBroadcastExtension: true)
        )))
    )

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(session)
                .environmentObject(LocalMedia(session: session))
                .environment(\.voiceEnabled, true)
                .environment(\.videoEnabled, true)
                .environment(\.textEnabled, true)
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
