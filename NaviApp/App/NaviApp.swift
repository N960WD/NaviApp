import SwiftUI

@main
struct NaviApp: App {
    @StateObject private var store = RouteStore.shared
    @StateObject private var session = NavSession.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RouteListView()
                .environmentObject(store)
                .environmentObject(session)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}
