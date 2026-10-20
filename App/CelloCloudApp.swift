import SwiftUI

@main
struct CelloCloudApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var phase

    init() {
        // The Keychain outlives deleting the app: a fresh install starts signed out.
        if !UserDefaults.standard.bool(forKey: "installed") {
            SessionStore.clear()
            UserDefaults.standard.set(true, forKey: "installed")
        }
        Files.clearOpened()
        Backup.register()
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        // Cindy (the user's assistant) inside CelloCloud: off until switched on in Settings
        CindyActions.install(model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(Backup.shared)
                .tint(.brand)
        }
        .onChange(of: phase) { _, now in
            guard model.signedIn else { return }
            if now == .active {
                Backup.shared.start()
                Task { await model.refreshAccount() }
            } else if now == .background {
                Backup.schedule()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !model.signedIn {
                AuthView()
            } else if let key = model.recoveryKey {
                RecoveryKeyView(key: key) { model.recoveryKey = nil }
            } else {
                MainView()
            }
        }
        .animation(.default, value: model.signedIn)
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            FilesTab()
                .tabItem { Label("Files", systemImage: "folder") }
            PhotosTab()
                .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            await model.refreshAccount()
            Backup.shared.start()
        }
    }
}

extension Color {
    static let brand = Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xeb / 255)
}

enum Links {
    static let privacy = URL(string: "https://cloud.cellosig.com/privacy")!
    static let terms = URL(string: "https://cloud.cellosig.com/terms")!
    static let support = URL(string: "https://cloud.cellosig.com/support")!
}
