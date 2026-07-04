import Foundation

// RLS前提の公開値（publishable key）。書き込みは認証済みユーザーのJWTで行い、service_roleは使わない。
enum SupabaseConfig {
    static let url = URL(string: "https://ykcbevvorckcigwwtftw.supabase.co")!
    static let publishableKey = "sb_publishable_s4KitKl3ZQvoz7ME9Sh7GQ_1YO94RL7"
}
