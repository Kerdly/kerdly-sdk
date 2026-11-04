import Foundation

/// Reads and writes the SDK's three JSON files through `FileStoring` (atomic writes).
struct StateStore: Sendable {
    let files: FileStoring

    func loadState() -> PersistedState? {
        files.read(StateFiles.state).flatMap { KerdlyJSON.decode(PersistedState.self, from: $0) }
    }

    @discardableResult
    func save(_ state: PersistedState) -> Bool {
        guard let data = KerdlyJSON.encode(state) else { return false }
        return files.write(data, to: StateFiles.state)
    }

    func loadQueue() -> QueueFile? {
        files.read(StateFiles.queue).flatMap { KerdlyJSON.decode(QueueFile.self, from: $0) }
    }

    @discardableResult
    func save(queue: [QueuedEvent], installId: String) -> Bool {
        guard let data = KerdlyJSON.encode(QueueFile(installId: installId, events: queue)) else { return false }
        return files.write(data, to: StateFiles.queue)
    }

    func loadConfig() -> ConfigCache? {
        files.read(StateFiles.config).flatMap { KerdlyJSON.decode(ConfigCache.self, from: $0) }
    }

    @discardableResult
    func save(config: ConfigCache) -> Bool {
        guard let data = KerdlyJSON.encode(config) else { return false }
        return files.write(data, to: StateFiles.config)
    }
}
