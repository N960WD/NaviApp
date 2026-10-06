import Foundation

/// Builds OpenStreetMap Overpass API queries and parses their JSON responses.
/// Networking lives in the app; this file is pure so it can be tested offline.
public enum Overpass {
    /// Major numbered roads near the route plus the cities/towns it passes.
    public static func corridorQuery(
        line: [GeoPoint],
        roadRadius: Int = 150,
        placeRadius: Int = 4_000,
        includeVillages: Bool = false
    ) -> String {
        let poly = polyline(line)
        let places = includeVillages ? "city|town|village" : "city|town"
        return """
        [out:json][timeout:120];
        (
          way["highway"~"^(motorway|trunk|primary)$"](around:\(roadRadius),\(poly));
          way["highway"="secondary"]["ref"](around:\(roadRadius),\(poly));
          node["place"~"^(\(places))$"]["name"](around:\(placeRadius),\(poly));
        );
        out geom;
        """
    }

    /// Named local streets around town centers, used to find the crossing street
    /// closest to the middle of each town the route drives through.
    public static func townStreetsQuery(centers: [GeoPoint], radius: Int = 1_500) -> String {
        let parts = centers.map {
            "  way[\"highway\"~\"^(primary|secondary|tertiary|unclassified|residential)$\"][\"name\"](around:\(radius),\(fmt($0.lat)),\(fmt($0.lon)));"
        }
        return """
        [out:json][timeout:120];
        (
        \(parts.joined(separator: "\n"))
        );
        out geom;
        """
    }

    static func polyline(_ pts: [GeoPoint]) -> String {
        pts.map { "\(fmt($0.lat)),\(fmt($0.lon))" }.joined(separator: ",")
    }

    static func fmt(_ v: Double) -> String { String(format: "%.5f", v) }

    // MARK: Response

    struct Response: Decodable {
        let elements: [Element]
    }

    struct Element: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let tags: [String: String]?
        let geometry: [LatLon?]?
    }

    struct LatLon: Decodable {
        let lat: Double
        let lon: Double
    }

    public struct Result: Sendable {
        public var roads: [RoadGeometry] = []
        public var places: [Place] = []
    }

    public static func parse(_ data: Data) throws -> Result {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var result = Result()
        for el in response.elements {
            let tags = el.tags ?? [:]
            switch el.type {
            case "way":
                guard let hw = tags["highway"].flatMap(HighwayClass.init(rawValue:)),
                      let geom = el.geometry else { continue }
                let pts = geom.compactMap { $0.map { GeoPoint(lat: $0.lat, lon: $0.lon) } }
                guard pts.count >= 2 else { continue }
                result.roads.append(RoadGeometry(id: el.id, name: tags["name"], ref: tags["ref"], highway: hw, points: pts))
            case "node":
                guard let lat = el.lat, let lon = el.lon, let name = tags["name"],
                      let type = tags["place"].flatMap(PlaceType.init(rawValue:)) else { continue }
                result.places.append(Place(id: el.id, name: name, type: type, location: GeoPoint(lat: lat, lon: lon)))
            default:
                continue
            }
        }
        return result
    }
}
