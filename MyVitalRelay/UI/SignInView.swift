import SwiftUI

struct SignInView: View {
    @Environment(AuthService.self) private var auth
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case email, password
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                hero
                VStack(spacing: 20) {
                    googleButton
                    orDivider
                    emailForm
                    if let message = auth.errorMessage {
                        errorBanner(message)
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.top, 72)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }

    private var hero: some View {
        VStack(spacing: 16) {
            AppMarkView(size: 96)
            VStack(spacing: 6) {
                Text("MyVitalRelay")
                    .font(.title.bold())
                Text("ヘルスケアのデータをSupabaseへ自動リレー")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var googleButton: some View {
        Button {
            Task {
                isBusy = true
                await auth.signInWithGoogle()
                isBusy = false
            }
        } label: {
            Label("Googleでサインイン", systemImage: "globe")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text("または")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
    }

    private var emailForm: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                TextField("メールアドレス", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .padding(14)
                Divider().padding(.leading, 14)
                SecureField("パスワード", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { signInWithEmail() }
                    .padding(14)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: signInWithEmail) {
                Group {
                    if isBusy {
                        ProgressView()
                    } else {
                        Text("メールアドレスでサインイン")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(email.isEmpty || password.isEmpty || isBusy)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func signInWithEmail() {
        guard !email.isEmpty, !password.isEmpty, !isBusy else { return }
        Task {
            isBusy = true
            await auth.signIn(email: email, password: password)
            isBusy = false
        }
    }
}
