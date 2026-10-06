import Foundation
import NaviCore

/// Saved routes, persisted as JSON in the app's Documents directory.
@MainActor
final class RouteStore: ObservableObject {
    static let shared = RouteStore()

    @Published private(set) var routes: [SavedRoute] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("routes.json")
    }()

    private init() {
        load()
    }

    func route(id: UUID) -> SavedRoute? {
        routes.first { $0.id == id }
    }

    func save(_ route: SavedRoute) {
        if let i = routes.firstIndex(where: { $0.id == route.id }) {
            routes[i] = route
        } else {
            routes.insert(route, at: 0)
        }
        persist()
    }

    func delete(at offsets: IndexSet) {
        routes.remove(atOffsets: offsets)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        routes = (try? decoder.decode([SavedRoute].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(routes).write(to: url, options: .atomic)
        } catch {
            print("RouteStore: failed to save routes: \(error)")
        }
    }
}
