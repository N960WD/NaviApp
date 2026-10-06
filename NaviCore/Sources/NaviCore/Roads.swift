import Foundation

/// OpenStreetMap highway classification, most to least important.
public enum HighwayClass: String, Codable, Sendable, CaseIterable {
    case motorway, trunk, primary, secondary, tertiary, unclassified, residential

    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    public var isMajor: Bool { rank <= HighwayClass.secondary.rank }
}

public struct RoadGeometry: Sendable, Hashable {
    public var id: Int64
    public var name: String?
    public var ref: String?
    public var highway: HighwayClass
    public var points: [GeoPoint]

    public init(id: Int64, name: String?, ref: String?, highway: HighwayClass, points: [GeoPoint]) {
        self.id = id
        self.name = name
        self.ref = ref
        self.highway = highway
        self.points = points
    }

    /// Human label, preferring route numbers: "I 80 / US 50", else the street name.
    public var label: String? {
        if let ref, !ref.isEmpty {
            return ref.split(separator: ";")
                .map { RoadGeometry.normalizeRef(String($0).trimmingCharacters(in: .whitespaces)) }
                .joined(separator: " / ")
        }
        return name
    }

    /// Normalizes OSM refs to the familiar US style: "I 80" → "I-80", "US 50" → "US-50".
    public static func normalizeRef(_ ref: String) -> String {
        let parts = ref.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].count <= 4, parts[1].first?.isNumber == true else { return ref }
        return "\(parts[0])-\(parts[1])"
    }
}

public enum PlaceType: String, Codable, Sendable {
    case city, town, village

    public var rank: Int {
        switch self {
        case .city: 0
        case .town: 1
        case .village: 2
        }
    }
}

public struct Place: Sendable, Hashable {
    public var id: Int64
    public var name: String
    public var type: PlaceType
    public var location: GeoPoint

    public init(id: Int64, name: String, type: PlaceType, location: GeoPoint) {
        self.id = id
        self.name = name
        self.type = type
        self.location = location
    }
}

public struct RouteCrossing: Sendable, Hashable {
    public var road: RoadGeometry
    public var distanceAlong: Double
    public var point: GeoPoint
    /// Angle between route and road at the crossing, 0...90 degrees.
    public var angle: Double
}

public enum CrossingFinder {
    /// Finds every place where one of `roads` crosses the route at an angle of at least
    /// `minAngle` degrees. Shallow-angle hits are rejected: they are almost always the road
    /// the route is itself driving on, offset slightly between map data sources.
    public static func crossings(
        route: RoutePath,
        roads: [RoadGeometry],
        minAngle: Double = 25
    ) -> [RouteCrossing] {
        let pts = route.points
        guard pts.count >= 2 else { return [] }

        // Bucket route segments into a coarse lat/lon grid so each road segment is only
        // tested against nearby route segments.
        let cell = 0.01 // degrees, ~1.1 km of latitude
        struct Key: Hashable { let x: Int; let y: Int }
        func key(_ lat: Double, _ lon: Double) -> Key {
            Key(x: Int((lon / cell).rounded(.down)), y: Int((lat / cell).rounded(.down)))
        }
        var grid: [Key: [Int]] = [:]
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let k1 = key(min(a.lat, b.lat), min(a.lon, b.lon))
            let k2 = key(max(a.lat, b.lat), max(a.lon, b.lon))
            for x in k1.x...k2.x { for y in k1.y...k2.y { grid[Key(x: x, y: y), default: []].append(i) } }
        }

        var result: [RouteCrossing] = []
        for road in roads where road.points.count >= 2 {
            for j in 0..<(road.points.count - 1) {
                let c = road.points[j], d = road.points[j + 1]
                let k1 = key(min(c.lat, d.lat), min(c.lon, d.lon))
                let k2 = key(max(c.lat, d.lat), max(c.lon, d.lon))
                var candidates = Set<Int>()
                for x in k1.x...k2.x { for y in k1.y...k2.y { candidates.formUnion(grid[Key(x: x, y: y)] ?? []) } }
                for i in candidates {
                    let a = pts[i], b = pts[i + 1]
                    let frame = LocalFrame(origin: a)
                    guard let hit = segmentIntersection(frame.xy(a), frame.xy(b), frame.xy(c), frame.xy(d)) else { continue }
                    let angle = Geo.crossingAngle(Geo.bearing(a, b), Geo.bearing(c, d))
                    guard angle >= minAngle else { continue }
                    let along = route.cumulative[i] + hit.t * (route.cumulative[i + 1] - route.cumulative[i])
                    result.append(RouteCrossing(
                        road: road,
                        distanceAlong: along,
                        point: Geo.interpolate(a, b, hit.t),
                        angle: angle
                    ))
                }
            }
        }
        result.sort { $0.distanceAlong < $1.distanceAlong }
        return mergeDuplicates(result)
    }

    /// Divided highways are mapped as two one-way ways and a road can be split into many
    /// ways, so the same road shows up several times within a short distance. Keep one.
    static func mergeDuplicates(_ crossings: [RouteCrossing], within: Double = 600) -> [RouteCrossing] {
        var out: [RouteCrossing] = []
        for c in crossings {
            let label = c.road.label ?? "#\(c.road.id)"
            if let idx = out.lastIndex(where: {
                ($0.road.label ?? "#\($0.road.id)") == label && c.distanceAlong - $0.distanceAlong < within
            }) {
                // Keep the first crossing but upgrade class if the duplicate ranks higher.
                if c.road.highway.rank < out[idx].road.highway.rank { out[idx].road.highway = c.road.highway }
                continue
            }
            out.append(c)
        }
        return out
    }
}
