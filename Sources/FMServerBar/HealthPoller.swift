import Foundation

struct ModelHealth: Codable, Equatable {
    let name: String
    let available: Bool
    let reason: String?
}

struct Health: Codable, Equatable {
    let status: String
    let models: [ModelHealth]

    func model(named name: String) -> ModelHealth? { models.first { $0.name == name } }
    var systemAvailable: Bool { model(named: "system")?.available ?? false }
}

enum HealthPoller {
    /// GET http://127.0.0.1:<port>/health with a short timeout. Returns nil on any failure.
    static func poll(port: Int) async -> Health? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Health.self, from: data)
        } catch {
            return nil
        }
    }
}
