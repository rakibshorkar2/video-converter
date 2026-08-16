import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label(L10n.tabHome, systemImage: "arrow.triangle.2.circlepath") }
            HistoryView()
                .tabItem { Label(L10n.tabHistory, systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label(L10n.tabSettings, systemImage: "gearshape") }
        }
    }
}