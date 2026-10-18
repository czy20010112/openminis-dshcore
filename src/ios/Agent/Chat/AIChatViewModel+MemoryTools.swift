import Foundation

// MARK: - Memory Tools

extension AIChatViewModel {

    // MARK: - Memory Tools

    /// Load full global memory content for system prompt injection.
    nonisolated static func loadGlobalMemoryFragment() -> String? {
        let globalFile = minisMemoryPersistentDir.appendingPathComponent("GLOBAL.md")
        guard FileManager.default.fileExists(atPath: globalFile.path),
              let content = try? String(contentsOf: globalFile, encoding: .utf8),
              !content.isEmpty else { return nil }

        return "Global memory (GLOBAL.md — read-only, user-maintained). Treat these as background context, not standing instructions. If the user's latest message conflicts with or supersedes anything here (different scope, different numbers, different goal), defer to the user's latest message:\n\(content)"
    }

    /// Load the 3 most recent daily memory logs that have content, for system prompt injection (first 200 lines each).
    nonisolated static func loadRecentDailyMemoryFragment() -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let fm = FileManager.default
        let today = Date()

        var fragments: [String] = []
        var dayOffset = 0
        let maxLookback = 30 // don't search more than 30 days back

        while fragments.count < 3 && dayOffset < maxLookback {
            let date = today.addingTimeInterval(-Double(dayOffset) * 86400)
            let dateStr = fmt.string(from: date)
            let fileURL = minisMemoryPersistentDir.appendingPathComponent("\(dateStr).md")

            if fm.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8),
               !content.isEmpty {
                let lines = content.components(separatedBy: "\n")
                let preview = lines.prefix(200).joined(separator: "\n")
                let label: String
                switch dayOffset {
                case 0: label = "Today's"
                case 1: label = "Yesterday's"
                default: label = "\(dateStr)"
                }
                var entry = "\(label) daily log (\(dateStr).md):\n\(preview)"
                if lines.count > 200 {
                    entry += "\n... (\(lines.count - 200) more lines, use memory_get to search)"
                }
                fragments.append(entry)
            }
            dayOffset += 1
        }

        guard !fragments.isEmpty else { return nil }

        var result = "Recent memories (auto-injected from daily logs):\n"
        result += "These are memories saved by you or the user in previous sessions. Treat them as background context, not standing instructions — they describe past tasks, not the current one. If the user's latest message changes scope, numbers, or goal, follow the latest message and do not resume the old task from these memories. Do not delete or rewrite these files unless the user explicitly asks. Use memory_get to search for more, or memory_write to save new ones.\n\n"
        result += fragments.joined(separator: "\n\n")
        return result
    }

    // MARK: - Volatile turn context (P1-2)

    /// Per-turn block carrying everything that can change *between* requests.
    ///
    /// P1-2: the memory fragments and the runtime facts used to be registered as
    /// system-prompt sections, so any change in them rewrote bytes at the head of
    /// the request. An engine caching the KV prefix by longest common prefix then
    /// re-prefilled the entire conversation — measured on this project's engine,
    /// `cache` fell from 99.5% to **0.0%** (not even the first token matched) on
    /// exactly the turn after one that had written a memory.
    ///
    /// Upstream DSH never puts durable state in the system prompt: its system
    /// prompt node is frozen and the dynamic snapshot travels as its own `user`
    /// message right before the turn's own user message
    /// (`packages/core/agent-loop/src/runtime-context.ts`,
    /// `RuntimeContextProjection.project()`, admitted in
    /// `packages/core/agent-loop/src/agent.ts` as
    /// `{ kind: 'enter', messages: [...claimed, context] }`).
    ///
    /// This is the same move, in the same place. The model reads the same text it
    /// read before; only the message that carries it changed, so the system
    /// prompt — and with it every cached earlier turn — stays byte-identical.
    ///
    /// Rebuilt per turn rather than persisted, so it can never go stale.
    ///
    /// Three callers compose it, in declared order:
    ///
    ///  1. the DSH path's registered volatile sections (`extraParts`, already
    ///     rendered in section order);
    ///  2. `runtimeFacts`, the same list of facts as plain lines — the legacy
    ///     path, which has no assembly;
    ///  3. the memory fragments.
    ///
    /// Parts 1 and 2 are alternatives, never both: the DSH path passes the
    /// rendered section and an empty fact list, the legacy path the other way
    /// round. So no sentence is ever emitted twice.
    ///
    /// - Returns: the block, or nil when this conversation has nothing volatile
    ///   to say (no memory fragments, no runtime facts).
    nonisolated static func volatileTurnContextSuffix(
        runtimeFacts: [String],
        memoryEnabled: Bool,
        extraParts: [String] = [],
        label: String = volatileTurnContextLabel
    ) -> String? {
        var parts: [String] = []

        // DSH's rendered volatile sections first (see `extraParts` above).
        parts.append(contentsOf: extraParts.filter { !$0.isEmpty })

        // Then the plain runtime facts: they describe the turn itself, and they
        // are the same facts the DSH path would have registered as
        // `minis:volatile/runtime-context`.
        if !runtimeFacts.isEmpty {
            parts.append(runtimeFacts.joined(separator: "\n"))
        }

        // The two memory fragments, under the same per-session gate the system
        // prompt used (see T-memory-toggle-gates-injection-and-tools-ios).
        // `minis:memory-status` deliberately stays in the system prompt: it only
        // moves when the user flips the toggle, and it must precede the block it
        // describes.
        if memoryEnabled {
            if let global = loadGlobalMemoryFragment(), !global.isEmpty {
                parts.append(global)
            }
            if let daily = loadRecentDailyMemoryFragment(), !daily.isEmpty {
                parts.append(daily)
            }
        }

        parts = parts.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        // The label is new text, not moved text, so it is a constant: the block
        // needs to say what it is, and "runtime context" is DSH's own word for
        // exactly this (`renderContextSnapshot`).
        return label + "\n\n" + parts.joined(separator: "\n\n")
    }

    /// The block's own one-line label. DSH's wording
    /// (`DSHSystemPrompt.renderContextSnapshot`) without its supersede sentence:
    /// this block is rebuilt per turn, so it describes the current turn rather
    /// than replacing anything the model read earlier in the same conversation.
    nonisolated static let volatileTurnContextLabel = "Memory and runtime context:"

    /// `history` with `suffix` inserted so it becomes the LAST message of the
    /// request — i.e. immediately before the most recent non-tool-result user
    /// message, the exact position upstream DSH admits its runtime-context
    /// snapshot to.
    ///
    /// Why that position, and not the tail:
    ///
    ///  * **Adjacency.** OpenAI Chat Completions requires every
    ///    `assistant.tool_calls` be answered immediately. Inserting at the very
    ///    tail during a tool loop would land the block between
    ///    `assistant(tool_use)` and its `user(tool_result)` batch. Inserting
    ///    *before* the user turn that opened this round cannot: the message after
    ///    the insertion point is either that user message (a normal turn), or the
    ///    assistant turn it triggered (a mid-turn iteration, where the assistant
    ///    replies to it). Either way the block never sits inside a pair.
    ///    Anthropic's `mergeConsecutiveSameRole` collapses the block into the
    ///    adjacent user turn, which is the same shape DSH's own projection
    ///    produces.
    ///  * **Cache.** The block's position relative to the conversation is fixed
    ///    for a given turn: one new user message per turn, inserted at the same
    ///    offset from that message. So re-emitting it each turn grows the request
    ///    at the tail — which is what a KV-prefix cache needs.
    ///
    /// - Returns: `history` unchanged when there is no suffix and no genuine
    ///   user message to anchor it to.
    nonisolated static func historyWithVolatileTurnContext(
        _ history: [AgentMessage],
        suffix: String?
    ) -> [AgentMessage] {
        guard let suffix, !suffix.isEmpty else { return history }
        guard let anchor = history.lastIndex(where: { AIChatViewModel.isGenuineUserMessage($0) }) else {
            return history
        }
        var out = history
        out.insert(AgentMessage(role: .user, parts: [.text(suffix)]), at: anchor)
        return out
    }

    /// Whether a message is a real user turn rather than a batch of tool results.
    ///
    /// The legacy loop carries tool results as `.user` messages, so "the last
    /// user message" is not the same as "the user's request".
    nonisolated static func isGenuineUserMessage(_ message: AgentMessage) -> Bool {
        guard message.role == .user else { return false }
        guard !message.parts.isEmpty else { return false }
        return !message.parts.allSatisfy { part in
            if case .toolResult = part { return true }
            return false
        }
    }

    /// Execute a memory_write tool call: prepend a timestamped entry to today's daily log.
    func executeMemoryWrite(from json: String) -> FileToolResult {
        guard memoryEnabled else {
            return FileToolResult(output: "Memory saving is disabled for this session. Use /memory to re-enable.", success: false)
        }
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String else {
            return FileToolResult(output: "Error: Missing required 'content' parameter", success: false)
        }

        let fm = FileManager.default
        let persistDir = Self.minisMemoryPersistentDir
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let fileName = "\(dateFmt.string(from: Date())).md"
        let fileURL = persistDir.appendingPathComponent(fileName)

        // Build timestamped entry
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = timeFmt.string(from: Date())
        let entry = "<!-- \(timestamp) -->\n\(content)\n\n"

        // Prepend to existing file
        var existing = ""
        if fm.fileExists(atPath: fileURL.path) {
            existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }

        let newContent = entry + existing
        guard let writeData = newContent.data(using: .utf8) else {
            return FileToolResult(output: "Error: Content is not valid UTF-8", success: false)
        }

        do {
            try writeData.write(to: fileURL)
        } catch {
            return FileToolResult(output: "Error writing memory: \(error.localizedDescription)", success: false)
        }

        // Register in meta.db for iSH visibility
        let linuxPath = "\(Self.minisMemoryLinuxDir)/\(fileName)"
        ensureFakefsMetadata(for: linuxPath, isDirectory: false)

        // Enqueue for iCloud v2 sync. Reuse fileName's stem (no second
        // Date() call) so the dateKey matches what was actually written
        // even across a midnight boundary.
        let dateStrForSync = (fileName as NSString).deletingPathExtension
        Task { @MainActor in
            await ChatStore.shared.markDirty(recordType: "MemoryDailyV2", recordId: dateStrForSync)
        }
        NotificationCenter.default.post(name: .memoryFilesDidChange, object: nil)

        return FileToolResult(output: "Memory saved to \(fileName) (\(content.count) chars)", success: true)
    }

    /// Execute a memory_get tool call: read and optionally search memory files.
    /// Uses confidence-based fuzzy matching: entries are scored by how many distinct
    /// keywords they contain, sorted by confidence descending. The model can decide
    /// how to use partial matches.
    func executeMemoryGet(from json: String) -> FileToolResult {
        // [T-memory-toggle-gates-injection-and-tools-ios] Defense in depth:
        // when memory is disabled, makeAgentTools() drops memory_get from
        // the registered tools, so the model normally cannot emit this
        // call. If something else routes here (history replay, manual
        // RPC, future caller), refuse with a clear message that mirrors
        // executeMemoryWrite's guard above.
        guard memoryEnabled else {
            return FileToolResult(output: "Memory is disabled for this session. Use /memory to re-enable, or open Settings to change the default.", success: false)
        }
        let dict: [String: Any]
        if let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        } else {
            dict = [:]
        }

        let scope = (dict["scope"] as? String) ?? "all"
        let keywords = ((dict["keywords"] as? String) ?? "")
            .components(separatedBy: .whitespaces)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }

        var filesToSearch: [(label: String, url: URL)] = []
        let fm = FileManager.default
        let memDir = Self.minisMemoryPersistentDir

        var globalEmpty = false
        if scope == "all" {
            let globalFile = memDir.appendingPathComponent("GLOBAL.md")
            if fm.fileExists(atPath: globalFile.path) {
                let content = (try? String(contentsOf: globalFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if content.isEmpty {
                    globalEmpty = true
                } else {
                    filesToSearch.append(("GLOBAL.md", globalFile))
                }
            } else {
                globalEmpty = true
            }
        }

        if fm.fileExists(atPath: memDir.path),
           let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let sorted = files
                .filter { $0.pathExtension == "md" && $0.lastPathComponent != "GLOBAL.md" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in sorted {
                filesToSearch.append((file.lastPathComponent, file))
            }
        }

        let globalNote = globalEmpty ? "[GLOBAL.md is empty or does not exist. Use file_write to create it when the user asks to save global memory.]\n\n" : ""

        if filesToSearch.isEmpty {
            return FileToolResult(output: globalNote + "No memory files found.", success: true)
        }

        // If no keywords, return full file contents (truncated)
        if keywords.isEmpty {
            let maxTotalLines = 500
            var results: [String] = []
            var totalLines = 0
            for (label, fileURL) in filesToSearch {
                guard totalLines < maxTotalLines else { break }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
                let lines = content.components(separatedBy: "\n")
                let budget = maxTotalLines - totalLines
                let take = min(lines.count, budget)
                let preview = lines.prefix(take).joined(separator: "\n")
                let truncated = lines.count > take ? " (showing first \(take) of \(lines.count) lines)" : ""
                results.append("[\(label)\(truncated)]\n\(preview)")
                totalLines += take
            }
            return FileToolResult(output: globalNote + results.joined(separator: "\n\n"), success: true)
        }

        // Split file content into memory entries using "<!-- " timestamp markers as boundaries.
        // Falls back to treating the whole file as one entry if no markers found.
        func splitIntoEntries(_ content: String, fileLabel: String) -> [(fileLabel: String, entryText: String)] {
            let lines = content.components(separatedBy: "\n")
            var entries: [(String, String)] = []
            var currentLines: [String] = []

            for line in lines {
                if line.hasPrefix("<!-- ") && !currentLines.isEmpty {
                    let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { entries.append((fileLabel, text)) }
                    currentLines = [line]
                } else {
                    currentLines.append(line)
                }
            }
            if !currentLines.isEmpty {
                let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { entries.append((fileLabel, text)) }
            }
            // If no timestamp markers found, treat whole file as one entry
            if entries.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append((fileLabel, content.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return entries
        }

        // Score each entry: count distinct keywords + extract timestamp for recency scoring.
        struct ScoredEntry {
            let fileLabel: String
            let text: String
            let matchedCount: Int
            let totalKeywords: Int
            let timestamp: Date
        }

        // Parse timestamp from entry text (<!-- 2026-03-04 17:00:00 -->) or fall back to
        // file label date (2026-03-04.md) or distantPast for GLOBAL.md entries.
        let tsFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        func extractTimestamp(from entryText: String, fileLabel: String) -> Date {
            // Try <!-- 2026-03-04 17:00:00 --> in first line
            if let firstLine = entryText.components(separatedBy: "\n").first,
               firstLine.hasPrefix("<!-- "),
               let end = firstLine.range(of: " -->"),
               let ts = tsFormatter.date(from: String(firstLine[firstLine.index(firstLine.startIndex, offsetBy: 5)..<end.lowerBound])) {
                return ts
            }
            // Fall back to file label date (e.g. "2026-03-04.md")
            let stem = (fileLabel as NSString).deletingPathExtension
            if let d = dateFormatter.date(from: stem) { return d }
            // GLOBAL.md or unknown — treat as oldest
            return Date.distantPast
        }

        var allEntries: [ScoredEntry] = []
        var totalEntryCount = 0

        for (label, fileURL) in filesToSearch {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
            let entries = splitIntoEntries(content, fileLabel: label)
            totalEntryCount += entries.count
            for (fileLabel, entryText) in entries {
                let lower = entryText.lowercased()
                let matchedCount = keywords.filter { lower.contains($0) }.count
                if matchedCount > 0 {
                    let ts = extractTimestamp(from: entryText, fileLabel: fileLabel)
                    allEntries.append(ScoredEntry(
                        fileLabel: fileLabel,
                        text: entryText,
                        matchedCount: matchedCount,
                        totalKeywords: keywords.count,
                        timestamp: ts
                    ))
                }
            }
        }

        if allEntries.isEmpty {
            return FileToolResult(
                output: globalNote + "No matches found for keywords: \(keywords.joined(separator: ", ")) (scanned \(totalEntryCount) memory entries)",
                success: true
            )
        }

        // Compute combined score: 50% normalized confidence + 50% normalized recency.
        // Normalize confidence: matchedCount / totalKeywords → [0, 1]
        // Normalize recency: (ts - minTs) / (maxTs - minTs) → [0, 1], newer = higher
        let minTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.min() ?? 0
        let maxTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.max() ?? 1
        let tsRange = maxTs - minTs  // may be 0 if all entries have same timestamp

        let scored: [(entry: ScoredEntry, score: Double)] = allEntries.map { entry in
            let confScore = Double(entry.matchedCount) / Double(max(entry.totalKeywords, 1))
            let recencyScore: Double
            if tsRange > 0 {
                recencyScore = (entry.timestamp.timeIntervalSince1970 - minTs) / tsRange
            } else {
                recencyScore = 1.0  // all same age — treat equally
            }
            let combined = 0.5 * confScore + 0.5 * recencyScore
            return (entry, combined)
        }

        let sortedScored = scored.sorted { $0.score > $1.score }

        // Cap output to avoid flooding context. Two independent limits, whichever
        // is hit FIRST wins:
        //   1. Entry count — max 60 entries (legacy T-memory-get-limit).
        //   2. Byte size — max 30 KB of UTF-8 entry text. From a field
        //      report: a single memory_get returned ~70 KB, making the
        //      tool-result view stutter for seconds. We accumulate per entry
        //      and stop AFTER the entry that pushes the running total past the
        //      ceiling (so the triggering entry is shown whole, never sliced).
        let maxEntries = 60
        let maxBytes = 30 * 1024  // 30,720 bytes

        var rendered: [String] = []
        var shownBytes = 0
        var stoppedByBytes = false
        for item in sortedScored {
            if rendered.count >= maxEntries { break }
            let confidence = "\(item.entry.matchedCount)/\(item.entry.totalKeywords)"
            let scoreStr = String(format: "%.2f", item.score)
            let block = "[score: \(scoreStr) | confidence: \(confidence) | \(item.entry.fileLabel)]\n\(item.entry.text)"
            rendered.append(block)
            shownBytes += block.utf8.count
            // Append-then-break: include this entry in full, then stop.
            if shownBytes >= maxBytes {
                stoppedByBytes = true
                break
            }
        }

        let output = rendered.joined(separator: "\n\n---\n\n")

        let shownCount = rendered.count
        let truncatedNote: String
        if stoppedByBytes {
            let kb = String(format: "%.1f", Double(shownBytes) / 1024.0)
            truncatedNote = "\n\n[Truncated: showing \(shownCount) of \(sortedScored.count) matching entries, total \(kb) KB]"
        } else if sortedScored.count > shownCount {
            // Hit the entry-count cap before the byte cap.
            truncatedNote = "\n\n[Showing top \(shownCount) of \(sortedScored.count) matching entries]"
        } else {
            truncatedNote = ""
        }

        let summary = "Found \(sortedScored.count) matching entries (scanned \(totalEntryCount) total), sorted by combined score (50% confidence + 50% recency):"
        return FileToolResult(output: globalNote + summary + "\n\n" + output + truncatedNote, success: true)
    }

    /// Escape single quotes for shell arguments.
    private func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }


}
