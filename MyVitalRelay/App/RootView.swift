import SwiftUI

struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if auth.isSignedIn {
                SyncStatusView()
            } else {
                SignInView()
            }
        }
        .task { await auth.observeAuthState() }
        .task(id: auth.isSignedIn) {
            if auth.isSignedIn { await syncEngine.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンド配信はOSの裁量で遅延しうるため、復帰時にも必ず差分同期を走らせる
            if phase == .active, auth.isSignedIn {
                Task { await syncEngine.sync() }
            }
        }
    }
}
