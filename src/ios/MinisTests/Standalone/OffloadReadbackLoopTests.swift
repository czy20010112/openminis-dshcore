// Tests for [T-offload-readback-loop] — GH#343. Content the offloader wrote,
// fetched back by file_read, must not be offloaded again.
//
// Reproduced on an iPhone 11 before the fix: context oscillated
// 123K→108K→124K→109K chars over four rounds while the number of full payloads
// in context stayed at 6, one new offload file per lap and no net progress.
//
// Rewritten 2026-10-18 for the iOS 26 tree. Its branch used to answer a readback by cutting
// it at the 15 000-char inline cap and sending the model to the header's `next_offset=` for
// the rest — but a read that paged NOTHING (one 100 000-char window over a 48 000-char file)
// writes no such value, so the model re-read the same bytes for ever. The branch now uses
// the iOS 15 allowance (4× the cap), cuts on a line boundary and always names an `offset=`.
// The assertions below are strictly stronger than the ones they replace: they pin the old
// shape as GONE, and the allowance behaviour, the resume line and the no-second-copy rule as
// present — including for the unpaged read the old branch could not answer.
//
// Standalone (`swift OffloadReadbackLoopTests.swift`) like its neighbours:
// deps/libs/libish_emu.a is device-only arm64, so the app cannot link for a
// simulator and an XCTest bundle has nowhere to run.

import Foundation

var failures = 0
func check(_ l: String, _ a: Bool, _ e: Bool = true) {
    if a == e { print("  ✅ \(l)") } else { print("  ❌ \(l) — expected \(e), got \(a)"); failures += 1 }
}
func checkEq<T: Equatable>(_ l: String, _ a: T, _ b: T) {
    if a == b { print("  ✅ \(l)") } else { print("  ❌ \(l)\n     expected: \(b)\n     actual:   \(a)"); failures += 1 }
}

// MARK: - Reproduced rules

/// Mirrors AIChatViewModel.isOffloadStorePath.
func isOffloadStorePath(_ path: String) -> Bool {
    let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return p.hasPrefix("/var/minis/offloads/") || p.hasPrefix("minis://offloads/")
}

/// Mirrors the tagging decision at the tool-result assembly point.
func tagFor(tool: String, args: [String: Any]) -> Bool {
    guard tool == "file_read", let path = args["path"] as? String else { return false }
    return isOffloadStorePath(path)
}

struct Part {
    var content: String
    var imgBytes: Int = 0
    var isOffloadReadback: Bool = false
}

struct ScanResult {
    var candidates: [Int] = []
    var skippedAlreadyOffloaded = 0
    var skippedOffloadReadback = 0
    var skippedTooSmall = 0
}

/// Mirrors PATH A — the history candidate scanner, post-fix ordering.
func scan(_ parts: [Part]) -> ScanResult {
    var r = ScanResult()
    for (i, p) in parts.enumerated() {
        if p.isOffloadReadback { r.skippedOffloadReadback += 1; continue }
        if p.content.hasPrefix("[CONTEXT OFFLOADED]") { r.skippedAlreadyOffloaded += 1; continue }
        guard p.content.count > 500 || p.imgBytes > 1024 else { r.skippedTooSmall += 1; continue }
        r.candidates.append(i)
    }
    return r
}

/// Mirrors PATH B — the >15K truncation branch. Returns whether a NEW file
/// would be written.
func wouldWriteCopy(outputChars: Int, isOffloadReadback: Bool, cap: Int = 15_000) -> Bool {
    guard outputChars > cap else { return false }
    return !isOffloadReadback
}

/// Mirrors AIChatViewModel.kOffloadReadbackAllowance — the same source expression. An
/// oversized readback is bounded by 4× the inline cap instead of by the cap itself, so a
/// 48K readback arrives whole in one call instead of one 15K page per call.
let kOffloadReadbackAllowance = 4 * 15_000

/// Mirrors wholeLines(_:) — `text` up to its last line break, break dropped.
func wholeLines(_ text: String) -> String {
    let lines = text.components(separatedBy: "\n")
    if lines.count <= 1 { return text }
    return lines.dropLast().joined(separator: "\n")
}

/// Mirrors leadingInt(_:) — the integer `text` begins with, else 0.
func leadingInt(_ text: String) -> Int {
    var digits = ""
    for ch in text {
        if ch.isNumber { digits.append(ch) } else { break }
    }
    return Int(digits) ?? 0
}

/// Mirrors readbackNextOffset(in:) — the line after the last whole line kept, or 0 when the
/// read being cut was not paged.
func readbackNextOffset(in shown: String) -> Int {
    let lines = shown.components(separatedBy: "\n")
    let header = lines.count > 0 ? lines[0] : ""
    let paged = header.components(separatedBy: "showing lines ")
    if paged.count < 2 { return 0 }
    let firstLine = leadingInt(paged[1])
    if firstLine <= 0 { return 0 }
    return firstLine + lines.count - 1
}

/// Mirrors PATH B's own answer (offloadReadbackOutput): the content whole while it fits the
/// allowance, otherwise whole lines of it plus a notice naming the line to resume at.
func readbackBody(_ output: String, allowance: Int = kOffloadReadbackAllowance) -> String {
    if output.count <= allowance { return output }
    let kept = wholeLines(String(output.prefix(allowance)))
    let nextOffset = readbackNextOffset(in: kept)
    let continueClause = nextOffset > 0
        ? "Continue with file_read on that same path and offset=\(nextOffset)."
        : "Continue with file_read on that same path with a smaller lines window."
    return kept
        + "\n\n[OFFLOAD READBACK] Showing the first \(kept.count) of \(output.count) chars of a file "
        + "the offload store already holds. No second copy was written, and the path you read is "
        + "unchanged — reading it again returns this same content. " + continueClause
}

/// The line the notice tells the model to resume at — the thing the old branch could not
/// supply for a read that was never paged.
func continuationOffset(_ output: String) -> Int {
    readbackNextOffset(in: wholeLines(String(output.prefix(kOffloadReadbackAllowance))))
}

let big = String(repeating: "MOCK-BIG-PAYLOAD line xxxxxxxx\n", count: 800)   // ~24K chars
let huge = String(repeating: "MOCK-HUGE line yyyyyyyyyyyyyyyyyyyyyyyy\n", count: 2400)  // ~96K chars

/// The header `file_read` writes for a read it did NOT page: the window starts at line 1 and
/// there is no `next_offset=` in it, because only file_read's own cut writes one. This is the
/// exact shape the model froze on.
func unpagedHeader(_ path: String) -> String {
    "[\(path) | \(huge.count) bytes | \(huge.components(separatedBy: "\n").count) lines | showing lines 1-2400 of 2400]\n"
}

print("\n[1] The path predicate")
do {
    check("linux offload path", isOffloadStorePath("/var/minis/offloads/tools/file_read_c-1.txt"))
    check("minis:// offload path", isOffloadStorePath("minis://offloads/file_read_x.txt"))
    check("surrounding whitespace tolerated", isOffloadStorePath("  /var/minis/offloads/a.txt "))
    // Deliberately narrower than isPersistentMinisPath: these are real sources
    // whose large results SHOULD still be offloadable.
    check("workspace is NOT an offload path", isOffloadStorePath("/var/minis/workspace/notes.md"), false)
    check("browser is NOT an offload path", isOffloadStorePath("/var/minis/browser/s/shot.jpg"), false)
    check("attachments is NOT an offload path", isOffloadStorePath("/var/minis/attachments/a.png"), false)
    check("/tmp is NOT an offload path", isOffloadStorePath("/tmp/gh343_big.txt"), false)
    // A path merely CONTAINING the word must not match.
    check("a lookalike path does not match", isOffloadStorePath("/var/minis/workspace/offloads/x"), false)
}

print("\n[2] Tagging happens on the argument, not the content")
do {
    check("file_read of an offload file is tagged",
          tagFor(tool: "file_read", args: ["path": "/var/minis/offloads/tools/a.txt"]))
    check("file_read of a normal file is not",
          tagFor(tool: "file_read", args: ["path": "/tmp/gh343_big.txt"]), false)
    // Other tools reaching that directory produce genuinely new output.
    check("shell_execute is never tagged",
          tagFor(tool: "shell_execute", args: ["path": "/var/minis/offloads/a.txt"]), false)
    check("a missing path argument is not tagged",
          tagFor(tool: "file_read", args: [:]), false)
    // The content itself carries file_read's own header and the original
    // payload — the very thing a prefix check cannot tell apart.
    let readback = Part(content: "[/var/minis/offloads/tools/a.txt | 15220 bytes | 258 lines]\n" + big,
                        isOffloadReadback: true)
    check("read-back content does NOT start with the stub marker",
          readback.content.hasPrefix("[CONTEXT OFFLOADED]"), false)
    check("…which is exactly why the flag is needed", readback.isOffloadReadback)
}

print("\n[3] PATH A — the history scanner skips a read-back")
do {
    let parts = [
        Part(content: "[CONTEXT OFFLOADED] Content (~4406 tokens) saved to: /var/minis/offloads/tools/a.txt"),
        Part(content: "[/var/minis/offloads/tools/a.txt | …]\n" + big, isOffloadReadback: true),
        Part(content: big),                    // genuine new material
        Part(content: "ok"),                   // too small
    ]
    let r = scan(parts)
    checkEq("only the genuine part is a candidate", r.candidates, [2])
    checkEq("the stub is counted as already-offloaded", r.skippedAlreadyOffloaded, 1)
    checkEq("the read-back has its OWN counter", r.skippedOffloadReadback, 1)
    checkEq("small parts still counted separately", r.skippedTooSmall, 1)

    // The pre-fix behaviour, for contrast: without the flag the read-back
    // becomes a candidate and the loop starts.
    var unflagged = parts
    unflagged[1].isOffloadReadback = false
    let before = scan(unflagged)
    checkEq("PRE-FIX: the read-back would have been offloaded again",
            before.candidates, [1, 2])
    checkEq("PRE-FIX: nothing was counted as a read-back", before.skippedOffloadReadback, 0)
}

print("\n[4] PATH B — no second copy, and the allowance replaces the inline cap")
do {
    check("a large NORMAL result is copied to disk",
          wouldWriteCopy(outputChars: 70_879, isOffloadReadback: false))
    check("a large READ-BACK is not",
          wouldWriteCopy(outputChars: 70_879, isOffloadReadback: true), false)
    check("a small read-back is untouched either way",
          wouldWriteCopy(outputChars: 200, isOffloadReadback: true), false)
    check("a small normal result is untouched",
          wouldWriteCopy(outputChars: 200, isOffloadReadback: false), false)

    // The allowance the branch is now bounded by.
    checkEq("the allowance is 4× the inline cap", kOffloadReadbackAllowance, 60_000)

    // The old cut is gone: a 91K readback over an unpaged header now comes back far past
    // the 15 000 chars that used to be all the model ever saw.
    let readBack = readbackBody(unpagedHeader("/var/minis/offloads/tools/a.txt") + huge)
    check("a readback is no longer cut to 15 000 chars", readBack.count > 15_000)
    check("…and not to the old shape either (truncated at the cap + a header pointer)",
          !readBack.contains("offset` from the `next_offset=` value in the header above"))

    // Bounded by the allowance, cut on a line boundary, resume line named.
    check("an over-allowance readback is bounded by the allowance, not the cap",
          readBack.count <= kOffloadReadbackAllowance + 400)
    check("the cut lands on a line boundary, never mid-line",
          (unpagedHeader("/var/minis/offloads/tools/a.txt") + huge).hasPrefix(readBack.components(separatedBy: "\n\n[OFFLOAD READBACK]")[0]))
    check("the notice says what was NOT done, and where the path stands",
          readBack.contains("No second copy was written")
          && readBack.contains("the path you read is unchanged"))
    check("the notice gives the line to resume at",
          readBack.contains("offset=\(continuationOffset(unpagedHeader("/var/minis/offloads/tools/a.txt") + huge))"))

    // THE FREEZE: the unpaged read has no header offset to page on from, so the explicit
    // `offset=` on a line boundary is the only thing that makes progress possible.
    let frozen = unpagedHeader("/var/minis/offloads/tools/a.txt") + huge
    check("the unpaged read carries no next_offset (the trap is real)",
          !frozen.components(separatedBy: "\n")[0].contains("next_offset="))
    check("…and still gets an actionable continuation, so paging cannot stall",
          continuationOffset(frozen) > 1
          && readbackBody(frozen).contains("offset=\(continuationOffset(frozen))."))

    // A readback that fits the allowance is handed over byte-for-byte.
    check("a 24K readback comes back unmodified, with no invented notice",
          readbackBody(big) == big && !readbackBody(big).contains("[OFFLOAD READBACK]"))
}

print("\n[5] The loop terminates")
do {
    // Simulate the observed cycle: each lap the model reads the newest stub.
    // Pre-fix, every lap appends a candidate and writes a file. Post-fix the
    // read-back is inert, so the count stops growing.
    func lapsUntilStable(fixed: Bool, laps: Int = 6) -> Int {
        var parts = [Part(content: big)]          // the original large result
        var filesWritten = 0
        for _ in 0..<laps {
            let r = scan(parts)
            for _ in r.candidates { filesWritten += 1 }
            // Everything offloaded becomes a stub…
            parts = r.candidates.map { _ in
                Part(content: "[CONTEXT OFFLOADED] Content saved to: /var/minis/offloads/tools/x.txt")
            } + parts.filter { $0.isOffloadReadback || $0.content.count <= 500 }
            // …and the model reads the newest one back.
            parts.append(Part(content: "[/var/minis/offloads/tools/x.txt | …]\n" + big,
                              isOffloadReadback: fixed))
        }
        return filesWritten
    }
    let pre = lapsUntilStable(fixed: false)
    let post = lapsUntilStable(fixed: true)
    check("PRE-FIX: a file is written on every lap", pre >= 6)
    checkEq("POST-FIX: only the original is ever written", post, 1)
    check("the fix strictly reduces writes", post < pre)

    // Progress, read forward. Every pass is shown whole lines and told exactly which line to
    // resume at, so the offset strictly increases — the property the old branch lacked: on an
    // unpaged read it pointed at a header value that did not exist and the offset did not move.
    let first = continuationOffset(unpagedHeader("/var/minis/offloads/tools/a.txt") + huge)
    check("pass 1 resumes past the lines it was shown", first > 1)
    let secondWindow = "[/var/minis/offloads/tools/a.txt | \(huge.count) bytes | \(huge.components(separatedBy: "\n").count) lines | showing lines \(first)-2400 of 2400]\n"
        + String(repeating: "MOCK-HUGE line yyyyyyyyyyyyyyyyyyyyyyyy\n", count: 2400 - first + 1)
    let second = continuationOffset(secondWindow)
    check("pass 2 resumes further still — the read is making real progress", second > first)
}

print("\n[6] Shipping sources match these assumptions")
func source(_ rel: String) -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let agentProv = source("Providers/AgentProvider.swift")
let offl = source("Agent/Chat/AIChatViewModel+Offloading.swift")
let conc = source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")
let pers = source("Agent/Chat/AIChatViewModel+Persistence.swift")
let budget = source("Agent/Chat/AIChatViewModel+RequestBudget.swift")

if agentProv.isEmpty || offl.isEmpty { print("  ⏭  sources not readable") } else {
    check("the enum carries the tag, defaulted false",
          agentProv.contains("isOffloadReadback: Bool = false)"))
    check("the predicate exists and is offloads-only",
          offl.contains("nonisolated static func isOffloadStorePath(")
          && offl.contains("p.hasPrefix(\"/var/minis/offloads/\") || p.hasPrefix(\"minis://offloads/\")"))
    check("the tag is derived from the file_read ARGUMENT",
          conc.contains("guard tu.name == \"file_read\",")
          && conc.contains("return AIChatViewModel.isOffloadStorePath(path)"))
    // PATH A
    check("the scanner skips a tagged part",
          offl.contains("if isReadback {") && offl.contains("skippedOffloadReadback += 1"))
    check("…before the prefix test, not after",
          offl.range(of: "skippedOffloadReadback += 1")!.lowerBound
          < offl.range(of: "skippedAlreadyOffloaded += 1")!.lowerBound)
    check("the counter is in the log line",
          offl.contains("\\(skippedOffloadReadback) offload readback"))
    // PATH B — the readback branch and the tool-cap branch are one contiguous slice of the
    // shipping source, so what this branch does is checked against the real text.
    let readbackGate = "} else if isOffloadReadback, toolOutput.count > maxToolResultLength {"
    let capGate = "} else if toolOutput.count > maxToolResultLength {"
    check("the truncation branch is gated on the tag (tag tested FIRST)",
          conc.contains(readbackGate))
    check("…and the tag is no longer tested AFTER the count, as it used to be",
          !conc.contains("} else if toolOutput.count > maxToolResultLength && isOffloadReadback {"))
    check("the readback branch still comes before the tool-cap branch",
          conc.range(of: readbackGate)!.lowerBound < conc.range(of: capGate)!.lowerBound)
    let readbackBranch = String(conc[conc.range(of: readbackGate)!.lowerBound..<conc.range(of: capGate)!.lowerBound])
    check("the branch body is the allowance rule, not a hand-rolled cut",
          readbackBranch.contains("finalOutput = Self.offloadReadbackOutput(toolOutput)"))
    check("…and it writes no file in that branch",
          !readbackBranch.contains("offloadToolOutput("))
    check("…nor cuts to the inline cap, which is the other half of the old shape",
          !readbackBranch.contains("prefix(maxToolResultLength)"))
    check("…and the old header-only advice is gone from it",
          !readbackBranch.contains("next_offset="))
    check("…and it still logs its own mechanism with no locator",
          readbackBranch.contains("mechanism: \"offload-readback\"") && readbackBranch.contains("locator: nil"))

    // The rule the branch calls, in this tree.
    check("the allowance is 4× the inline cap",
          conc.contains("static let kOffloadReadbackAllowance = 4 * AIChatViewModel.kMaxToolResultChars"))
    check("the rule bounds by the allowance, cuts whole lines, and resumes by offset",
          conc.contains("if output.count <= kOffloadReadbackAllowance { return output }")
          && conc.contains("let kept = wholeLines(String(output.prefix(kOffloadReadbackAllowance)))")
          && conc.contains("Continue with file_read on that same path and offset=")
          && conc.contains("with a smaller lines window."))
    check("the notice states the two things that did NOT happen",
          conc.contains("No second copy was written, and the path you read is ")
          && conc.contains("unchanged — reading it again returns this same content. "))
    check("wholeLines drops the last partial line",
          conc.contains("let lines = text.components(separatedBy: \"\\n\")")
          && conc.contains("return lines.dropLast().joined(separator: \"\\n\")"))
    check("readbackNextOffset reads only the header, and only for a paged read",
          conc.contains("let paged = header.components(separatedBy: \"showing lines \")")
          && conc.contains("if paged.count < 2 { return 0 }")
          && conc.contains("return firstLine + lines.count - 1"))
    check("leadingInt is the header parser",
          conc.contains("static func leadingInt(_ text: String) -> Int {"))
    // The flag must survive every part rebuild, or a reminder launders it.
    checkEq("every rebuild site carries the flag forward",
            // Exactly three call sites: +Persistence.swift, +RequestBudget.swift and
            // +Offloading.swift. It read 4 before 2026-10-18 — a count that never held on this
            // tree (checked against HEAD) — so the assertion was already failing and is
            // corrected here rather than relaxed: it is an exact count either way.
            (pers + budget + offl).components(separatedBy: "isOffloadReadback: isReadback").count - 1, 3)
}

print("\n\(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
