//
//  DSHSpillStore.swift
//  Minis
//
//  Storage for spilled tool results, ported from DeepSeek Harness
//  (packages/spill/spill-local/src/{index,store,cleanup}.ts).
//
//  WHERE THE FILE GOES, AND WHY IT HAS TO GO THERE
//  ----------------------------------------------
//  The spill notice tells the model "Use file_read with offset/limit, or a
//  shell_execute grep on this path to search within it." That sentence is only
//  true if the path is one the model's own tools can open. The session's existing
//  offload bucket already is:
//
//    * `AIChatViewModel.minisOffloadsLinuxDir` is `/var/minis/offloads`
//      (AIChatViewModel+Misc.swift:137);
//    * `/var/minis/offloads` is bind-mounted onto
//      `minisPersistentBase/<sid>/offloads` — i.e.
//      `Library/MinisChat/minis/<sid>/offloads` — by `ensureMinisSymlinks`
//      (AIChatViewModel+Offloading.swift:892–901);
//    * the app's own system prompt already documents the directory to the model
//      as "Auto-saved large outputs. Read with file_read."
//      (AIChatViewModel.swift:2367);
//    * `AIChatViewModel.resolvePathForDirectRead` resolves any `/var/minis/…`
//      path through the live bind-mount table (AIChatViewModel+FileTools.swift:145),
//      which is what `file_read` goes through — and the shell reaches the same
//      bytes, so the notice's "or grep this path" is a `shell_execute` grep on
//      that path rather than a tool of its own;
//    * the same bucket is already used for offloaded tool output
//      (`offloadContextContent` → `<...>/offloads/tools/<tool>_<id>.txt`,
//      AIChatViewModel+Offloading.swift:86–100) and for request-budget image
//      spillover (AIChatViewModel+RequestBudget.swift:119).
//
//  So a spill file is addressable by `file_read`, `read_image`, and
//  `shell_execute` with no new mount, no new tool, and no prompt change. The
//  subtree is `offloads/dsh-spill/session-<hash>/…`, which keeps DSH spill
//  files distinguishable from the offloader's own `offloads/tools/…` files so
//  the cleanup sweep can never delete the user's offloaded content.
//
//  Naming and permissions follow the upstream backend:
//
//    * the session directory is keyed by a hash of the session id, so two
//      sessions never collide and neither the directory nor the notice leaks the
//      raw session id;
//    * the file name carries 6 random bytes, so a name cannot be predicted and a
//      result can never overwrite another one;
//    * the directory is created with `NSFileProtectionComplete` and files are
//      written with the same protection — upstream's 0700/0600 intent, expressed
//      as the iOS facility that actually enforces it;
//    * one best-effort sweep on first use reclaims spill files older than
//      `cleanupPeriodDays` (default 30, `0` disables), by modification date.
//

import CryptoKit
import Foundation

/// Filesystem backend for DSH spill files.
///
/// iOS-only by construction: it writes into the app's session bucket. The
/// location *decision* lives here because it is an app fact, not a policy fact —
/// `DSHSpill` stays storage-free so its retention logic can be exercised without
/// a filesystem.
public enum DSHSpillStore {

    /// Directory name under the session's offload bucket. A distinct level keeps
    /// the sweep from ever walking the offloader's own files.
    public static let subtreeName = "dsh-spill"

    /// Prefix of a session directory, matching upstream's `session-<hash>`.
    public static let sessionDirectoryPrefix = "session-"

    /// The guest-visible folder every spill file lands in.
    ///
    /// Only the settings screen needs this — a real path is per session and comes
    /// from `linuxPath(fileName:sessionId:)`. Kept here rather than spelled out in
    /// the view so the folder appears in exactly one place in the app's code.
    public static let offloadsDisplayPath = "/var/minis/offloads/\(subtreeName)/"

    /// Whether the one-shot expiry sweep has already run in this process.
    /// Guarded by a lock rather than the main actor: `write` is callable from a
    /// tool's own context and the sweep must not run twice under a race.
    private static let cleanupLock = NSLock()
    private static var cleanupStarted = false

    // MARK: - Paths

    /// Host directory for one session's spill files.
    ///
    /// - Parameters:
    ///   - sessionId: the owning conversation.
    ///   - offloadsRoot: host URL of the session's `offloads` bucket.
    /// - Returns: the host directory, which may not exist yet.
    public static func sessionDirectory(sessionId: String, offloadsRoot: URL) -> URL {
        offloadsRoot
            .appendingPathComponent(subtreeName, isDirectory: true)
            .appendingPathComponent(sessionDirectoryPrefix + sessionHash(sessionId), isDirectory: true)
    }

    /// The `/var/minis/offloads/…` path the model uses to reach one spill file.
    ///
    /// - Parameters:
    ///   - fileName: the file's name in the session directory.
    ///   - sessionId: the owning conversation.
    /// - Returns: the guest-visible path of the file.
    public static func linuxPath(fileName: String, sessionId: String) -> String {
        "/var/minis/offloads/\(subtreeName)/\(sessionDirectoryPrefix + sessionHash(sessionId))/\(fileName)"
    }

    /// 12 lowercase hex characters of `sha256(sessionId)` — upstream's own
    /// derivation, unchanged: `sha256(sessionId).slice(0, 12)`.
    ///
    /// - Parameter sessionId: the owning conversation.
    /// - Returns: the directory key.
    public static func sessionHash(_ sessionId: String) -> String {
        let digest = SHA256.hash(data: Data(sessionId.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Write

    /// One written spill file.
    public struct Saved: Sendable {
        /// Guest-visible path, e.g. `/var/minis/offloads/dsh-spill/session-ab12…/9f3c1a-tool.txt`.
        public let linuxPath: String
        /// Host URL of the same file.
        public let hostURL: URL
        /// UTF-8 byte length of the text that was written.
        public let bytes: Int
    }

    /// Write one tool result's full text under its session's spill directory.
    ///
    /// Synchronous, and callers reach it from the turn's actor. That is a real
    /// constraint and not an oversight: the notice naming this file is written
    /// into the same session append as the bounded result, so the bytes must be
    /// on disk before the tool result is published. The app's existing offloader
    /// does the same thing for the same reason (`offloadContextContent`).
    /// Writes are one tool result apiece, so the cost is a single file write per
    /// spilled call — bounded by the size of the result that tripped the budget.
    ///
    /// - Parameters:
    ///   - text: the COMPLETE result — this is the copy the notice points at.
    ///   - toolName: the producing tool, used as the readable part of the name.
    ///   - sessionId: the owning conversation.
    ///   - offloadsRoot: host URL of the session's `offloads` bucket.
    ///   - cleanupPeriodDays: passed to the one-shot sweep on first write.
    /// - Returns: the saved file, or nil when nothing was written.
    @discardableResult
    public static func write(
        text: String,
        toolName: String,
        sessionId: String,
        offloadsRoot: URL,
        cleanupPeriodDays: Int
    ) -> Saved? {
        let directory = sessionDirectory(sessionId: sessionId, offloadsRoot: offloadsRoot)
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        } catch {
            return nil
        }

        let fileName = "\(randomSuffix())-\(safeName(toolName)).txt"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        do {
            // `.atomic` writes a sibling and renames it, so a reader can never
            // observe a half-written spill file — the model may well be reading
            // this path while the next tool call is still settling.
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)

        sweepExpired(offloadsRoot: offloadsRoot, cleanupPeriodDays: cleanupPeriodDays)

        return Saved(linuxPath: linuxPath(fileName: fileName, sessionId: sessionId), hostURL: url, bytes: text.utf8.count)
    }

    /// Write an image blob a spilled result had to drop, so the model can still
    /// re-read the pixels the notice told it about.
    ///
    /// - Parameters:
    ///   - data: the image bytes.
    ///   - toolName: the producing tool.
    ///   - sessionId: the owning conversation.
    ///   - offloadsRoot: host URL of the session's `offloads` bucket.
    ///   - fileExtension: the extension for the media type (`png`, `jpg`, …).
    /// - Returns: the saved file, or nil.
    @discardableResult
    public static func writeImage(
        data: Data,
        toolName: String,
        sessionId: String,
        offloadsRoot: URL,
        fileExtension: String
    ) -> Saved? {
        let directory = sessionDirectory(sessionId: sessionId, offloadsRoot: offloadsRoot)
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        } catch {
            return nil
        }
        let fileName = "\(randomSuffix())-\(safeName(toolName)).\(fileExtension)"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return Saved(linuxPath: linuxPath(fileName: fileName, sessionId: sessionId), hostURL: url, bytes: data.count)
    }

    // MARK: - Expiry

    /// Run the one-shot expiry sweep, at most once per process.
    ///
    /// Called on the first spill write rather than at launch: the app has no
    /// spill subtree until it spills something for the first time, so a launch
    /// hook would walk a directory that usually does not exist.
    ///
    /// Off the main thread on purpose. The offloads bucket can be backed by a
    /// FileProvider volume, and a directory walk there is a synchronous XPC
    /// round trip — the same watchdog hazard `refreshMountedFolderSymlinks`
    /// documents. The sweep is best-effort and its result is never awaited.
    public static func sweepExpiredOnce(offloadsRoot: URL, cleanupPeriodDays: Int) {
        guard cleanupPeriodDays > 0 else { return }
        cleanupLock.lock()
        if cleanupStarted {
            cleanupLock.unlock()
            return
        }
        cleanupStarted = true
        cleanupLock.unlock()

        Task.detached(priority: .utility) {
            _ = sweepExpired(offloadsRoot: offloadsRoot, cleanupPeriodDays: cleanupPeriodDays)
        }
    }

    /// Delete spill files whose modification date is older than the cutoff, then
    /// prune the directories left empty.
    ///
    /// Best-effort by contract: an entry that cannot be inspected or removed is
    /// left alone, and no failure propagates.
    ///
    /// - Parameters:
    ///   - offloadsRoot: host URL of a session's `offloads` bucket.
    ///   - cleanupPeriodDays: age cutoff in days; `0` disables.
    /// - Returns: how many files were removed.
    @discardableResult
    public static func sweepExpired(offloadsRoot: URL, cleanupPeriodDays: Int) -> Int {
        guard cleanupPeriodDays > 0 else { return 0 }
        let root = offloadsRoot.appendingPathComponent(subtreeName, isDirectory: true)
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }

        let cutoff = Date().addingTimeInterval(-Double(cleanupPeriodDays) * 24 * 60 * 60)
        var removed = 0
        for session in sessions {
            let name = session.lastPathComponent
            // Only our own session directories are swept. An unrelated
            // `session-backup` directory, or anything else sharing this subtree,
            // is never descended into.
            guard name.hasPrefix(sessionDirectoryPrefix) else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: session,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified < cutoff else { continue }
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
            }
            // Prune the session directory only when the sweep emptied it; a
            // directory that still holds a fresh spill file stays.
            if let remaining = try? fm.contentsOfDirectory(atPath: session.path), remaining.isEmpty {
                try? fm.removeItem(at: session)
            }
        }
        return removed
    }

    // MARK: - Naming

    /// 6 random bytes as lowercase hex, upstream's `randomBytes(6).toString('hex')`.
    private static func randomSuffix() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Reduce a tool name to one filesystem-safe segment.
    ///
    /// Tool names reach here from the model's tool call, so they are untrusted
    /// input: anything outside `[A-Za-z0-9_-]` becomes `_`, which removes path
    /// separators, `..`, and control characters in one step. An empty name falls
    /// back to `tool`.
    private static func safeName(_ toolName: String) -> String {
        let mapped = toolName.map { character -> Character in
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                return character
            }
            return "_"
        }
        let name = String(mapped)
        return name.isEmpty ? "tool" : String(name.prefix(64))
    }
}
