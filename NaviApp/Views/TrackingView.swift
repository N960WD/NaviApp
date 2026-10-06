import MapKit
import NaviCore
import SwiftUI

/// The in-car dashboard: clock, speeds, next waypoint, ETAs, target speed and nav log.
struct TrackingView: View {
    @EnvironmentObject private var session: NavSession
    @EnvironmentObject private var settings: AppSettings

    @State private var editing: EditingWaypoint?
    @State private var showMap = false
    @State private var confirmStop = false

    var body: some View {
        Group {
            if let snap = session.snapshot, let route = session.route {
                dashboard(snap, route: route)
            } else {
                ContentUnavailableView("No route loaded", systemImage: "speedometer",
                                       description: Text("Pick a saved route and tap Load for Tracking."))
            }
        }
        .navigationTitle(session.route?.name ?? "Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $editing) { item in
            let status = session.snapshot?.waypoints.first { $0.id == item.id }
            WaypointEditorView(
                waypoint: item.waypoint,
                distanceToGo: status?.distanceToGo ?? item.waypoint.distanceAlong,
                eta: status?.eta,
                onSave: { wp in session.updateWaypoint(wp.id) { $0 = wp } }
            )
        }
        .sheet(isPresented: $showMap) {
            TrackingMapView().presentationDetents([.medium, .large])
        }
        .confirmationDialog("Stop tracking?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { session.stop() }
        }
    }

    // MARK: Dashboard

    private func dashboard(_ s: NavSnapshot, route: SavedRoute) -> some View {
        let u = settings.units
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    header(s)
                    banners(s)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        Readout(title: "SPEED", value: Format.speed(s.currentSpeed, u), unit: u.speedUnit, size: .large)
                        Readout(title: "AVG SPEED", value: Format.speed(s.averageSpeed, u), unit: u.speedUnit, size: .large)
                        targetTile(s)
                        Readout(title: "ELAPSED", value: s.startTime == nil ? "--:--" : Format.duration(s.elapsed))
                    }

                    nextWaypointCard(s)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        Readout(title: "DEST ETA", value: Format.clock(s.destinationETA),
                                caption: s.finishTime == nil ? nil : "arrived")
                        Readout(title: "REMAINING", value: Format.distance(s.distanceRemaining, u, unit: false), unit: u.distanceUnit,
                                caption: s.finishTime == nil ? Format.duration(s.destinationETA?.timeIntervalSince(s.now)) : nil)
                        Readout(title: "MAX SPEED", value: s.maxSpeed > 0 ? Format.speed(s.maxSpeed, u) : "--", unit: u.speedUnit)
                        Readout(title: "ETA BASIS", value: Format.speed(s.projectionSpeed, u), unit: u.speedUnit,
                                caption: s.etaBasis.label)
                    }

                    ProgressView(value: s.progress) {
                        HStack {
                            Text("\(Format.distance(s.distanceAlong, u)) of \(Format.distance(s.routeLength, u))")
                            Spacer()
                            Text("\(Int(s.progress * 100))%")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    navLog(s)
                }
                .padding(12)
            }
            controlBar(s)
        }
        .background(Color.black)
    }

    private func header(_ s: NavSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text("TIME").font(.caption2.bold()).foregroundStyle(.secondary)
                Text(Format.clock(s.now))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.5)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("START").font(.caption2.bold()).foregroundStyle(.secondary)
                Text(Format.clock(s.startTime)).font(.title3.monospaced())
            }
        }
    }

    @ViewBuilder private func banners(_ s: NavSnapshot) -> some View {
        if !s.hasFix {
            Banner(text: "Waiting for GPS…", color: .orange, symbol: "location.slash")
        } else if s.isOffRoute {
            Banner(text: "Off route by \(Format.distance(s.crossTrack, settings.units)) — timing uses closest point",
                   color: .red, symbol: "exclamationmark.triangle")
        }
        if session.isSimulating {
            Banner(text: "Simulated drive", color: .purple, symbol: "play.circle")
        }
    }

    private func targetTile(_ s: NavSnapshot) -> some View {
        let u = settings.units
        guard let target = s.target else {
            return Readout(title: "TARGET SPEED", value: "--", unit: u.speedUnit, caption: "no required times")
        }
        if target.isUnable || s.targetSpeed == nil {
            return Readout(title: "TARGET SPEED", value: "UNABLE", caption: target.waypoint.name, tint: .red, size: .large)
        }
        let need = s.targetSpeed!
        var tint = Color.green
        var caption = "→ \(target.waypoint.name)"
        if let cur = s.currentSpeed {
            let diff = u.speed(need) - u.speed(cur)
            if diff > 2 { tint = .orange; caption = "▲ \(Int(diff.rounded())) · \(target.waypoint.name)" }
            else if diff < -2 { tint = .cyan; caption = "▼ \(Int((-diff).rounded())) · \(target.waypoint.name)" }
        }
        return Readout(title: "TARGET SPEED", value: Format.speed(need, u), unit: u.speedUnit,
                       caption: caption, tint: tint, size: .large)
    }

    private func nextWaypointCard(_ s: NavSnapshot) -> some View {
        let u = settings.units
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NEXT WAYPOINT").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if let next = s.next { Text(next.waypoint.kind.label.uppercased()).font(.caption2.bold()).foregroundStyle(color(for: next.waypoint.kind)) }
            }
            if let next = s.next {
                Text(next.waypoint.name).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.6)
                if let detail = next.waypoint.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack {
                    MiniReadout(title: "DIST", value: Format.distance(next.distanceToGo, u))
                    MiniReadout(title: "TIME TO", value: Format.duration(next.timeToGo))
                    MiniReadout(title: "ETA", value: Format.clock(next.eta))
                }
                if let req = next.waypoint.requiredTime {
                    HStack {
                        MiniReadout(title: "REQUIRED", value: Format.clock(req), tint: .yellow)
                        MiniReadout(title: "REQ SPEED", value: next.isUnable ? "UNABLE" : Format.speed(next.requiredSpeed, u, unit: true), tint: .yellow)
                        MiniReadout(title: "Δ", value: Format.delta(next.delta), tint: deltaColor(next.delta))
                    }
                }
            } else {
                Text(s.finishTime != nil ? "Arrived" : "—").font(.title2.bold())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func navLog(_ s: NavSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAV LOG").font(.caption2.bold()).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(Array(s.waypoints.enumerated()), id: \.element.id) { i, status in
                Button {
                    editing = EditingWaypoint(waypoint: status.waypoint, isNew: false)
                } label: {
                    NavLogRow(status: status, units: settings.units,
                              isNext: i == s.nextIndex, isTarget: status.id == s.targetWaypointID)
                }
                .buttonStyle(.plain)
            }
            Text("Tap a waypoint to set its required crossing time.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func controlBar(_ s: NavSnapshot) -> some View {
        VStack(spacing: 8) {
            if session.isSimulating {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Slider(value: Binding(
                        get: { settings.units.speed(settings.simulatorSpeed) },
                        set: { session.setSimulatorSpeed(settings.units.metersPerSecond($0)) }
                    ), in: 0...160, step: 1)
                    Text(Format.speed(settings.simulatorSpeed, settings.units, unit: true))
                        .font(.caption.monospacedDigit()).frame(width: 64)
                }
            }
            if session.isRunning {
                Button { confirmStop = true } label: {
                    Label("STOP", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.red)
            } else if session.isFinished {
                Button { session.resetTrip() } label: {
                    Label("RESET TRIP", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            } else {
                Button { session.start() } label: {
                    Label("START", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }
        }
        .font(.title2.bold())
        .padding(12)
        .background(.ultraThinMaterial)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showMap = true } label: { Image(systemName: "map") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("ETA based on", selection: $settings.etaBasis) {
                    ForEach(ETABasis.allCases) { Text("\($0.label) speed").tag($0) }
                }
                Divider()
                if session.isSimulating {
                    Button("Stop simulated drive", systemImage: "stop.circle") { session.stopSimulation() }
                } else {
                    Button("Simulate drive", systemImage: "play.circle") { session.startSimulation() }
                }
                Button("Unload route", systemImage: "eject", role: .destructive) { session.unload() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

func deltaColor(_ delta: TimeInterval?) -> Color {
    guard let delta else { return .secondary }
    if abs(delta) <= 30 { return .green }
    return delta > 0 ? .red : .cyan
}

// MARK: Components

struct Readout: View {
    enum Size { case normal, large }

    let title: String
    let value: String
    var unit: String? = nil
    var caption: String? = nil
    var tint: Color = .primary
    var size: Size = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: size == .large ? 40 : 26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            Text(caption ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MiniReadout: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Banner: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(color.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NavLogRow: View {
    let status: WaypointStatus
    let units: UnitSystem
    let isNext: Bool
    let isTarget: Bool

    var body: some View {
        let wp = status.waypoint
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: wp.kind.symbolName).foregroundStyle(color(for: wp.kind)).frame(width: 20)
                Text(wp.name).bold().lineLimit(1)
                if isTarget { Image(systemName: "scope").foregroundStyle(.yellow) }
                Spacer()
                if status.isPassed {
                    Text(status.actualTime.map { "ATA \(Format.clock($0))" } ?? "passed")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("ETA \(Format.clock(status.eta))").font(.callout.monospacedDigit().bold())
                }
            }
            HStack(spacing: 10) {
                if !status.isPassed {
                    Text(Format.distance(status.distanceToGo, units))
                    Text(Format.duration(status.timeToGo))
                }
                if let req = wp.requiredTime {
                    Text("REQ \(Format.clock(req))").foregroundStyle(.yellow)
                    if !status.isPassed {
                        Text(status.isUnable ? "UNABLE" : Format.speed(status.requiredSpeed, units, unit: true))
                            .foregroundStyle(status.isUnable ? .red : .yellow)
                        if let leg = status.legSpeed, abs(leg - (status.requiredSpeed ?? leg)) > 0.3 {
                            Text("leg \(Format.speed(leg, units))").foregroundStyle(.secondary)
                        }
                    }
                    Text(Format.delta(status.delta)).foregroundStyle(deltaColor(status.delta))
                }
                Spacer()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 28)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isNext ? Color.accentColor.opacity(0.18) : Color(white: 0.09))
        )
        .opacity(status.isPassed ? 0.55 : 1)
    }
}

struct TrackingMapView: View {
    @EnvironmentObject private var session: NavSession
    @State private var position: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)

    var body: some View {
        Map(position: $position) {
            if let route = session.route {
                MapPolyline(coordinates: route.points.map(\.coordinate)).stroke(Color.accentColor, lineWidth: 5)
                ForEach(route.activeWaypoints) { wp in
                    Marker(wp.name, systemImage: wp.kind.symbolName, coordinate: wp.coordinate.coordinate)
                        .tint(color(for: wp.kind))
                }
            }
            if session.isSimulating, let p = session.snapshot?.position {
                Annotation("Sim", coordinate: p.coordinate) {
                    Image(systemName: "car.fill").padding(6).background(.purple, in: Circle())
                }
            }
            UserAnnotation()
        }
        .mapControls { MapUserLocationButton(); MapCompass() }
    }
}
