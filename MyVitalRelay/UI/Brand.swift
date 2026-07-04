import SwiftUI

/// アプリアイコンと揃えたブランドカラー。アイコン本体はAssets.xcassets/AppIconを参照。
enum Brand {
    static let teal = Color(red: 0.10, green: 0.74, blue: 0.61)
    static let blue = Color(red: 0.09, green: 0.35, blue: 0.78)

    static let gradient = LinearGradient(
        colors: [teal, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// アプリアイコンと同モチーフのインアプリ用マーク（サインイン画面などのヒーロー表示用）。
struct AppMarkView: View {
    var size: CGFloat = 96

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Brand.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Brand.blue.opacity(0.3), radius: size * 0.12, y: size * 0.06)
    }
}

#Preview {
    AppMarkView()
}
