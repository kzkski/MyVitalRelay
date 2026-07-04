import Supabase

enum SupabaseClientProvider {
    static let shared = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.publishableKey,
        options: .init(
            auth: .init(redirectToURL: SupabaseConfig.oauthRedirectURL)
        )
    )
}
