import Foundation

/// A single persistent dictation history entry.
public struct HistoryRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let durationSeconds: Double
    public let engineIdentifier: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        text: String,
        durationSeconds: Double,
        engineIdentifier: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.durationSeconds = durationSeconds
        self.engineIdentifier = engineIdentifier
        self.timestamp = timestamp
    }
}

/// Thread-safe local file-backed history storage.
public final class HistoryStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var cachedRecords: [HistoryRecord] = []

    public init(fileURL: URL? = nil) {
        if let fileURL = fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let folder = appSupport.appendingPathComponent("KansoDictate", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = folder.appendingPathComponent("history.json")
        }
        load()
    }

    public var records: [HistoryRecord] {
        lock.withLock { cachedRecords }
    }

    public func addRecord(_ record: HistoryRecord) {
        lock.lock()
        cachedRecords.insert(record, at: 0) // Newest first
        let current = cachedRecords
        lock.unlock()
        persist(records: current)
    }

    public func clear() {
        lock.lock()
        cachedRecords.removeAll()
        lock.unlock()
        persist(records: [])
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryRecord].self, from: data) else {
            cachedRecords = []
            return
        }
        cachedRecords = decoded
    }

    private func persist(records: [HistoryRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
