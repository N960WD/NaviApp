import Foundation
import NaviCore

/// Minimal client for the public OpenStreetMap Overpass API.
struct OverpassClient {
    enum OverpassError: LocalizedError {
        case http(Int)
        case allEndpointsFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .http(let code): "Map data server returned HTTP \(code)"
            case .allEndpointsFailed(let e): "Map data unavailable: \(e?.localizedDescription ?? "unknown error")"
            }
        }
    }

    var endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
    ]

    func run(_ query: String) async throws -> Overpass.Result {
        var lastError: Error?
        for endpoint in endpoints {
            for attempt in 0..<2 {
                do {
                    return try await fetch(query, from: endpoint)
                } catch {
                    lastError = error
                    // Back off briefly on rate limiting / gateway timeouts.
                    try await Task.sleep(nanoseconds: UInt64(2 + attempt * 3) * 1_000_000_000)
                }
            }
        }
        throw OverpassError.allEndpointsFailed(lastError)
    }

    private func fetch(_ query: String, from endpoint: URL) async throws -> Overpass.Result {
        var request = URLRequest(url: endpoint, timeoutInterval: 150)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("NaviApp/1.0 (route timing research app)", forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        request.httpBody = Data("data=\(encoded)".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OverpassError.http(http.statusCode)
        }
        return try Overpass.parse(data)
    }
}
