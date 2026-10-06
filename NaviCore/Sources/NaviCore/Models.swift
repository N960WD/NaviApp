import Foundation

public enum WaypointKind: String, Codable, CaseIterable, Sendable {
    case highwayJunction   // route turns onto / exits to a numbered highway
    case highwayCrossing   // a numbered highway crosses the route
    case townCenter        // road crossing nearest a city/town center
    case abeamTown         // closest point of approach to a town not driven through
    case custom            // user-defined
    case destination

    public var label: String {
        switch self {
        case .highwayJunction: "Junction"
        case .highwayCrossing: "Crossing"
        case .townCenter: "Town"
        case .abeamTown: "Abeam"
        case .custom: "Custom"
        case .destination: "Destination"
        }
    }

    public var symbolName: String {
        switch self {
        case .highwayJunction: "arrow.triangle.branch"
        case .highwayCrossing: "plus"
        case .townCenter: "building.2"
        case .abeamTown: "arrow.left.and.right"
        case .custom: "mappin"
        case .destination: "flag.checkered"
        }
    }
}

public struct Waypoint: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var detail: String?
    public var kind: WaypointKind
    public var coordinate: GeoPoint
    /// Distance from the route start, meters.
    public var distanceAlong: Double
    /// User-entered time the vehicle must cross this point.
    public var requiredTime: Date?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        detail: String? = nil,
        kind: WaypointKind,
        coordinate: GeoPoint,
        distanceAlong: Double,
        requiredTime: Date? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.kind = kind
        self.coordinate = coordinate
        self.distanceAlong = distanceAlong
        self.requiredTime = requiredTime
        self.isEnabled = isEnabled
    }
}

/// A route the user has planned and saved: geometry plus its nav log.
public struct SavedRoute: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var originName: String
    public var destinationName: String
    public var createdAt: Date
    public var points: [GeoPoint]
    /// Travel time predicted by the routing engine, seconds.
    public var expectedTravelTime: TimeInterval
    /// Optional user override for planning speed, m/s.
    public var plannedSpeedOverride: Double?
    public var waypoints: [Waypoint]

    public init(
        id: UUID = UUID(),
        name: String,
        originName: String,
        destinationName: String,
        createdAt: Date = Date(),
        points: [GeoPoint],
        expectedTravelTime: TimeInterval,
        plannedSpeedOverride: Double? = nil,
        waypoints: [Waypoint]
    ) {
        self.id = id
        self.name = name
        self.originName = originName
        self.destinationName = destinationName
        self.createdAt = createdAt
        self.points = points
        self.expectedTravelTime = expectedTravelTime
        self.plannedSpeedOverride = plannedSpeedOverride
        self.waypoints = waypoints
    }

    public var path: RoutePath { RoutePath(points: points) }

    /// Planning speed: the user's override, else the routing engine's average.
    public var plannedSpeed: Double { plannedSpeed(routeLength: path.length) }

    /// Planning speed given an already-known route length (avoids rebuilding the path).
    public func plannedSpeed(routeLength: Double) -> Double {
        if let plannedSpeedOverride, plannedSpeedOverride > 0 { return plannedSpeedOverride }
        guard expectedTravelTime > 0, routeLength > 0 else { return 25 } // ~56 mph fallback
        return routeLength / expectedTravelTime
    }

    /// Enabled waypoints, ordered along the route.
    public var activeWaypoints: [Waypoint] {
        waypoints.filter(\.isEnabled).sorted { $0.distanceAlong < $1.distanceAlong }
    }
}
