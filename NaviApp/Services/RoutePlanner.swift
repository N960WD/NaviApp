import Foundation
import MapKit
import NaviCore

/// Computes driving routes with MapKit and turns one into a `SavedRoute` with a nav log.
@MainActor
enum RoutePlanner {
    static func routes(from origin: MKMapItem, to destination: MKMapItem, avoidTolls: Bool) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = origin
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        request.tollPreference = avoidTolls ? .avoid : .any
        let response = try await MKDirections(request: request).calculate()
        return response.routes
    }

    struct Progress {
        var message: String
        var fraction: Double
    }

    /// Builds the nav log: MapKit maneuvers + OpenStreetMap highway crossings and towns.
    /// Map-data failures degrade gracefully to maneuver-only waypoints; `warning` says so.
    static func makeSavedRoute(
        from mkRoute: MKRoute,
        originName: String,
        destinationName: String,
        settings: AppSettings,
        progress: @escaping @MainActor (Progress) -> Void
    ) async -> (route: SavedRoute, warning: String?) {
        let points = mkRoute.polyline.coordinates.map { GeoPoint($0) }
        let path = RoutePath(points: points)
        let maneuvers: [Maneuver] = mkRoute.steps.compactMap { step in
            guard !step.instructions.isEmpty, step.polyline.pointCount > 0,
                  let first = step.polyline.coordinates.first else { return nil }
            return Maneuver(instruction: step.instructions, point: GeoPoint(first))
        }

        var majorRoads: [Int64: RoadGeometry] = [:]
        var places: [Int64: Place] = [:]
        var townStreets: [Int64: RoadGeometry] = [:]
        var warning: String?
        let client = OverpassClient()

        do {
            // 1. Corridor query, in ~150 km chunks to keep each request small.
            let chunks = path.chunks(maxLength: 150_000)
            for (i, chunk) in chunks.enumerated() {
                progress(Progress(message: "Finding highways & towns (\(i + 1)/\(chunks.count))",
                                  fraction: 0.1 + 0.6 * Double(i) / Double(chunks.count)))
                var tolerance = 40.0
                var line = chunk.simplified(tolerance: tolerance)
                while line.count > 350 { tolerance *= 1.5; line = chunk.simplified(tolerance: tolerance) }
                let query = Overpass.corridorQuery(
                    line: line,
                    roadRadius: Int(max(150, tolerance * 2)),
                    includeVillages: settings.includeVillages
                )
                let result = try await client.run(query)
                for r in result.roads { majorRoads[r.id] = r }
                for p in result.places { places[p.id] = p }
            }

            // 2. Local streets around the centers of towns the route drives through.
            let through = places.values.filter {
                (path.project($0.location, maxCrossTrack: .infinity)?.crossTrack ?? .infinity) <= 1_500
            }
            let batches = stride(from: 0, to: through.count, by: 12).map {
                Array(through[$0..<min($0 + 12, through.count)])
            }
            for (i, batch) in batches.enumerated() {
                progress(Progress(message: "Finding town-center crossings (\(i + 1)/\(batches.count))",
                                  fraction: 0.7 + 0.25 * Double(i) / Double(max(batches.count, 1))))
                let result = try await client.run(Overpass.townStreetsQuery(centers: batch.map(\.location)))
                for r in result.roads { townStreets[r.id] = r }
            }
        } catch {
            warning = "\(error.localizedDescription). Showing highway junctions from Apple Maps only — you can add waypoints manually."
        }

        progress(Progress(message: "Building nav log", fraction: 0.97))
        var options = WaypointBuilder.Options()
        options.includeAbeamTowns = settings.includeAbeamTowns
        let waypoints = WaypointBuilder(options: options).build(
            route: path,
            maneuvers: maneuvers,
            majorRoads: Array(majorRoads.values),
            places: Array(places.values),
            townStreets: Array(townStreets.values),
            destinationName: destinationName
        )

        let route = SavedRoute(
            name: "\(originName) → \(destinationName)",
            originName: originName,
            destinationName: destinationName,
            points: path.points,
            expectedTravelTime: mkRoute.expectedTravelTime,
            waypoints: waypoints
        )
        return (route, warning)
    }
}
