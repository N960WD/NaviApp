import Foundation

/// One GPS position report.
public struct LocationFix: Sendable, Equatable {
    public var time: Date
    public var point: GeoPoint
    /// Ground speed in m/s, nil when the receiver did not report a valid speed.
    public var speed: Double?
    /// Horizontal accuracy radius in meters.
    public var horizontalAccuracy: Double

    public init(time: Date, point: GeoPoint, speed: Double?, horizontalAccuracy: Double = 5) {
        self.time = time
        self.point = point
        self.speed = speed
        self.horizontalAccuracy = horizontalAccuracy
    }
}

/// Which speed is used to project ETAs.
public enum ETABasis: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Average speed since start (falls back to planned until there is enough data).
    case average
    /// Instantaneous ground speed.
    case current
    /// The route's planned cruise speed.
    case planned

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .average: "Average"
        case .current: "Current"
        case .planned: "Planned"
        }
    }
}

public struct WaypointStatus: Identifiable, Sendable {
    public var id: UUID { waypoint.id }
    public var waypoint: Waypoint
    /// Distance from the current position along the route; negative once passed.
    public var distanceToGo: Double
    /// Estimated time en route from now (ETE), nil once passed.
    public var timeToGo: TimeInterval?
    /// Estimated time of arrival / crossing.
    public var eta: Date?
    /// Actual time the waypoint was crossed (ATA), if crossed while tracking.
    public var actualTime: Date?
    /// Speed needed from the current position to cross exactly at `requiredTime`.
    public var requiredSpeed: Double?
    /// Speed needed over the leg from the previous timed waypoint (or the current
    /// position) to this one, assuming every earlier required time is met exactly.
    public var legSpeed: Double?
    /// True when the required time can no longer be met (it is already past).
    public var isUnable: Bool
    /// `eta - requiredTime` before crossing, `ata - requiredTime` after. Positive = late.
    public var delta: TimeInterval?
    public var isPassed: Bool
}

public struct NavSnapshot: Sendable {
    public var now: Date
    public var startTime: Date?
    public var finishTime: Date?
    public var elapsed: TimeInterval
    public var distanceAlong: Double
    public var distanceRemaining: Double
    public var routeLength: Double
    public var crossTrack: Double
    public var isOffRoute: Bool
    public var hasFix: Bool
    /// Last reported position.
    public var position: GeoPoint?
    public var currentSpeed: Double?
    public var averageSpeed: Double?
    public var maxSpeed: Double
    public var plannedSpeed: Double
    /// The speed actually used to project ETAs.
    public var projectionSpeed: Double
    public var etaBasis: ETABasis
    public var waypoints: [WaypointStatus]
    public var nextIndex: Int?
    public var destinationETA: Date?
    /// Required speed to cross the next timed waypoint exactly on time.
    public var targetSpeed: Double?
    public var targetWaypointID: UUID?

    public var isRunning: Bool { startTime != nil && finishTime == nil }
    public var next: WaypointStatus? { nextIndex.map { waypoints[$0] } }
    public var target: WaypointStatus? { waypoints.first { $0.id == targetWaypointID } }
    public var progress: Double { routeLength > 0 ? min(max(distanceAlong / routeLength, 0), 1) : 0 }
}

/// Platform-independent navigation state machine: feed it GPS fixes, ask it for snapshots.
public struct TrackingEngine: Sendable {
    public private(set) var route: SavedRoute
    public private(set) var path: RoutePath
    public var etaBasis: ETABasis = .average
    /// Minimum elapsed time before the average-speed basis is trusted.
    public var averageWarmup: TimeInterval = 60
    public var offRouteThreshold: Double = 250
    /// Distance from the destination at which the trip is considered complete.
    public var arrivalRadius: Double = 75

    public private(set) var startTime: Date?
    public private(set) var finishTime: Date?
    public private(set) var distanceAlong: Double = 0
    public private(set) var crossTrack: Double = 0
    public private(set) var lastFix: LocationFix?
    public private(set) var currentSpeed: Double?
    public private(set) var maxSpeed: Double = 0
    public private(set) var passages: [UUID: Date] = [:]
    private var startDistance: Double = 0
    private var hasPosition = false

    public init(route: SavedRoute) {
        self.route = route
        self.path = route.path
    }

    public var isRunning: Bool { startTime != nil && finishTime == nil }

    /// Replace the route definition (e.g. after editing required times) keeping progress.
    public mutating func update(route newRoute: SavedRoute) {
        if newRoute.points != route.points { path = newRoute.path }
        route = newRoute
    }

    public mutating func start(at time: Date) {
        startTime = time
        finishTime = nil
        passages = [:]
        maxSpeed = 0
        startDistance = hasPosition ? distanceAlong : 0
        if !hasPosition { distanceAlong = 0 }
    }

    public mutating func stop(at time: Date) {
        if isRunning { finishTime = time }
    }

    public mutating func reset() {
        startTime = nil
        finishTime = nil
        passages = [:]
        maxSpeed = 0
        startDistance = 0
    }

    public mutating func ingest(_ fix: LocationFix) {
        // Ground speed: receiver-reported if valid, else derived from the previous fix.
        var speed = fix.speed.flatMap { $0 >= 0 ? $0 : nil }
        if speed == nil, let last = lastFix {
            let dt = fix.time.timeIntervalSince(last.time)
            if dt > 0.5 { speed = Geo.distance(last.point, fix.point) / dt }
        }
        currentSpeed = speed
        if isRunning, let speed { maxSpeed = max(maxSpeed, speed) }

        // Along-track position, searched near the previous position so progress is stable.
        let dt = lastFix.map { max(fix.time.timeIntervalSince($0.time), 1) } ?? 1
        let ahead = max(2_000, (speed ?? 40) * dt * 3)
        let hint: Double? = hasPosition ? distanceAlong : nil
        if let proj = path.project(fix.point, near: hint, back: 500, ahead: ahead, maxCrossTrack: offRouteThreshold) {
            let previous = distanceAlong
            let previousTime = lastFix?.time ?? fix.time
            crossTrack = proj.crossTrack
            if isRunning && hasPosition && proj.distanceAlong > previous {
                recordPassages(from: previous, at: previousTime, to: proj.distanceAlong, at: fix.time)
            }
            distanceAlong = proj.distanceAlong
            // Started before the first fix arrived: average speed counts from here.
            if !hasPosition && startTime != nil { startDistance = proj.distanceAlong }
            hasPosition = true
        }
        lastFix = fix

        if isRunning, path.length - distanceAlong <= arrivalRadius, crossTrack <= offRouteThreshold {
            finishTime = passages[route.activeWaypoints.last?.id ?? UUID()] ?? fix.time
        }
    }

    /// Records the interpolated crossing time of every waypoint between two positions.
    private mutating func recordPassages(from d0: Double, at t0: Date, to d1: Double, at t1: Date) {
        let span = d1 - d0
        let dt = t1.timeIntervalSince(t0)
        for wp in route.activeWaypoints where passages[wp.id] == nil {
            // The destination counts as crossed on entering the arrival radius.
            let target = wp.kind == .destination ? max(wp.distanceAlong - arrivalRadius, 0) : wp.distanceAlong
            guard target > d0, target <= d1 else { continue }
            let frac = span > 0 ? (target - d0) / span : 1
            let crossed = t0.addingTimeInterval(dt * frac)
            passages[wp.id] = startTime.map { max(crossed, $0) } ?? crossed
        }
    }

    public func averageSpeed(at now: Date) -> Double? {
        guard let startTime else { return nil }
        let end = finishTime ?? now
        let elapsed = end.timeIntervalSince(startTime)
        guard elapsed >= 5 else { return nil }
        return max(distanceAlong - startDistance, 0) / elapsed
    }

    public func projectionSpeed(at now: Date) -> Double {
        let planned = route.plannedSpeed(routeLength: path.length)
        let elapsed = startTime.map { now.timeIntervalSince($0) } ?? 0
        let average = averageSpeed(at: now).flatMap { elapsed >= averageWarmup && $0 > 0.5 ? $0 : nil }
        switch etaBasis {
        case .planned:
            return planned
        case .average:
            return average ?? planned
        case .current:
            if let currentSpeed, currentSpeed > 0.5 { return currentSpeed }
            return average ?? planned
        }
    }

    public func snapshot(at now: Date) -> NavSnapshot {
        let speed = max(projectionSpeed(at: now), 0.1)
        let finished = finishTime != nil
        let waypoints = route.activeWaypoints

        var statuses: [WaypointStatus] = []
        statuses.reserveCapacity(waypoints.count)
        // Previous timing constraint for leg-speed computation: starts at the current position.
        var prevConstraint = (distance: distanceAlong, time: now)
        var prevConstraintUnable = false
        var targetID: UUID?
        var targetSpeed: Double?
        var nextIndex: Int?

        for wp in waypoints {
            let dtg = wp.distanceAlong - distanceAlong
            let ata = passages[wp.id]
            let passed = ata != nil || finished || (wp.kind == .destination ? dtg <= arrivalRadius && startTime != nil : dtg <= 0)
            var st = WaypointStatus(
                waypoint: wp, distanceToGo: dtg, timeToGo: nil, eta: nil, actualTime: ata,
                requiredSpeed: nil, legSpeed: nil, isUnable: false, delta: nil, isPassed: passed
            )
            if passed {
                if let ata, let req = wp.requiredTime { st.delta = ata.timeIntervalSince(req) }
            } else {
                if nextIndex == nil { nextIndex = statuses.count }
                let ete = dtg / speed
                st.timeToGo = ete
                st.eta = now.addingTimeInterval(ete)
                if let req = wp.requiredTime {
                    let available = req.timeIntervalSince(now)
                    st.delta = st.eta!.timeIntervalSince(req)
                    if available > 0 {
                        st.requiredSpeed = dtg / available
                    } else {
                        st.isUnable = true
                    }
                    let legTime = req.timeIntervalSince(prevConstraint.time)
                    let legDist = wp.distanceAlong - prevConstraint.distance
                    if legTime > 0, !prevConstraintUnable {
                        st.legSpeed = legDist / legTime
                    }
                    prevConstraintUnable = legTime <= 0
                    prevConstraint = (wp.distanceAlong, req)
                    if targetID == nil {
                        targetID = wp.id
                        targetSpeed = st.requiredSpeed
                    }
                }
            }
            statuses.append(st)
        }

        let remaining = max(path.length - distanceAlong, 0)
        let elapsed = startTime.map { (finishTime ?? now).timeIntervalSince($0) } ?? 0
        return NavSnapshot(
            now: now,
            startTime: startTime,
            finishTime: finishTime,
            elapsed: elapsed,
            distanceAlong: distanceAlong,
            distanceRemaining: remaining,
            routeLength: path.length,
            crossTrack: crossTrack,
            isOffRoute: hasPosition && crossTrack > offRouteThreshold,
            hasFix: lastFix != nil,
            position: lastFix?.point,
            currentSpeed: currentSpeed,
            averageSpeed: averageSpeed(at: now),
            maxSpeed: maxSpeed,
            plannedSpeed: route.plannedSpeed(routeLength: path.length),
            projectionSpeed: speed,
            etaBasis: etaBasis,
            waypoints: statuses,
            nextIndex: nextIndex,
            destinationETA: finished ? finishTime : now.addingTimeInterval(remaining / speed),
            targetSpeed: targetSpeed,
            targetWaypointID: targetID
        )
    }
}
