//
//  DSHPrefixStability.swift
//  Minis
//
//  Development-time assertion that the outbound request only ever grows at the
//  tail.
//
//  A server that caches the KV prefix by longest-common-token-prefix has to
//  re-prefill the whole conversation the moment any byte *before* the tail
//  changes. Nothing in the app notices: the request is semantically identical,
//  the reply is correct, and the only symptom is a first token that takes
//  seconds instead of milliseconds. That is why this bug survived so long — the
//  symptom lives in the engine's log, not in ours.
//
//  So the invariant is asserted here instead, on every request: canonically
//  serialize each message, hash it, and compare against the previous request
//  position by position. A stable session reports "only the last N messages are
//  new"; the first differing index names the message and the field that moved,
//  with both sides' text so the cause is readable without a packet capture.
//
//  Switch: `minis.prefixStabilityProbe` (UserDefaults). Defaults to on in DEBUG
//  builds and off in release; set it to 1 in a release build to keep the check
//  in a TestFlight log.
//

import Foundation

enum DSHPrefixStability {

    // MARK: - Switch

    static let defaultsKey = "minis.prefixStabilityProbe"

    /// Whether the assertion runs. Release defaults to off so the per-request
    /// canonicalization + hashing never ships as an unconditional cost.
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Bodies larger than this are skipped: hashing them costs more than the
    /// information is worth, and a session this large has already been checked
    /// at smaller sizes.
    private static let maxBytes = 16 * 1024 * 1024

    // MARK: - Canonical serialization

    /// Canonical bytes for any JSON value: sorted keys at every level, no
    /// escaped slashes, no whitespace.
    ///
    /// Byte-identical for semantically identical input, which is the whole
    /// point — Swift's dictionary iteration order is not a stable contract and
    /// `JSONSerialization` without `.sortedKeys` emits exactly that order.
    static func canonicalJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8) else {
            // The request bodies this is pointed at are built from JSON-legal
            // values only, so this branch is a canary, not a path.
            return "<not-json>"
        }
        return text
    }

    /// The same message with every embedded `function.arguments` string replaced
    /// by its canonical form.
    ///
    /// `arguments` travels as a *string*, so canonicalizing the enclosing object
    /// cannot see inside it: two turns whose arguments differ only in key order
    /// produce identical message objects but different bytes on the wire. Doing
    /// this here is what lets the report separate "the model actually said
    /// something different" from "we re-serialized the same thing", and that
    /// distinction is the entire content of this bug.
    static func canonicalizingEmbeddedArguments(_ value: Any) -> Any {
        guard var message = value as? [String: Any],
              let calls = message["tool_calls"] as? [[String: Any]] else { return value }
        var rewritten: [[String: Any]] = []
        rewritten.reserveCapacity(calls.count)
        for var call in calls {
            if var function = call["function"] as? [String: Any],
               let raw = function["arguments"] as? String,
               let data = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                function["arguments"] = canonicalJSON(parsed)
                call["function"] = function
            }
            rewritten.append(call)
        }
        message["tool_calls"] = rewritten
        return message
    }

    // MARK: - Comparison

    /// First index whose canonical hash differs, or nil when every shared
    /// position is byte-identical.
    ///
    /// The reference form of this check, kept for callers that already hold both
    /// sides. `note(_:label:)` is the one the app calls.
    static func firstUnstableIndex(previous: [[String: Any]], current: [[String: Any]]) -> Int? {
        let n = min(previous.count, current.count)
        for i in 0..<n where fingerprint(previous[i]).hash != fingerprint(current[i]).hash {
            return i
        }
        return nil
    }

    /// Everything kept about one message between requests: its canonical hash,
    /// the hash of each top-level field (so the report can name what moved),
    /// and a bounded window of its text for the "both sides" excerpt.
    struct Fingerprint {
        let hash: String
        let fields: [String: String]
        /// Canonical text of the message, truncated — enough to read the field
        /// that moved without pinning a multi-megabyte body in memory.
        let excerpt: String
        /// Byte offset of the first difference *within* this message, when the
        /// caller that produced it can supply one.
        let length: Int
    }

    static func fingerprint(_ message: Any) -> Fingerprint {
        let canonicalMessage = canonicalizingEmbeddedArguments(message)
        let text = canonicalJSON(canonicalMessage)
        var fields: [String: String] = [:]
        if let dict = canonicalMessage as? [String: Any] {
            for (key, value) in dict {
                fields[key] = sha256Hex(canonicalJSON(value))
            }
        }
        return Fingerprint(
            hash: sha256Hex(text),
            fields: fields,
            excerpt: String(text.prefix(excerptLimit)),
            length: text.utf8.count
        )
    }

    private static let excerptLimit = 900

    // MARK: - Per-request check

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var previous: [Fingerprint] = []
        private var previousCount = 0
        private var previousLabel = ""

        func swap(in fingerprints: [Fingerprint], label: String) -> ([Fingerprint], Int, String) {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = (previous, previousCount, previousLabel)
            previous = fingerprints
            previousCount = fingerprints.count
            previousLabel = label
            return snapshot
        }
    }

    private static let store = Store()
    private static let logger = AppLogger(category: "PrefixStability")

    /// Canonicalize this request, compare it against the previous one, and log
    /// the outcome. Silent when the check is off.
    ///
    /// Call it with the final message array — after the system prompt has been
    /// inserted and after every conversion — because an instability anywhere in
    /// that array is what the server's cache sees.
    static func note(_ messages: [[String: Any]], label: String) {
        guard isEnabled else { return }

        var total = 0
        var fingerprints: [Fingerprint] = []
        fingerprints.reserveCapacity(messages.count)
        for message in messages {
            let entry = fingerprint(message)
            total += entry.length
            if total > maxBytes {
                logger.info("[PrefixStability] label=\(label) skipped — bodies over \(maxBytes) bytes")
                _ = store.swap(in: [], label: label)
                return
            }
            fingerprints.append(entry)
        }

        let (previous, previousCount, previousLabel) = store.swap(in: fingerprints, label: label)
        guard !previous.isEmpty, previousLabel == label else { return }

        let shared = min(previous.count, fingerprints.count)
        var unstable: Int?
        for i in 0..<shared where previous[i].hash != fingerprints[i].hash {
            unstable = i
            break
        }

        guard let index = unstable else {
            logger.info("[PrefixStability] label=\(label) msgs=\(messages.count) "
                + "prefix-stable=\(shared) (\(previousCount) → \(messages.count), "
                + "only the tail is new)")
            return
        }

        let old = previous[index]
        let new = fingerprints[index]
        let moved = Set(old.fields.keys).union(new.fields.keys)
            .filter { old.fields[$0] != new.fields[$0] }
            .sorted()
        logger.warning("[PrefixStability] label=\(label) msgs=\(messages.count) "
            + "FIRST-UNSTABLE index=\(index) shared-before-it=\(index)/\(min(previousCount, messages.count)) "
            + "changed-fields=[\(moved.joined(separator: ","))] "
            + "role=\((messages[index]["role"] as? String) ?? "?")")
        logger.warning("[PrefixStability]   prev[\(index)]: \(old.excerpt)")
        logger.warning("[PrefixStability]   cur [\(index)]: \(new.excerpt)")
        logger.warning("[PrefixStability]   tail after the change is re-prefilled by the server; "
            + "if the fields above are all `tool_calls` and the arguments parse equal, "
            + "a tool-call arguments string was re-serialized in a different key order.")
    }

    // MARK: - SHA-256

    /// SHA-256 of a UTF-8 string, lowercase hex.
    ///
    /// Hand-rolled rather than CryptoKit so this file stays inside the
    /// Foundation-only subset the Windows preflight can type-check (CryptoKit is
    /// not in that subset). Used for equality only — nothing here is
    /// security-relevant, and the vectors in `_tools/prefix-stability-selftest.cjs`
    /// pin it to FIPS 180-4.
    static func sha256Hex(_ text: String) -> String {
        var message = Array(text.utf8)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var schedule = [UInt32](repeating: 0, count: 64)

        var chunk = 0
        while chunk < message.count {
            for i in 0..<16 {
                let base = chunk + i * 4
                schedule[i] = (UInt32(message[base]) << 24)
                    | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8)
                    | UInt32(message[base + 3])
            }
            for i in 16..<64 {
                let x = schedule[i - 15]
                let y = schedule[i - 2]
                let s0 = rotateRight(x, 7) ^ rotateRight(x, 18) ^ (x >> 3)
                let s1 = rotateRight(y, 17) ^ rotateRight(y, 19) ^ (y >> 10)
                schedule[i] = schedule[i - 16] &+ s0 &+ schedule[i - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ kRoundConstants[i] &+ schedule[i]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
            chunk += 64
        }

        var out = ""
        out.reserveCapacity(64)
        for word in state {
            out += String(format: "%08x", word)
        }
        return out
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    /// FIPS 180-4 §4.2.2 round constants.
    private static let kRoundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}
