//
//  DSHRemoteTeamTools.swift
//  Minis
//
//  The four `remote_team_*` tools: spawn a durable teammate on the PAIRED
//  computer, keep talking to it, list the roster, interrupt it.
//
//  Contract: `verify/DSH-REMOTE-TEAM-CONTRACT.md` §2. Two things this file
//  deliberately does NOT do:
//    * it opens no stream — progress is answered by `remote_team_list`, and the
//      teammate's own output is its DSH Session (`sessionId` is in every reply);
//    * it owns no tool DEFINITION — `makeAgentTools()` (client-ui) declares the
//      name/description/parameters, and `availability` below is what it gates on.
//
//  Naming: the host identifies a teammate by name and rejects a duplicate with
//  `409 team/name-taken`. The phone therefore generates a kebab-case name from the
//  task, and this file retries with `-2` / `-3` before giving up.
//

import Foundation

enum DSHRemoteTeamTools {

    /// What `makeAgentTools()` needs to decide whether to register the four tools.
    enum Availability: Equatable {
        /// No paired computer: nothing to dispatch to.
        case notPaired
        /// Paired, but the host has no agent-team service (`503 team/unavailable`).
        case unavailable
        case available

        /// Log/telemetry tag — the same spelling the device log uses.
        var tag: String {
            switch self {
            case .notPaired: return "notPaired"
            case .unavailable: return "unavailable"
            case .available: return "available"
            }
        }
    }

    /// Cached so `makeAgentTools()` can be synchronous; refreshed by a probe.
    private static var cached: Availability = .notPaired
    private static var lastProbe = Date.distantPast
    /// Members seen by the last successful roster probe (0 when unknown).
    private(set) static var lastMemberCount = 0

    /// Synchronous read for tool registration. Kicks a throttled probe so the
    /// value converges without anyone having to await it at build time.
    @MainActor
    static var availability: Availability {
        probeIfStale()
        return cached
    }

    /// Awaitable refresh (tests, and after pairing completes).
    @MainActor
    @discardableResult
    static func refreshAvailability(force: Bool = true) async -> Availability {
        if !force, Date().timeIntervalSince(lastProbe) < 30 { return cached }
        lastProbe = Date()
        guard DSHRemoteStore.shared.isPaired else {
            cached = .notPaired
            return .notPaired
        }
        do {
            let roster = try await DSHRemoteStore.shared.listTeamMembers()
            cached = .available
            lastMemberCount = roster.members.count
            NSLog("[DSH] team availability available members=\(roster.members.count)")
        } catch let error as DSHRemoteError where error.code == "team/unavailable" || error.code == "dsh/unavailable" {
            cached = .unavailable
            lastMemberCount = 0
            NSLog("[DSH] team availability unavailable code=\(error.code)")
        } catch {
            // A transport failure says nothing about the host's capabilities: keep
            // the last known answer instead of flipping the tools off on a hiccup.
            NSLog("[DSH] team availability probe failed: \(error.localizedDescription)")
        }
        return cached
    }

    @MainActor
    private static func probeIfStale() {
        guard Date().timeIntervalSince(lastProbe) > 30 else { return }
        lastProbe = Date()
        Task { await refreshAvailability(force: true) }
    }

    // MARK: - Tool entry point

    /// Run one `remote_team_*` call. Mirrors the shape the other feature tools use
    /// (`DSHWebSearchTool.run`, `DSHGoalTools.run`) so the dispatch switch in
    /// `executeSingleToolUse` only has to route the outcome.
    @MainActor
    static func run(name: String, arguments: [String: Any]) async -> (success: Bool, output: String) {
        switch name {
        case "remote_team_spawn":
            return await spawn(arguments)
        case "remote_team_message":
            return await message(arguments)
        case "remote_team_list":
            return await list()
        case "remote_team_interrupt":
            return await interrupt(arguments)
        case "remote_team_output":
            return await output(arguments)
        default:
            return (false, "Error: unknown remote team tool \(name)")
        }
    }

    // MARK: - output

    /// Read a teammate's answer, waiting for it when necessary.
    ///
    /// This is the tool that closes the loop: the roster shows status, the receipts
    /// show delivery, and only this shows the RESULT. It polls inside the call on
    /// purpose — a model that has to `sleep`/`echo` between turns burns the user's
    /// time and forgets what it was waiting for.
    private static func output(_ arguments: [String: Any]) async -> (success: Bool, output: String) {
        guard let rawTarget = (arguments["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTarget.isEmpty else {
            return (false, "Error: remote_team_output needs `target` (a teammate name from remote_team_list, or its session id).")
        }
        let requested = intArgument(arguments["wait_seconds"], default: 60, min: 5, max: 600)

        // Resolve the name → session id once, up front: the poll loop must not hit
        // the roster on every tick.
        var sessionId = rawTarget
        var name = rawTarget
        do {
            let roster = try await DSHRemoteStore.shared.listTeamMembers()
            if let member = roster.members.first(where: { $0.name == rawTarget || $0.id == rawTarget }) {
                name = member.name
                guard let id = member.sessionId, !id.isEmpty else {
                    return (false, "Error: \(member.name) has no Session yet (status \(member.displayStatus)) — it may still be provisioning. Try remote_team_list again in a moment.")
                }
                sessionId = id
            } else if !looksLikeSessionId(rawTarget) {
                let names = roster.members.map(\.name).joined(separator: ", ")
                return (false, "Error: no teammate named \(rawTarget) on that computer. Known: \(names.isEmpty ? "(none)" : names)")
            }
        } catch {
            return (false, "Error: \(describe(error))")
        }

        // The transcript is polled every tick; the roster (which carries the
        // status) every third tick — a 10-minute wait would otherwise mean 300
        // roster round trips.
        var statusCache: String?
        var tick = 0
        return await pollAnswer(name: name, sessionId: sessionId, waitSeconds: requested) {
            tick += 1
            let answer = try await DSHRemoteStore.shared.teamTranscript(sessionId: sessionId)
            if statusCache == nil || tick % 3 == 1 {
                let roster = try await DSHRemoteStore.shared.listTeamMembers()
                statusCache = roster.members.first(where: { $0.sessionId == sessionId || $0.name == name })?.status
            }
            return (answer, statusCache)
        }
    }

    /// The polling loop, with the host behind two closures so it can be exercised
    /// without a store (see `_tools/dsh-remote-team-test.ps1`).
    ///
    /// Stops on whichever comes first:
    ///   • the teammate said something NEW since the call began → that answer;
    ///   • it is no longer running and has said something → that answer (this is
    ///     the common case: the work finished before the tool was even called);
    ///   • it `failed` → its last answer, if any, plus the status;
    ///   • the deadline.
    static func pollAnswer(
        name: String,
        sessionId: String,
        waitSeconds: Int,
        interval: Double = 2,
        read: () async throws -> (answer: DSHRemoteTeamAnswer, status: String?)
    ) async -> (success: Bool, output: String) {
        let deadline = Date().addingTimeInterval(Double(max(1, waitSeconds)))
        var baseline: String?
        var lastSeen = DSHRemoteTeamAnswer.none
        var lastStatus: String?
        var polls = 0

        while true {
            polls += 1
            do {
                let snapshot = try await read()
                lastSeen = snapshot.answer
                lastStatus = snapshot.status
                if baseline == nil { baseline = snapshot.answer.fingerprint }

                let status = snapshot.status ?? "unknown"
                let isNew = baseline != snapshot.answer.fingerprint
                let finished = status != "running" && status != "provisioning"

                if status == "failed" {
                    return render(name: name, answer: snapshot.answer, status: status,
                                  note: snapshot.answer.isEmpty ? "failed before producing an answer" : nil)
                }
                if isNew, !snapshot.answer.isEmpty {
                    return render(name: name, answer: snapshot.answer, status: status, note: nil)
                }
                if finished, !snapshot.answer.isEmpty {
                    // Already done when we arrived: waiting the full window for a
                    // second answer would be wrong.
                    return render(name: name, answer: snapshot.answer, status: status, note: nil)
                }
            } catch let error as DSHRemoteError where error.code == "team/unavailable" {
                return (false, "Error: \(describe(error))")
            } catch {
                // A transient read failure is not an answer: keep polling.
                NSLog("[DSH] team output poll failed: \(error.localizedDescription)")
            }

            if Date() >= deadline {
                let status = lastStatus ?? "unknown"
                if lastSeen.isEmpty {
                    return (false, "no new answer from \(name) after \(waitSeconds)s (status=\(status), polls=\(polls)). Call remote_team_list to check whether it is still running, then ask again with a longer wait_seconds.")
                }
                return render(name: name, answer: lastSeen, status: status,
                              note: "no NEW answer after \(waitSeconds)s; showing its last output")
            }
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, interval) * 1_000_000_000))
        }
    }

    private static func render(name: String, answer: DSHRemoteTeamAnswer, status: String,
                               note: String?) -> (success: Bool, output: String) {
        var head = "\(name) answered"
        if let turn = answer.turn { head += " (turn \(turn), \(answer.text.count) chars" } else { head += " (\(answer.text.count) chars" }
        head += ", status=\(status))"
        if let note { head += " — \(note)" }
        return (status != "failed" || !answer.isEmpty, "\(head):\n\(answer.text)")
    }

    private static func looksLikeSessionId(_ raw: String) -> Bool {
        raw.hasPrefix("session-") || raw.count >= 32
    }

    private static func intArgument(_ raw: Any?, default fallback: Int, min: Int, max: Int) -> Int {
        var value = fallback
        if let number = raw as? Int { value = number }
        else if let double = raw as? Double { value = Int(double) }
        else if let text = raw as? String, let parsed = Int(text) { value = parsed }
        return Swift.min(Swift.max(value, min), max)
    }

    // MARK: - spawn

    private static func spawn(_ arguments: [String: Any]) async -> (success: Bool, output: String) {
        guard let task = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty else {
            return (false, "Error: remote_team_spawn needs a non-empty `task` — the teammate cannot see this device's context, so the task must be complete on its own.")
        }
        let explicit = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (arguments["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? firstLine(of: task)
        let base = (explicit?.isEmpty == false ? explicit! : suggestedName(from: task))

        do {
            let member = try await withNameRetry(base: base) { name in
                try await DSHRemoteStore.shared.spawnTeammate(
                    name: name, description: description, task: task, context: nil
                )
            }
            let session = member.sessionId ?? "unknown"
            return (true, """
            Dispatched to \(member.name) on the paired computer (host session \(session), status \(member.displayStatus)).
            Follow up with remote_team_message(target: "\(member.name)", text: …) — same teammate, same session, it keeps its context. Do NOT spawn again for a follow-up.
            """)
        } catch let error as DSHRemoteError where error.code == "team/name-taken" {
            return (false, "Error: every suggested name was already taken on that computer (\(base) and its -2/-3 variants). Call remote_team_spawn again with an explicit `name`.")
        } catch {
            return (false, "Error: \(describe(error))")
        }
    }

    /// Try the name, then `-2`, then `-3` when the host answers `409 team/name-taken`.
    ///
    /// Split out from `spawn` so the retry can be exercised without a store (see
    /// `_tools/dsh-remote-team-test.ps1`); it is the only place a name is chosen.
    static func withNameRetry<T>(base: String, maxAttempts: Int = 3,
                                 _ attempt: (String) async throws -> T) async throws -> T {
        var candidate = base
        var tries = 1
        while true {
            do {
                return try await attempt(candidate)
            } catch let error as DSHRemoteError where error.code == "team/name-taken" || error.status == 409 {
                guard tries < maxAttempts else { throw error }
                tries += 1
                candidate = "\(base)-\(tries)"
                NSLog("[DSH] team name taken → retry name=\(candidate)")
            }
        }
    }

    // MARK: - message

    private struct StoredSession: Codable {
        var sessionId: String?
    }

    private static func message(_ arguments: [String: Any]) async -> (success: Bool, output: String) {
        guard let target = (arguments["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else {
            return (false, "Error: remote_team_message needs `target` (the teammate name from remote_team_list).")
        }
        guard let text = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return (false, "Error: remote_team_message needs a non-empty `text`.")
        }
        do {
            let delivery = try await DSHRemoteStore.shared.sendTeamMessage(target: target, text: text)
            let status = delivery.status ?? "unknown"
            let delivered = delivery.delivered ?? true
            if !delivered {
                return (false, "Error: the computer did not accept the message for \(target) (status \(status)).")
            }
            return (true, "Delivered to \(target) (status \(status)). Same teammate, same session — its output shows in its DSH session.")
        } catch let error as DSHRemoteError where error.code == "team/no-such-member" || error.status == 404 {
            return (false, "Error: no teammate named \(target) on that computer. Call remote_team_list to see the current roster.")
        } catch {
            return (false, "Error: \(describe(error))")
        }
    }

    // MARK: - list

    private static func list() async -> (success: Bool, output: String) {
        do {
            let roster = try await DSHRemoteStore.shared.listTeamMembers()
            guard !roster.members.isEmpty else {
                return (true, "No teammates on that computer yet. Use remote_team_spawn to create one.")
            }
            var lines: [String] = []
            for member in roster.members {
                var line = "\(member.name) [\(member.role ?? "teammate")/\(member.displayStatus)]"
                line += " session=\(member.sessionId ?? "-")"
                line += " last=\(relativeTime(member.lastMessageAt))"
                lines.append(line)
            }
            let lead = roster.lead?.sessionId.map { " (dispatch lead session=\($0))" } ?? ""
            return (true, lines.joined(separator: "\n") + "\n" + "\(lines.count) teammate(s)\(lead)")
        } catch {
            return (false, "Error: \(describe(error))")
        }
    }

    // MARK: - interrupt

    private static func interrupt(_ arguments: [String: Any]) async -> (success: Bool, output: String) {
        guard let target = (arguments["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else {
            return (false, "Error: remote_team_interrupt needs `target`.")
        }
        do {
            let result = try await DSHRemoteStore.shared.interruptTeammate(target: target)
            return (result.interrupted ?? true,
                    result.interrupted == false
                    ? "The computer reported nothing to interrupt for \(target)."
                    : "Interrupted \(target).")
        } catch let error as DSHRemoteError where error.code == "team/no-such-member" || error.status == 404 {
            return (false, "Error: no teammate named \(target) on that computer.")
        } catch {
            return (false, "Error: \(describe(error))")
        }
    }

    // MARK: - Naming

    /// First 3–4 meaningful words of the task, kebab-cased.
    ///
    /// A Chinese task has no ASCII words to build from, so the fallback is a short
    /// stable prefix plus a random suffix — the host only needs it to be unique and
    /// readable in its own sidebar.
    static func suggestedName(from task: String) -> String {
        let words = task
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { word in word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
            .prefix(4)
        let kebab = words.joined(separator: "-")
        if kebab.isEmpty || kebab.count < 3 {
            return "teammate-" + UUID().uuidString.prefix(4).lowercased()
        }
        return String(kebab.prefix(40))
    }

    private static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.prefix(120))
    }

    /// "just now" / "3 m ago" / "2 h ago" — the roster only carries a timestamp.
    static func relativeTime(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds > 0 else { return "never" }
        let seconds = Date().timeIntervalSince1970 - milliseconds / 1000
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    /// One readable line for a failed call: the host's code first, because that is
    /// what tells the model whether retrying can help.
    private static func describe(_ error: Error) -> String {
        guard let remote = error as? DSHRemoteError else { return error.localizedDescription }
        if remote.code == "team/unavailable" {
            return "that computer does not have the teammate feature (team/unavailable)."
        }
        return "\(remote.code): \(remote.message)"
    }
}
