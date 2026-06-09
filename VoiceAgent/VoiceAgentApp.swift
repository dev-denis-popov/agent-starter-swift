import LiveKit
import SwiftUI

private struct SupabaseTokenSource: EndpointTokenSource {
    let url: URL

    // Forward the signed-in user's Supabase JWT so the `livekit-token` edge
    // function can authenticate the user and embed it in the participant
    // metadata. The agent reads it back to act on behalf of the user (its MCP
    // tool calls run RLS-scoped to this user). `currentSession` is read on each
    // fetch so the latest (auto-refreshed) access token is always used.
    var headers: [String: String] {
        guard let token = SupabaseService.client.auth.currentSession?.accessToken else {
            return [:]
        }
        return ["Authorization": "Bearer \(token)"]
    }
}

@main
struct VoiceAgentApp: App {
    private let session: Session

    init() {
        // Each fetch mints a fresh room + participant identity and dispatches the
        // agent, so the token must NOT be cached: a cached token would reconnect to
        // the previous (now empty, agent-departed) room and the user couldn't talk.
        let tokenSource = SupabaseTokenSource(
            url: URL(string: "https://vcxwsuawqenaecvyvsnd.supabase.co/functions/v1/livekit-token")!
        )
        session = Session(
            tokenSource: tokenSource,
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
