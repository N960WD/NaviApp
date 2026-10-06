import CoreLocation
import MapKit
import NaviCore
import SwiftUI

/// Address / POI autocomplete backed by MKLocalSearchCompleter.
final class PlaceSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet {
            if query.isEmpty { results = [] } else { completer.queryFragment = query }
        }
    }
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = Array(completer.results.prefix(8))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> MKMapItem? {
        try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first
    }
}

/// Holds a CLLocationManager so the permission prompt can be shown during planning.
private final class PermissionAsker: ObservableObject {
    let manager = CLLocationManager()
    func ask() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }
}

struct NewRouteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var search = PlaceSearchModel()
    @StateObject private var permission = PermissionAsker()

    enum Field { case origin, destination }

    @State private var origin: MKMapItem? = nil          // nil = current location
    @State private var destination: MKMapItem?
    @State private var editing: Field?
    @State private var avoidTolls = false
    @State private var alternatives: [MKRoute] = []
    @State private var selected = 0
    @State private var isRouting = false
    @State private var progress: RoutePlanner.Progress?
    @State private var errorMessage: String?

    /// Called with the saved route and an optional warning about degraded map data.
    var onCreated: (SavedRoute, String?) -> Void = { _, _ in }

    var body: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    placeRow(label: "From", value: origin?.name ?? "Current Location", field: .origin)
                    placeRow(label: "To", value: destination?.name ?? "Search destination", field: .destination)
                    Toggle("Avoid tolls", isOn: $avoidTolls)
                }

                if let editing {
                    Section {
                        TextField(editing == .origin ? "Start address or place" : "Destination address or place",
                                  text: $search.query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                        if editing == .origin {
                            Button { origin = nil; self.editing = nil } label: {
                                Label("Current Location", systemImage: "location.fill")
                            }
                        }
                        ForEach(search.results, id: \.self) { result in
                            Button { pick(result) } label: {
                                VStack(alignment: .leading) {
                                    Text(result.title).foregroundStyle(.primary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if destination != nil && editing == nil {
                    Section {
                        Button(action: calculate) {
                            HStack {
                                Text(alternatives.isEmpty ? "Calculate Routes" : "Recalculate")
                                if isRouting && progress == nil { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(isRouting)
                    }
                }

                if !alternatives.isEmpty {
                    Section("Choose a route") {
                        Map {
                            ForEach(alternatives.indices, id: \.self) { i in
                                MapPolyline(alternatives[i].polyline)
                                    .stroke(i == selected ? Color.accentColor : .gray.opacity(0.6),
                                            lineWidth: i == selected ? 6 : 3)
                            }
                        }
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())

                        ForEach(alternatives.indices, id: \.self) { i in
                            let r = alternatives[i]
                            Button { selected = i } label: {
                                HStack {
                                    Image(systemName: i == selected ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(r.name.isEmpty ? "Route \(i + 1)" : "via \(r.name)")
                                        Text("\(Format.distance(r.distance, settings.units)) · \(Format.duration(r.expectedTravelTime))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }

                    Section {
                        if let progress {
                            VStack(alignment: .leading) {
                                Text(progress.message).font(.footnote)
                                ProgressView(value: progress.fraction)
                            }
                        } else {
                            Button("Build Nav Log & Save", action: build)
                                .bold()
                                .disabled(isRouting)
                        }
                    } footer: {
                        Text("Waypoints are generated from Apple Maps maneuvers plus OpenStreetMap data: interstate/US/state highway junctions and crossings, and the crossing street nearest each town center.")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { permission.ask() }
            .interactiveDismissDisabled(progress != nil)
        }
    }

    private func placeRow(label: String, value: String, field: Field) -> some View {
        Button {
            search.query = ""
            editing = editing == field ? nil : field
        } label: {
            HStack {
                Text(label).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Text(value).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) {
        let field = editing
        Task {
            do {
                guard let item = try await search.resolve(completion) else { return }
                if item.name == nil { item.name = completion.title }
                if field == .origin { origin = item } else { destination = item }
                editing = nil
                search.query = ""
                alternatives = []
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func calculate() {
        guard let destination else { return }
        isRouting = true
        errorMessage = nil
        Task {
            defer { isRouting = false }
            do {
                alternatives = try await RoutePlanner.routes(
                    from: origin ?? MKMapItem.forCurrentLocation(), to: destination, avoidTolls: avoidTolls
                )
                selected = 0
                if alternatives.isEmpty { errorMessage = "No driving route found." }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func build() {
        guard alternatives.indices.contains(selected) else { return }
        let mkRoute = alternatives[selected]
        isRouting = true
        Task {
            let result = await RoutePlanner.makeSavedRoute(
                from: mkRoute,
                originName: origin?.name ?? "Current Location",
                destinationName: destination?.name ?? "Destination",
                settings: settings
            ) { progress = $0 }
            RouteStore.shared.save(result.route)
            isRouting = false
            progress = nil
            dismiss()
            onCreated(result.route, result.warning)
        }
    }
}
