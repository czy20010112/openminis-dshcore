//
//  DSHRemoteTranscriptCache.swift
//  Minis
//
//  On-disk transcript cache: what makes re-opening the same remote Session feel
//  instant.
//
//  WHY THIS CAN EXIST AT ALL
//  A snapshot frame is a REPLACE (`applySnapshot` rebuilds), so a cached page can
//  only be combined with the host if the host can CONTINUE the log. Protocol v1
//  gained exactly that (`after=<cursor>` → `resumed: true` / `reset: true`), which
//  is why this file was not written earlier: without an explicit resume signal,
//  "show the cache, then fetch" produces either duplicates or a truncated
//  transcript.
//
//  WHAT IS CACHED: records + cursor only. Never `goal` / `todos` / `summary` —
//  those change on a 30-second scale and a stale goal is worse than no goal.
//  WHAT IT IS NOT: an offline reader. A cache miss simply means the old full path.
//
//  Layout: `Application Support/dsh-cache/<sessionId>.json`
//    { "version": 1, "serverId": …, "sessionId": …, "cursor": 4211,
//      "savedAt": 1761612345.123, "records": [ { "seq": 1, "event": {…} }, … ] }
//
//  Limits: 400 records per Session (newest kept) and 20 MB in total, oldest file
//  evicted first. A corrupt file is deleted on sight — a cache must never be able
//  to break the page it exists to speed up.
//

import Foundation

struct DSHCachedTranscript: Codable {
    static let currentVersion = 1

    var version: Int = DSHCachedTranscript.currentVersion
    var serverId: String
    var sessionId: String
    var cursor: Int
    var savedAt: Date
    var records: [DSHHistoryRecord]

    /// True when the file is usable for THIS pairing and this Session.
    func isValid(serverId: String, sessionId: String) -> Bool {
        version == DSHCachedTranscript.currentVersion
            && self.serverId == serverId
            && self.sessionId == sessionId
            && cursor > 0
            && !records.isEmpty
    }
}

enum DSHRemoteTranscriptCache {

    /// Newest 400 records per Session: enough for ~40 turns of history, small
    /// enough that decoding it on open is a few milliseconds.
    static let maxRecords = 400
    /// Total budget for every cached Session. Beyond this the OLDEST file goes.
    static let maxTotalBytes = 20 * 1024 * 1024

    // MARK: Location

    /// `Application Support/dsh-cache` — caches belong in Application Support, not
    /// Documents (not user-visible, not backed up).
    static func directory() -> URL? {
        let manager = FileManager.default
        guard let base = try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("dsh-cache", isDirectory: true)
        if !manager.fileExists(atPath: dir.path) {
            try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileURL(sessionId: String) -> URL? {
        guard let dir = directory() else { return nil }
        // Session ids are UUID-ish; the sanitiser is for hostile/garbled ids.
        let safe = sessionId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return dir.appendingPathComponent("\(safe).json")
    }

    // MARK: Read / write

    /// `nil` on a miss — including a corrupt or foreign file, which is deleted.
    static func load(serverId: String, sessionId: String) -> DSHCachedTranscript? {
        guard let url = fileURL(sessionId: sessionId),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            NSLog("[DSH] cache unreadable sid=\(sessionId.prefix(12)) → removed")
            remove(sessionId: sessionId)
            return nil
        }
        do {
            let cached = try cacheDecoder().decode(DSHCachedTranscript.self, from: data)
            guard cached.isValid(serverId: serverId, sessionId: sessionId) else {
                // Wrong host (re-paired), wrong version, or an empty page: the file
                // describes a different world, so it must not be shown.
                NSLog("[DSH] cache rejected sid=\(sessionId.prefix(12)) version=\(cached.version) records=\(cached.records.count) → removed")
                remove(sessionId: sessionId)
                return nil
            }
            return cached
        } catch {
            NSLog("[DSH] cache corrupt sid=\(sessionId.prefix(12)): \(error.localizedDescription) → removed")
            remove(sessionId: sessionId)
            return nil
        }
    }

    /// Keep the newest `maxRecords` of `records`, ordered by seq, and write.
    @discardableResult
    static func save(serverId: String, sessionId: String, cursor: Int,
                     records: [DSHHistoryRecord]) -> Int {
        guard let url = fileURL(sessionId: sessionId), cursor > 0, !records.isEmpty else { return 0 }
        let trimmed = Array(records.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) }.suffix(maxRecords))
        let cached = DSHCachedTranscript(serverId: serverId, sessionId: sessionId,
                                         cursor: cursor, savedAt: Date(), records: trimmed)
        do {
            let data = try cacheEncoder().encode(cached)
            try data.write(to: url, options: .atomic)
            excludeFromBackup(url)
            evictIfNeeded(keeping: url)
            return trimmed.count
        } catch {
            NSLog("[DSH] cache write failed sid=\(sessionId.prefix(12)): \(error.localizedDescription)")
            return 0
        }
    }

    static func remove(sessionId: String) {
        guard let url = fileURL(sessionId: sessionId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func removeAll() {
        guard let dir = directory() else { return }
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files { try? manager.removeItem(at: file) }
    }

    /// The longest run of records with strictly ascending, gapless `seq`s, ending
    /// at the newest record — the only suffix it is safe to hand back as a cursor.
    ///
    /// Lives here, not in the store: it is a property of what may be CACHED, and it
    /// must be testable without a paired device.
    static func contiguousTail(_ records: [DSHHistoryRecord]) -> [DSHHistoryRecord] {
        let sorted = records.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) }
        var tail: [DSHHistoryRecord] = []
        var expected: Double?
        for record in sorted {
            guard let seq = record.seq else { continue }
            if let wanted = expected {
                if seq == wanted {
                    tail.append(record)
                    expected = seq + 1
                } else if seq > wanted {
                    // Gap: everything before it can never be continued from.
                    tail = [record]
                    expected = seq + 1
                }
                // seq <= last seen: duplicate, skip.
            } else {
                tail = [record]
                expected = seq + 1
            }
        }
        return Array(tail.suffix(maxRecords))
    }

    /// Records on disk, for diagnostics and the eviction test.
    static func totalBytes() -> Int {
        guard let dir = directory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
    }

    // MARK: Housekeeping

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// Oldest first until the total fits the budget.
    private static func evictIfNeeded(keeping url: URL) {
        guard let dir = directory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        var entries: [(url: URL, size: Int, modified: Date)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxTotalBytes else { return }
        entries.sort { $0.modified < $1.modified }
        for entry in entries where total > maxTotalBytes {
            guard entry.url != url else { continue }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            NSLog("[DSH] cache evicted \(entry.url.lastPathComponent) size=\(entry.size)")
        }
    }

    // MARK: Coding

    private static func cacheEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Readable on purpose: this file is a debugging aid as much as a cache.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func cacheDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
