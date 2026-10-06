import Foundation

/// A WGS-84 latitude/longitude pair in degrees. Kept independent of CoreLocation so the
/// navigation math can be unit tested anywhere.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public enum Geo {
    /// Mean Earth radius (IUGG) in meters.
    public static let earthRadius = 6_371_008.8

    static func rad(_ deg: Double) -> Double { deg * .pi / 180 }
    static func deg(_ rad: Double) -> Double { rad * 180 / .pi }

    /// Great-circle distance in meters (haversine).
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = rad(b.lat - a.lat)
        let dLon = rad(b.lon - a.lon)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.lat)) * cos(rad(b.lat)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial true course from `a` to `b`, degrees 0..<360.
    public static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let φ1 = rad(a.lat), φ2 = rad(b.lat)
        let Δλ = rad(b.lon - a.lon)
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let θ = deg(atan2(y, x))
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Linear interpolation between two nearby points.
    public static func interpolate(_ a: GeoPoint, _ b: GeoPoint, _ t: Double) -> GeoPoint {
        GeoPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
    }

    /// Smallest angle between two undirected lines with the given bearings, 0...90.
    public static func crossingAngle(_ b1: Double, _ b2: Double) -> Double {
        var d = abs(b1 - b2).truncatingRemainder(dividingBy: 180)
        if d > 90 { d = 180 - d }
        return d
    }
}

/// Local flat-earth (equirectangular) frame. Accurate to well under a meter over the few
/// kilometers spanned by a single route or road segment, which is all it is used for.
struct LocalFrame {
    let origin: GeoPoint
    let kx: Double
    let ky: Double

    init(origin: GeoPoint) {
        self.origin = origin
        ky = Geo.earthRadius * .pi / 180
        kx = ky * cos(Geo.rad(origin.lat))
    }

    func xy(_ p: GeoPoint) -> (x: Double, y: Double) {
        var dLon = p.lon - origin.lon
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        return (dLon * kx, (p.lat - origin.lat) * ky)
    }
}

/// Result of intersecting two line segments `p1→p2` and `q1→q2`.
/// `t` and `u` are the fractional positions along each segment.
func segmentIntersection(
    _ p1: (x: Double, y: Double), _ p2: (x: Double, y: Double),
    _ q1: (x: Double, y: Double), _ q2: (x: Double, y: Double)
) -> (t: Double, u: Double)? {
    let rx = p2.x - p1.x, ry = p2.y - p1.y
    let sx = q2.x - q1.x, sy = q2.y - q1.y
    let denom = rx * sy - ry * sx
    if abs(denom) < 1e-9 { return nil } // parallel / collinear: never a crossing
    let qpx = q1.x - p1.x, qpy = q1.y - p1.y
    let t = (qpx * sy - qpy * sx) / denom
    let u = (qpx * ry - qpy * rx) / denom
    let eps = 1e-9
    guard t >= -eps, t <= 1 + eps, u >= -eps, u <= 1 + eps else { return nil }
    return (min(max(t, 0), 1), min(max(u, 0), 1))
}
