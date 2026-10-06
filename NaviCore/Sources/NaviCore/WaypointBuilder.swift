import Foundation

/// A turn-by-turn step from the routing engine (e.g. an `MKRoute.Step`).
public struct Maneuver: Sendable, Hashable {
    public var instruction: String
    /// Where the maneuver happens (start of the step).
    public var point: GeoPoint

    public init(instruction: String, point: GeoPoint) {
        self.instruction = instruction
        self.point = point
    }
}

/// Turns raw map data into a nav log of checkpoints along the route.
public struct WaypointBuilder {
    public struct Options: Sendable {
        /// Waypoints closer together than this are merged into one.
        public var mergeDistance: Double = 400
        /// A town whose center is within this distance of the route is "driven through".
        public var throughTownDistance: Double = 1_500
        /// Towns farther than `throughTownDistance` but within this get an "abeam" point.
        public var abeamDistance: Double = 4_000
        public var includeAbeamTowns: Bool = true
        /// Max distance from a town center for its crossing street to count.
        public var townCrossingRadius: Double = 1_500
        public var minCrossingAngle: Double = 25

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func build(
        route: RoutePath,
        maneuvers: [Maneuver],
        majorRoads: [RoadGeometry],
        places: [Place],
        townStreets: [RoadGeometry],
        destinationName: String
    ) -> [Waypoint] {
        guard route.points.count >= 2, let end = route.end else { return [] }
        var candidates: [Waypoint] = []

        // 1. Junctions where the route turns onto / exits to a numbered highway.
        var lastRef: String?
        for m in maneuvers {
            guard let ref = Self.highwayRef(in: m.instruction),
                  let proj = route.project(m.point, maxCrossTrack: 500) else { continue }
            defer { lastRef = ref }
            if ref == lastRef { continue } // "Keep left to stay on I-80"
            candidates.append(Waypoint(
                name: ref,
                detail: m.instruction,
                kind: .highwayJunction,
                coordinate: proj.point,
                distanceAlong: proj.distanceAlong
            ))
        }

        // 2. Numbered highways crossing the route.
        let numbered = majorRoads.filter { $0.ref != nil || $0.highway.rank <= HighwayClass.trunk.rank }
        let highwayCrossings = CrossingFinder.crossings(route: route, roads: numbered, minAngle: options.minCrossingAngle)
        let sortedPlaces = places.sorted { $0.type.rank < $1.type.rank }
        for c in highwayCrossings {
            guard let label = c.road.label else { continue }
            var detail = "\(c.road.highway.rawValue.capitalized) crossing"
            if let town = nearestPlace(to: c.point, in: sortedPlaces, within: 8_000) {
                detail += " near \(town.name)"
            }
            candidates.append(Waypoint(
                name: label,
                detail: detail,
                kind: .highwayCrossing,
                coordinate: c.point,
                distanceAlong: c.distanceAlong
            ))
        }

        // 3. Towns: the crossing street nearest the center, or an abeam point.
        let townCrossings = CrossingFinder.crossings(
            route: route, roads: townStreets + majorRoads, minAngle: options.minCrossingAngle
        )
        var seenTowns = Set<String>()
        for place in sortedPlaces {
            guard !seenTowns.contains(place.name),
                  let proj = route.project(place.location, maxCrossTrack: .infinity) else { continue }
            if proj.crossTrack <= options.throughTownDistance {
                seenTowns.insert(place.name)
                let best = townCrossings
                    .map { ($0, Geo.distance($0.point, place.location)) }
                    .filter { $0.1 <= options.townCrossingRadius }
                    .min { $0.1 < $1.1 }
                if let crossing = best?.0 {
                    candidates.append(Waypoint(
                        name: place.name,
                        detail: "\(crossing.road.label ?? "Cross street") · \(place.type.rawValue) center",
                        kind: .townCenter,
                        coordinate: crossing.point,
                        distanceAlong: crossing.distanceAlong
                    ))
                } else {
                    candidates.append(Waypoint(
                        name: place.name,
                        detail: "Closest point to \(place.type.rawValue) center",
                        kind: .townCenter,
                        coordinate: proj.point,
                        distanceAlong: proj.distanceAlong
                    ))
                }
            } else if options.includeAbeamTowns, proj.crossTrack <= options.abeamDistance, place.type != .village {
                seenTowns.insert(place.name)
                candidates.append(Waypoint(
                    name: "Abeam \(place.name)",
                    detail: String(format: "%.1f mi (%.1f km) ", proj.crossTrack / 1609.344, proj.crossTrack / 1000)
                        + side(of: place.location, route: route, at: proj.distanceAlong),
                    kind: .abeamTown,
                    coordinate: proj.point,
                    distanceAlong: proj.distanceAlong
                ))
            }
        }

        // 4. Destination.
        let destination = Waypoint(
            name: destinationName,
            detail: "Destination",
            kind: .destination,
            coordinate: end,
            distanceAlong: route.length
        )

        // Drop anything within merge distance of the start or end; they are the start/destination.
        candidates = candidates.filter {
            $0.distanceAlong > options.mergeDistance / 2 && $0.distanceAlong < route.length - options.mergeDistance
        }
        return Self.merge(candidates + [destination], within: options.mergeDistance)
    }

    /// Collapses waypoints that are close together, keeping the most significant one and
    /// noting the others in its detail text.
    static func merge(_ waypoints: [Waypoint], within distance: Double) -> [Waypoint] {
        let sorted = waypoints.sorted { $0.distanceAlong < $1.distanceAlong }
        var out: [Waypoint] = []
        for wp in sorted {
            guard var last = out.last, wp.distanceAlong - last.distanceAlong < distance else {
                out.append(wp)
                continue
            }
            var keep = priority(wp) > priority(last) ? wp : last
            let other = keep.id == wp.id ? last : wp
            if other.name != keep.name, !(keep.detail ?? "").contains(other.name) {
                keep.detail = [keep.detail, other.name].compactMap { $0 }.joined(separator: " · ")
            }
            last = keep
            out[out.count - 1] = last
        }
        return out
    }

    static func priority(_ wp: Waypoint) -> Int {
        switch wp.kind {
        case .destination: 100
        case .custom: 90
        case .highwayJunction: 80
        case .highwayCrossing: wp.name.hasPrefix("I-") ? 75 : 60
        case .townCenter: 70
        case .abeamTown: 40
        }
    }

    func nearestPlace(to p: GeoPoint, in places: [Place], within: Double) -> Place? {
        places
            .map { ($0, Geo.distance($0.location, p)) }
            .filter { $0.1 <= within }
            .min { $0.1 < $1.1 }?.0
    }

    func side(of p: GeoPoint, route: RoutePath, at distance: Double) -> String {
        let course = route.course(atDistance: distance)
        let toPlace = Geo.bearing(route.point(atDistance: distance), p)
        let rel = (toPlace - course + 360).truncatingRemainder(dividingBy: 360)
        return rel < 180 ? "right" : "left"
    }

    // MARK: Highway reference parsing

    private static let refRegex = try! NSRegularExpression(
        pattern: #"\b(?:I-\d+[A-Z]?|US-\d+[A-Z]?|[A-Z]{2}-\d+[A-Z]?|(?:Interstate|State Route|State Highway|SR|Route|Hwy|Highway|US Highway|County Road|CR)[- ]\d+[A-Z]?)(?:\s[NSEW]\b)?"#
    )

    /// Extracts the first highway reference from a driving instruction, e.g.
    /// "Take exit 52B onto I-80 E toward Sacramento" → "I-80 E".
    public static func highwayRef(in instruction: String) -> String? {
        let range = NSRange(instruction.startIndex..., in: instruction)
        guard let match = refRegex.firstMatch(in: instruction, range: range),
              let r = Range(match.range, in: instruction) else { return nil }
        return String(instruction[r])
    }
}
