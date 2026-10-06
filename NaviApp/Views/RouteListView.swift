import NaviCore
import SwiftUI

enum AppDestination: Hashable {
    case route(UUID)
    case tracking
}

struct RouteListView: View {
    @EnvironmentObject private var store: RouteStore
    @EnvironmentObject private var session: NavSession
    @EnvironmentObject private var settings: AppSettings

    @State private var path = NavigationPath()
    @State private var showNew = false
    @State private var showSettings = false
    @State private var warning: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let active = session.route {
                    Section("Active") {
                        NavigationLink(value: AppDestination.tracking) {
                            HStack {
                                Image(systemName: session.isRunning ? "record.circle" : "pause.circle")
                                    .foregroundStyle(session.isRunning ? .green : .orange)
                                VStack(alignment: .leading) {
                                    Text(active.name).lineLimit(1)
                                    Text(session.isRunning ? "Tracking" : session.isFinished ? "Arrived" : "Loaded — not started")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Saved routes") {
                    if store.routes.isEmpty {
                        Text("No routes yet. Tap + to plan one.").foregroundStyle(.secondary)
                    }
                    ForEach(store.routes) { route in
                        NavigationLink(value: AppDestination.route(route.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.name).lineLimit(1)
                                Text("\(Format.distance(route.path.length, settings.units)) · \(Format.duration(route.expectedTravelTime)) · \(route.activeWaypoints.count) waypoints")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        if let loaded = session.route?.id,
                           offsets.contains(where: { store.routes[$0].id == loaded }) {
                            session.unload()
                        }
                        store.delete(at: offsets)
                    }
                }
            }
            .navigationTitle("Route Timer")
            .navigationDestination(for: AppDestination.self) { dest in
                switch dest {
                case .route(let id): RouteDetailView(routeID: id, path: $path)
                case .tracking: TrackingView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showNew) {
                NewRouteView { route, warning in
                    path.append(AppDestination.route(route.id))
                    self.warning = warning
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("Limited map data", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button("OK") { warning = nil }
            } message: {
                Text(warning ?? "")
            }
        }
    }
}
