import SwiftUI

@main
struct VideoConverterApp: App {
    @State private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .preferredColorScheme(container.settings.appearance.preferredColorScheme)
                .onOpenURL { url in
                    Task { await container.handleIncomingURL(url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        container.queue.pauseForBackground()
                    case .active:
                        container.queue.resumeFromForeground()
                    default:
                        break
                    }
                }
        }
    }
}

extension AppearanceOption {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}