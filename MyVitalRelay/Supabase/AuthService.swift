import Foundation
import Observation
import Supabase

@Observable
@MainActor
final class AuthService {
    private(set) var isSignedIn = false
    private(set) var userId: UUID?
    var errorMessage: String?

    private let client = SupabaseClientProvider.shared

    /// セッション復元を含む認証状態の監視。RootViewの.taskから呼ばれ、Viewの生存期間中走り続ける。
    func observeAuthState() async {
        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .tokenRefreshed:
                isSignedIn = session != nil
                userId = session?.user.id
            case .signedOut:
                isSignedIn = false
                userId = nil
            default:
                break
            }
        }
    }

    func signIn(email: String, password: String) async {
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            isSignedIn = true
            userId = session.user.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        try? await client.auth.signOut()
        isSignedIn = false
        userId = nil
    }
}
