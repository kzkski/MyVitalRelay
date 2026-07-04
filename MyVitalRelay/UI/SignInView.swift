import SwiftUI

struct SignInView: View {
    @Environment(AuthService.self) private var auth
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task {
                            isBusy = true
                            await auth.signInWithGoogle()
                            isBusy = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("Googleでサインイン")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isBusy)
                }
                Section("メールアドレスでサインイン") {
                    TextField("メールアドレス", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("パスワード", text: $password)
                    Button {
                        Task {
                            isBusy = true
                            await auth.signIn(email: email, password: password)
                            isBusy = false
                        }
                    } label: {
                        if isBusy {
                            ProgressView()
                        } else {
                            Text("サインイン")
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || isBusy)
                }
                if let message = auth.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("MyVitalRelay")
        }
    }
}
