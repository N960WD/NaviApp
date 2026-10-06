import Foundation

/// A route polyline with precomputed cumulative distances, supporting along-track
/// projection ("how far along the route am I?") and point lookup by distance.
public struct RoutePath: Sendable {
    public let points: [GeoPoint]
    /// `cumulative[i]` is the distance in meters from the start to `points[i]`.
    public let cumulative: [Double]

    public var length: Double { cumulative.last ?? 0 }
    public var start: GeoPoint? { points.first }
    public var end: GeoPoint? { points.last }

    public init(points raw: [GeoPoint]) {
        // Drop consecutive duplicates; they create zero-length segments.
        var pts: [GeoPoint] = []
        pts.reserveCapacity(raw.count)
        for p in raw where pts.last != p { pts.append(p) }
        points = pts
        var cum: [Double] = [0]
        cum.reserveCapacity(pts.count)
        for i in 1..<max(pts.count, 1) {
            cum.append(cum[i - 1] + Geo.distance(pts[i - 1], pts[i]))
        }
        cumulative = pts.isEmpty ? [] : cum
    }

    /// The point located `distance` meters along the route (clamped to the ends).
    public func point(atDistance distance: Double) -> GeoPoint {
        guard let first = points.first else { return GeoPoint(lat: 0, lon: 0) }
        if distance <= 0 || points.count == 1 { return first }
        if distance >= length { return points[points.count - 1] }
        let i = segmentIndex(containing: distance)
        let segLen = cumulative[i + 1] - cumulative[i]
        let t = segLen > 0 ? (distance - cumulative[i]) / segLen : 0
        return Geo.interpolate(points[i], points[i + 1], t)
    }

    /// Track (bearing) of the route at the given distance along it.
    public func course(atDistance distance: Double) -> Double {
        guard points.count >= 2 else { return 0 }
        let i = segmentIndex(containing: min(max(distance, 0), length))
        return Geo.bearing(points[i], points[i + 1])
    }

    /// Index `i` of the segment `points[i]→points[i+1]` that contains `distance`.
    func segmentIndex(containing distance: Double) -> Int {
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= distance { lo = mid } else { hi = mid }
        }
        return min(lo, max(points.count - 2, 0))
    }

    public struct Projection: Equatable, Sendable {
        /// Distance along the route of the closest point, meters.
        public var distanceAlong: Double
        /// Perpendicular distance from the query point to the route, meters.
        public var crossTrack: Double
        public var segmentIndex: Int
        public var point: GeoPoint
    }

    /// Projects `p` onto the route.
    ///
    /// When `near` is given, only segments within `[near - back, near + ahead]` are searched
    /// first. That keeps progress monotonic on routes that double back on themselves and
    /// keeps per-fix cost low. If nothing within `maxCrossTrack` is found in the window the
    /// whole route is searched.
    public func project(
        _ p: GeoPoint,
        near: Double? = nil,
        back: Double = 1_000,
        ahead: Double = 10_000,
        maxCrossTrack: Double = 300
    ) -> Projection? {
        guard points.count >= 2 else {
            guard let only = points.first else { return nil }
            return Projection(distanceAlong: 0, crossTrack: Geo.distance(only, p), segmentIndex: 0, point: only)
        }
        if let near {
            let lo = segmentIndex(containing: max(0, near - back))
            let hi = segmentIndex(containing: min(length, near + ahead))
            if let best = project(p, segments: lo...hi), best.crossTrack <= maxCrossTrack {
                return best
            }
        }
        return project(p, segments: 0...(points.count - 2))
    }

    private func project(_ p: GeoPoint, segments: ClosedRange<Int>) -> Projection? {
        var best: Projection?
        let frame = LocalFrame(origin: p)
        for i in segments {
            let a = frame.xy(points[i]), b = frame.xy(points[i + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? -(a.x * dx + a.y * dy) / len2 : 0
            t = min(max(t, 0), 1)
            let cx = a.x + t * dx, cy = a.y + t * dy
            let d = (cx * cx + cy * cy).squareRoot()
            if best == nil || d < best!.crossTrack {
                let along = cumulative[i] + t * (cumulative[i + 1] - cumulative[i])
                best = Projection(
                    distanceAlong: along,
                    crossTrack: d,
                    segmentIndex: i,
                    point: Geo.interpolate(points[i], points[i + 1], t)
                )
            }
        }
        return best
    }

    /// Douglas–Peucker simplification, tolerance in meters. Endpoints are always kept.
    public func simplified(tolerance: Double) -> [GeoPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let range = stack.popLast() {
            let (s, e) = range
            guard e > s + 1 else { continue }
            let frame = LocalFrame(origin: points[s])
            let a = frame.xy(points[s]), b = frame.xy(points[e])
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var maxD = -1.0, idx = s
            for i in (s + 1)..<e {
                let c = frame.xy(points[i])
                var t = len2 > 0 ? ((c.x - a.x) * dx + (c.y - a.y) * dy) / len2 : 0
                t = min(max(t, 0), 1)
                let px = a.x + t * dx - c.x, py = a.y + t * dy - c.y
                let d = (px * px + py * py).squareRoot()
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    /// Splits the route into consecutive chunks of roughly `maxLength` meters (each chunk
    /// shares its boundary point with the next). Used to keep map-data queries small.
    public func chunks(maxLength: Double) -> [RoutePath] {
        guard points.count >= 2, length > maxLength else { return [self] }
        var result: [RoutePath] = []
        var startIdx = 0
        for i in 1..<points.count {
            if cumulative[i] - cumulative[startIdx] >= maxLength || i == points.count - 1 {
                result.append(RoutePath(points: Array(points[startIdx...i])))
                startIdx = i
            }
        }
        return result
    }
}
