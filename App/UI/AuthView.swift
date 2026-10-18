import SwiftUI

struct AuthView: View {
    enum Mode { case signIn, signUp, recover }

    @EnvironmentObject private var model: AppModel
    @State private var mode = Mode.signIn
    @State private var username = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var recovery = ""
    @State private var agreed = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image("Logo").resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16))
                        Text("CelloCloud").font(.title.bold())
                        Text("Your photos and files, end-to-end encrypted.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if mode == .recover {
                        TextField("Recovery key (XXXX-XXXX-…)", text: $recovery, axis: .vertical)
                            .font(.body.monospaced()).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .lineLimit(2...4)
                    }
                    SecureField(mode == .recover ? "New password (at least 10 characters)" : "Password", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                    if mode != .signIn {
                        SecureField("Repeat password", text: $password2).textContentType(.newPassword)
                    }
                } header: {
                    Text(mode == .signIn ? "Sign in" : mode == .signUp ? "Create your account" : "Reset your password")
                } footer: {
                    if mode == .signUp {
                        Text("Your password encrypts your files. We can't reset it — you'll get a recovery key next.")
                    } else if mode == .recover {
                        Text("The recovery key you saved when you made your account unlocks your files again.")
                    }
                }

                if mode == .signUp {
                    Section {
                        Toggle(isOn: $agreed) {
                            Text("I agree to the [terms](https://cloud.cellosig.com/terms) and [privacy policy](https://cloud.cellosig.com/privacy). Nothing illegal; abusive accounts are removed.")
                                .font(.footnote)
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? (mode == .signIn ? "Unlocking…" : "Working…")
                                 : mode == .signIn ? "Sign in" : mode == .signUp ? "Create account" : "Reset password")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(busy || username.trimmed.isEmpty || password.isEmpty)
                }

                Section {
                    if mode != .signIn { Button("I have an account — sign in") { switchTo(.signIn) } }
                    if mode != .signUp { Button("Create an account") { switchTo(.signUp) } }
                    if mode != .recover { Button("Forgot password?") { switchTo(.recover) } }
                }
                .font(.subheadline)

                Section {
                    Label("Files, names and details are encrypted on your iPhone before upload. Nobody else can open them — not even us.",
                          systemImage: "lock.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    private func switchTo(_ m: Mode) {
        mode = m
        error = nil
        password = ""
        password2 = ""
    }

    private func submit() {
        error = nil
        let user = username.trimmed.lowercased()
        if mode != .signIn {
            guard password.count >= 10 else { error = "Use a password of at least 10 characters."; return }
            guard password == password2 else { error = "The passwords don't match."; return }
        }
        if mode == .signUp && !agreed { error = "Please accept the terms and privacy policy."; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .signIn:
                    try await model.cloud.signIn(username: user, password: password)
                case .signUp:
                    model.recoveryKey = try await model.cloud.signUp(username: user, password: password)
                case .recover:
                    try await model.cloud.recover(username: user, recoveryText: recovery, newPassword: password)
                }
                password = ""
                password2 = ""
                recovery = ""
                model.didSignIn()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct RecoveryKeyView: View {
    let key: String
    let done: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var saved = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("If you ever forget your password, this key is the only way back into your files. Nobody — including us — can reset it for you.")
                }
                Section("Your recovery key") {
                    Text(key)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: key]],
                                                      options: [.expirationDate: Date().addingTimeInterval(120), .localOnly: true])
                        copied = true
                    }
                    ShareLink("Save or share…", item: "CelloCloud recovery key for \(model.username)\n\n\(key)\n\nKeep this safe. It's the only way back into your files if you forget your password.\n")
                }
                Section {
                    Toggle("I've saved my recovery key", isOn: $saved)
                } footer: {
                    Text("Store it somewhere safe and separate from this iPhone — a password manager, or printed on paper. Copied text is cleared from the clipboard after 2 minutes.")
                }
                Section {
                    Button("Continue to CelloCloud", action: done).bold().disabled(!saved)
                }
            }
            .navigationTitle("Save your recovery key")
        }
    }
}
