//
//  DSHToolGate.swift
//  Minis
//
//  Loop guard, ported from DeepSeek Harness's repeat-tool reminder and
//  tool-call scheduler guards.
//
//  OpenMinis ran its loop detector only AFTER a tool call settled, so a model
//  stuck on a repeated no-progress call burned several full rounds before
//  anything noticed. DSH's guard runs before dispatch: a call that has already
//  been seen too many times never executes, and the model receives the reason as
//  the tool result so it changes approach on the next step.
//
//  A blocked call therefore returns an error result instead of running. That is
//  the whole mechanism — there is no separate retry counter to keep in sync with
//  the scheduler.
//

import Foundation

/// Loop guard: detects repeated no-progress calls and blocks them before they
/// fire again.
final class DSHToolGate: @unchecked Sendable {

    private let lock = NSLock()
    private let enabled: Bool
    private let defaultWarning: Int
    private let defaultCritical: Int

    /// Call counts by `toolName:argumentHash`.
    private var history: [String: Int] = [:]
    /// Outcome counts by `toolName:resultHash`, so a call whose output stops
    /// changing is recognised independently of its arguments.
    private var noProgress: [String: Int] = [:]
    /// Warning emission buckets, so a warning fires once per threshold multiple
    /// rather than on every subsequent identical call.
    private var warningBuckets: [String: Int] = [:]

    init(enabled: Bool, warningThreshold: Int, criticalThreshold: Int) {
        self.enabled = enabled
        self.defaultWarning = max(1, warningThreshold)
        self.defaultCritical = max(self.defaultWarning + 1, criticalThreshold)
    }

    struct Verdict: Sendable {
        public enum Level: Sendable { case pass, warning, critical }
        public let level: Level
        public let message: String?

        public init(level: Level, message: String?) {
            self.level = level
            self.message = message
        }

        public static let pass = Verdict(level: .pass, message: nil)
    }

    /// Check before a call fires.
    ///
    /// - Parameters:
    ///   - toolName: the tool being called.
    ///   - arguments: the call's parsed arguments.
    ///   - warningThreshold / criticalThreshold: per-call overrides. Omit to use
    ///     the guard's configured thresholds.
    func check(
        toolName: String,
        arguments: [String: Any],
        warningThreshold: Int? = nil,
        criticalThreshold: Int? = nil
    ) -> Verdict {
        guard enabled else { return .pass }
        let warning = max(1, warningThreshold ?? defaultWarning)
        let critical = max(warning + 1, criticalThreshold ?? defaultCritical)

        lock.lock()
        defer { lock.unlock() }

        let key = "\(toolName):\(stableHash(arguments))"
        let count = (history[key] ?? 0) + 1
        history[key] = count

        if count >= critical {
            return Verdict(
                level: .critical,
                message: "[LOOP BLOCKED] CRITICAL: called \(toolName) \(count) times with identical arguments. Stop retrying and report the outcome without that tool."
            )
        }
        if count >= warning {
            let bucket = count / warning
            if let last = warningBuckets[key], last >= bucket { return .pass }
            warningBuckets[key] = bucket
            return Verdict(
                level: .warning,
                message: "[LOOP WARNING] You have called \(toolName) \(count) times with identical arguments. If this is not making progress, stop and report."
            )
        }
        return .pass
    }

    /// Record a settled call.
    func record(
        toolName: String,
        result: String?,
        errorMessage: String?,
        warningThreshold: Int? = nil,
        criticalThreshold: Int? = nil
    ) -> Verdict {
        guard enabled else { return .pass }
        let warning = max(1, warningThreshold ?? defaultWarning)
        let critical = max(warning + 1, criticalThreshold ?? defaultCritical)

        lock.lock()
        defer { lock.unlock() }

        let key = "\(toolName):\(stableHash(result ?? ""))"
        let count = (noProgress[key] ?? 0) + 1
        noProgress[key] = count

        if count >= warning && count < critical {
            let bucket = count / warning
            if let last = warningBuckets[key], last >= bucket { return .pass }
            warningBuckets[key] = bucket
            // [T-dsh-gate-scalar-hash] The gate is otherwise silent, which is why
            // the false positive it just had (every result of a tool shared one
            // key, so the tenth call always warned) could only be seen in the
            // transcript and never in a device log. One line where a warning is
            // actually emitted is what makes the next report diagnosable.
            AppLogger(category: "DSHLoop").warning(
                "[DSH] loop gate: \(toolName) produced the same outcome \(count)× "
                + "(warning=\(warning) critical=\(critical) key=\(key.prefix(24))…)")
            return Verdict(
                level: .warning,
                message: "[LOOP WARNING] This call has produced the same outcome \(count) times. Change approach or report the result."
            )
        }
        return .pass
    }

    /// Reset every counter. Called when a turn ends, so a new turn starts clean.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        history.removeAll()
        noProgress.removeAll()
        warningBuckets.removeAll()
    }

    // MARK: - Hashing

    /// Stable hash over a JSON-serializable value, so semantically equal
    /// arguments collapse to one counter.
    ///
    /// [T-dsh-gate-scalar-hash] A tool RESULT is a bare `String`, and
    /// `JSONSerialization.isValidJSONObject` accepts only an array or a
    /// dictionary at the top level — every string fell through to the `"?"`
    /// fallback. So `record`'s key `"\(toolName):?"` was the SAME for every
    /// result of a given tool: ten `file_read`s of different pages (or of
    /// different files, with different content) incremented one shared counter
    /// and the tenth got "[LOOP WARNING] This call has produced the same
    /// outcome 10 times", which was simply false. `.fragmentsAllowed` is what
    /// lets a scalar serialize at the root, so the guard has no job here — the
    /// same reason `BrowserUseManager.stringifyJSReturn` keeps it for
    /// containers only. (The repository already records this behaviour:
    /// `BrowserUseManager.swift` — "`isValidJSONObject` requires the top level
    /// to be an array or dictionary, so naked scalars fall here.")
    private func stableHash(_ value: Any) -> String {
        let normalized = normalize(value)
        guard let data = try? JSONSerialization.data(
            withJSONObject: normalized, options: [.sortedKeys, .fragmentsAllowed]
        ), let text = String(data: data, encoding: .utf8) else {
            return "?"
        }
        return text
    }

    private func normalize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = normalize(v) }
            return out
        }
        if let arr = value as? [Any] { return arr.map { normalize($0) } }
        if value is NSNull { return NSNull() }
        if let s = value as? String { return s }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n }
        return String(describing: value)
    }
}
