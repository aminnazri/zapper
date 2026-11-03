import Foundation
import ATVKit

/// Saved devices, persisted as JSON in Application Support.
final class DeviceStore {

    private let url: URL

    init() {
        self.url = AppSupport.directory.appendingPathComponent("devices.json")
    }

    func load() -> [Device] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Device].self, from: data)) ?? []
    }

    func save(_ devices: [Device]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
