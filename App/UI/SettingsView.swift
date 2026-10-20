import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var backup: Backup
    @State private var changingPassword = false
    @State private var deletingAccount = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: model.username)
                    if let a = model.account {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: Double(a.used), total: Double(max(a.quota, 1)))
                                .tint(Double(a.used) / Double(max(a.quota, 1)) > 0.9 ? .orange : .brand)
                            Text("\(a.used.bytes) of \(a.quota.bytes) used").font(.caption).foregroundStyle(.secondary)
                        }
                        if let s = a.storage, s != "ok" {
                            Label(s == "offline" ? "Storage is offline right now — you can't upload or open files until it's back. Your files are safe."
                                  : "The server's storage is nearly full — uploads are paused.", systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Toggle("Camera backup", isOn: Binding(get: { backup.enabled }, set: { on in
                        if on { Task { _ = await backup.turnOn() } } else { backup.turnOff() }
                    }))
                    if backup.enabled {
                        Toggle("Use mobile data", isOn: $backup.cellular)
                    }
                    if !backup.status.isEmpty {
                        HStack {
                            if backup.running { ProgressView().padding(.trailing, 4) }
                            Text(backup.status).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Camera backup")
                } footer: {
                    Text("New photos and videos you take go into the \"\(Backup.folderName)\" folder, encrypted. iOS lets it run in the background only now and then (usually overnight while charging); opening CelloCloud backs up right away.")
                }

                CindySettingsSection()

                Section {
                    Button("Change password") { changingPassword = true }
                    Button("Sign out") { confirmSignOut = true }
                    Button("Delete account", role: .destructive) { deletingAccount = true }
                } header: {
                    Text("Security")
                } footer: {
                    Text("🔒 Your files, their names and details are encrypted on this iPhone before upload. Only your password or recovery key can open them.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    if let built = Bundle.main.object(forInfoDictionaryKey: "CelloCloudBuildDate") as? String {
                        LabeledContent("Built", value: built)
                    }
                    Link("Privacy policy", destination: Links.privacy)
                    Link("Terms", destination: Links.terms)
                    Link("Support", destination: Links.support)
                    Link("CelloCloud on the web", destination: URL(string: "https://cloud.cellosig.com")!)
                }
            }
            .navigationTitle("Settings")
            .refreshable { await model.refreshAccount() }
            .confirmationDialog("Sign out of CelloCloud on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
            } message: { Text("You'll need your password to sign back in. Camera backup stops.") }
            .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
            .sheet(isPresented: $deletingAccount) { DeleteAccountSheet() }
        }
    }
}

private struct ChangePasswordSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var next = ""
    @State private var next2 = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current password", text: $current).textContentType(.password)
                }
                Section {
                    SecureField("New password (at least 10 characters)", text: $next).textContentType(.newPassword)
                    SecureField("Repeat the new password", text: $next2).textContentType(.newPassword)
                } footer: {
                    Text("Your files stay as they are. Other devices are signed out. Your recovery key keeps working.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if done { Section { Label("Password changed.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }
            }
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done ? "Done" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else if !done { Button("Change", action: change).disabled(current.isEmpty || next.isEmpty) }
                }
            }
        }
    }

    private func change() {
        error = nil
        guard next.count >= 10 else { error = "Use a password of at least 10 characters."; return }
        guard next == next2 else { error = "The passwords don't match."; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.cloud.changePassword(current: current, next: next)
                done = true
                current = ""; next = ""; next2 = ""
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DeleteAccountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var sure = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This deletes your account and ALL your files from CelloCloud. It can't be undone.")
                    Toggle("I understand", isOn: $sure)
                    SecureField("Your password", text: $password).textContentType(.password)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(role: .destructive, action: delete) {
                        HStack { if busy { ProgressView().padding(.trailing, 4) }; Text("Delete my account").bold() }
                    }
                    .disabled(!sure || password.isEmpty || busy)
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func delete() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await model.cloud.deleteAccount(password: password)
                dismiss()
                model.accountDeleted()
            } catch { self.error = error.localizedDescription }
        }
    }
}
