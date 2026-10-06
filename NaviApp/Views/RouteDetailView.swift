import MapKit
import NaviCore
import SwiftUI

struct EditingWaypoint: Identifiable {
    var waypoint: Waypoint
    var isNew: Bool
    var id: UUID { waypoint.id }
}

/// Route overview and nav-log editor: review generated waypoints, add custom ones by
/// tapping the map, set required times, then load the route for tracking.
struct RouteDetailView: View {
    let routeID: UUID
    @Binding var path: NavigationPath

    @EnvironmentObject private var store: RouteStore
    @EnvironmentObject private var session: NavSession
    @EnvironmentObject private var settings: AppSettings

    @State private var addMode = false
    @State private var editing: EditingWaypoint?
    @State private var plannedText = ""
    @State private var renaming = false
    @State private var newName = ""
    @State private var routePath: RoutePath?

    var body: some View {
        if let route = store.route(id: routeID) {
            content(route)
        } else {
            ContentUnavailableView("Route not found", systemImage: "map")
        }
    }

    private func content(_ route: SavedRoute) -> some View {
        let rp = routePath ?? route.path
        return List {
            Section {
                MapReader { proxy in
                    Map {
                        MapPolyline(coordinates: route.points.map(\.coordinate))
                            .stroke(Color.accentColor, lineWidth: 4)
                        ForEach(route.activeWaypoints) { wp in
                            Marker(wp.name, systemImage: wp.kind.symbolName, coordinate: wp.coordinate.coordinate)
                                .tint(color(for: wp.kind))
                        }
                        UserAnnotation()
                    }
                    .onTapGesture { point in
                        guard addMode, let coord = proxy.convert(point, from: .local),
                              let proj = rp.project(GeoPoint(coord), maxCrossTrack: .infinity) else { return }
                        addMode = false
                        let wp = Waypoint(name: "Custom \(Format.distance(proj.distanceAlong, settings.units))",
                                          detail: "User waypoint", kind: .custom,
                                          coordinate: proj.point, distanceAlong: proj.distanceAlong)
                        editing = EditingWaypoint(waypoint: wp, isNew: true)
                    }
                }
                .frame(height: 280)
                .listRowInsets(EdgeInsets())
                .overlay(alignment: .top) {
                    if addMode {
                        Text("Tap the map near the route to add a waypoint")
                            .font(.footnote.bold())
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }

                LabeledContent("Distance", value: Format.distance(rp.length, settings.units))
                LabeledContent("Apple Maps time", value: Format.duration(route.expectedTravelTime))
                HStack {
                    Text("Planned speed")
                    Spacer()
                    TextField(Format.speed(route.plannedSpeed(routeLength: rp.length), settings.units), text: $plannedText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: plannedText) { savePlanned(route) }
                    Text(settings.units.speedUnit).foregroundStyle(.secondary)
                }
                if route.plannedSpeedOverride != nil {
                    Button("Use Apple Maps average speed") {
                        var r = route
                        r.plannedSpeedOverride = nil
                        plannedText = ""
                        session.apply(r)
                    }
                    .font(.footnote)
                }
            }

            Section {
                Button {
                    session.load(route)
                    path.append(AppDestination.tracking)
                } label: {
                    Label(session.route?.id == route.id ? "Open Dashboard" : "Load for Tracking",
                          systemImage: "speedometer")
                        .frame(maxWidth: .infinity)
                        .bold()
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(route.waypoints.sorted { $0.distanceAlong < $1.distanceAlong }) { wp in
                    Button {
                        editing = EditingWaypoint(waypoint: wp, isNew: false)
                    } label: {
                        WaypointPlanRow(waypoint: wp, units: settings.units)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) { delete(wp.id, from: route) } label: { Label("Delete", systemImage: "trash") }
                        Button { toggle(wp.id, in: route) } label: {
                            Label(wp.isEnabled ? "Hide" : "Show", systemImage: wp.isEnabled ? "eye.slash" : "eye")
                        }
                        .tint(.gray)
                    }
                }
            } header: {
                HStack {
                    Text("Nav log (\(route.activeWaypoints.count))")
                    Spacer()
                    Button(addMode ? "Cancel" : "Add on Map") { addMode.toggle() }
                        .font(.caption.bold())
                }
            } footer: {
                Text("Tap a waypoint to set a required crossing time. Swipe to hide or delete.")
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { newName = route.name; renaming = true } label: { Image(systemName: "pencil") }
        }
        .alert("Rename route", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                var r = route
                r.name = newName
                session.apply(r)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editing) { item in
            let toGo = item.waypoint.distanceAlong - (loadedSnapshot(route)?.distanceAlong ?? 0)
            let eta = loadedSnapshot(route)?.waypoints.first { $0.id == item.id }?.eta
                ?? Date().addingTimeInterval(item.waypoint.distanceAlong / route.plannedSpeed(routeLength: rp.length))
            WaypointEditorView(
                waypoint: item.waypoint,
                distanceToGo: toGo,
                eta: eta,
                onSave: { save($0, in: route) },
                onDelete: item.isNew ? nil : { delete(item.id, from: route) }
            )
        }
        .task(id: route.points.count) { routePath = route.path }
    }

    private func loadedSnapshot(_ route: SavedRoute) -> NavSnapshot? {
        session.route?.id == route.id ? session.snapshot : nil
    }

    private func savePlanned(_ route: SavedRoute) {
        guard let v = Double(plannedText.replacingOccurrences(of: ",", with: ".")), v > 0 else { return }
        var r = route
        r.plannedSpeedOverride = settings.units.metersPerSecond(v)
        session.apply(r)
    }

    private func save(_ wp: Waypoint, in route: SavedRoute) {
        var r = route
        if let i = r.waypoints.firstIndex(where: { $0.id == wp.id }) {
            r.waypoints[i] = wp
        } else {
            r.waypoints.append(wp)
        }
        session.apply(r)
    }

    private func delete(_ id: UUID, from route: SavedRoute) {
        var r = route
        r.waypoints.removeAll { $0.id == id }
        session.apply(r)
    }

    private func toggle(_ id: UUID, in route: SavedRoute) {
        var r = route
        if let i = r.waypoints.firstIndex(where: { $0.id == id }) { r.waypoints[i].isEnabled.toggle() }
        session.apply(r)
    }
}

func color(for kind: WaypointKind) -> Color {
    switch kind {
    case .highwayJunction: .blue
    case .highwayCrossing: .red
    case .townCenter: .orange
    case .abeamTown: .gray
    case .custom: .purple
    case .destination: .green
    }
}

struct WaypointPlanRow: View {
    let waypoint: Waypoint
    let units: UnitSystem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: waypoint.kind.symbolName)
                .frame(width: 28, height: 28)
                .background(color(for: waypoint.kind).opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.name).bold()
                if let detail = waypoint.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.distance(waypoint.distanceAlong, units)).font(.callout.monospacedDigit())
                if let req = waypoint.requiredTime {
                    Label(Format.clock(req), systemImage: "clock.badge.exclamationmark")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.yellow)
                }
            }
        }
        .opacity(waypoint.isEnabled ? 1 : 0.4)
    }
}
