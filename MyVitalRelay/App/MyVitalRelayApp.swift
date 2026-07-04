import SwiftUI

@main
struct MyVitalRelayApp: App {
    @State private var auth = AuthService()
    @State private var syncEngine = SyncEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(syncEngine)
                .onOpenURL { SupabaseClientProvider.shared.handle($0) }
        }
    }
}
