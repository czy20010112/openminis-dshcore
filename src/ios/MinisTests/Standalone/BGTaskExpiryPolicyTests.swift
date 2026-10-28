#!/usr/bin/env swift
// [T-bgnotif-outcome] A task that did not finish was notified "✅ completed"
// (user report: a task ended by a lost network showed "task completed").
// endBackgroundProcessing decided success from `messages.last?.error` alone, so three
// endings slipped through as completed: the background-task expiry, the context-full
// stop, and an error on the turn's assistant row with a queued row after it.
//
// PORTED FROM upstream 1.15:src/ios/MinisTests/Standalone/BackgroundTurnOutcomeTests.swift
// Renamed on the way in: this tree's type is `BGTaskExpiryPolicy`, and it lives in
// `Agent/Background/BackgroundKeepAliveManager.swift` — not inside an
// `Agent/Chat/AIChatViewModel+BackgroundTask.swift` BEGIN/END block, and with no
// BEGIN/END markers at all. The decision table is identical:
//
//   enum BGTaskExpiryPolicy { enum Action { case endOnly, rearm, suspend }
//     static func decide(continuedTaskRunning:keepAliveConfigured:silentAudioPlaying:) -> Action }
//
// Other changes, each deliberate:
//   * the "agent loop" guard is GONE — `Agent/Chat/AIChatViewModel+AgentLoop.swift` is
//     upstream's file split and was not ported. Removed rather than left empty.
//   * the strings-in-catalog loop is GONE for the same reason as in
//     ContinuedCardStatusTests: untranslated keys are not a defect today. See
//     PORT-NOTES.md.
//
// The table is asserted as PROPERTIES plus a distribution, not by re-typing the
// implementation: a copy of `decide` inside the test would agree with itself no matter
// which side is wrong.
//
// Run: swift BGTaskExpiryPolicyTests.swift   (needs swiftc; macOS only — it calls xcrun)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

// MARK: - the tree this script reads, and proof that it found it
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

var filesRead = 0
var linesRead = 0
func source(_ rel: String) -> String {
    let url = iosRoot.appendingPathComponent(rel)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        print("  ❌ could not read \(rel) under \(iosRoot.path)")
        failures += 1
        return ""
    }
    filesRead += 1
    linesRead += text.split(separator: "\n", omittingEmptySubsequences: false).count
    return text
}

print("[0] the tree this script reads")
let rootPath = iosRoot.standardizedFileURL.path
let looksRight = rootPath.hasSuffix("/OpenMinis-iOS26/src/ios")
check("root resolves to …/OpenMinis-iOS26/src/ios  (got \(rootPath))", looksRight)
if !looksRight {
    print("❌ wrong tree — put this file back in src/ios/MinisTests/Standalone/")
    exit(1)
}

/// The `enum BGTaskExpiryPolicy { … }` block, brace-balanced. There are no BEGIN/END
/// markers around it in this tree, so the block is taken by structure.
func balancedBlock(_ s: String, from token: String) -> String? {
    guard let r = s.range(of: token), let open = s.range(of: "{", range: r.upperBound..<s.endIndex) else { return nil }
    var depth = 0
    var i = open.lowerBound
    while i < s.endIndex {
        let c = s[i]
        if c == "{" { depth += 1 }
        else if c == "}" {
            depth -= 1
            if depth == 0 { return String(s[r.lowerBound..<s.index(after: i)]) }
        }
        i = s.index(after: i)
    }
    return nil
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let bka = source("Agent/Background/BackgroundKeepAliveManager.swift")
guard let policy = balancedBlock(bka, from: "enum BGTaskExpiryPolicy {") else {
    print("❌ BGTaskExpiryPolicy enum not found"); exit(1)
}

print("[1] the decision table")
let harness = """
import Foundation
\(policy)

var fails = 0
func CHECK(_ l: String, _ c: Bool) { print(c ? "  ✅ \\(l)" : "  ❌ \\(l)"); if !c { fails += 1 } }
typealias A = BGTaskExpiryPolicy.Action

var endOnly = 0, rearm = 0, suspend = 0
var continuedNeverSuspends = true
var rearmOnlyWhenAudioReal = true
var suspendsTheRest = true

for c in [false, true] {
  for k in [false, true] {
    for s in [false, true] {
      let a = BGTaskExpiryPolicy.decide(continuedTaskRunning: c, keepAliveConfigured: k, silentAudioPlaying: s)
      switch a { case .endOnly: endOnly += 1; case .rearm: rearm += 1; case .suspend: suspend += 1 }
      // P1: while a continued-processing task holds the app, NEVER re-arm or suspend.
      // That is the failure the report is about: the system kills an app that still
      // holds an assertion when the time runs out.
      if c && a != .endOnly { continuedNeverSuspends = false }
      // P2: re-arm only when no continued task is up AND the audio is really playing
      // AND the setting allows it. The setting alone is not enough.
      if a == .rearm && !(k && s && !c) { rearmOnlyWhenAudioReal = false }
      // P3: everything else suspends, so the loop resumes in the foreground.
      if a == .suspend && (c || (k && s)) { suspendsTheRest = false }
    }
  }
}

CHECK("a continued task never re-arms or suspends (P1)", continuedNeverSuspends)
CHECK("re-arm only with the setting ON, audio really playing, and no continued task (P2)", rearmOnlyWhenAudioReal)
CHECK("everything else suspends (P3)", suspendsTheRest)
CHECK("exactly 4 of 8 end-only", endOnly == 4)
CHECK("exactly 1 of 8 re-arms", rearm == 1)
CHECK("exactly 3 of 8 suspend", suspend == 3)
CHECK("skipped keep-alive is not re-armed even with audio",
      BGTaskExpiryPolicy.decide(continuedTaskRunning: false, keepAliveConfigured: false, silentAudioPlaying: true) == A.suspend)
CHECK("configured but silent is not re-armed",
      BGTaskExpiryPolicy.decide(continuedTaskRunning: false, keepAliveConfigured: true, silentAudioPlaying: false) == A.suspend)
CHECK("the continued task wins over a perfectly good re-arm",
      BGTaskExpiryPolicy.decide(continuedTaskRunning: true, keepAliveConfigured: true, silentAudioPlaying: true) == A.endOnly)
exit(fails == 0 ? 0 : 1)
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("expiry-policy-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("main.swift"), bin = tmp.appendingPathComponent("h").path
try? harness.write(to: src, atomically: true, encoding: .utf8)
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", bin])
check("the policy block compiles standalone", cc == 0)
if cc != 0 { print(ccOut) } else {
    let (status, out) = run(bin, [])
    print(out, terminator: "")
    check("every policy check passes", status == 0 && !out.contains("❌"))
}

print("[2] source guards")
let bgTask = source("Agent/Chat/AIChatViewModel+BackgroundTask.swift")
check("the expiry handler asks the policy instead of deciding alone",
      bgTask.contains("BGTaskExpiryPolicy.decide("))
check("the three inputs are the kept-alive state, not a guess",
      bgTask.contains("continuedTaskRunning: keepAlive.continuedTaskRunning")
      && bgTask.contains("keepAliveConfigured: keepAlive.enhancedBackgroundEffective")
      && bgTask.contains("silentAudioPlaying: keepAlive.silentAudioIsPlaying"))
check("the first two actions are handled explicitly",
      bgTask.contains("== .endOnly") && bgTask.contains("== .rearm"))
// `.suspend` is the FALL-THROUGH, not an explicit comparison: after the two branches
// above, the handler suspends the loop instead of cancelling it. Asserting
// `== .suspend` finds zero hits in this tree - it would have been a false red.
check("the third action is the fall-through: the loop is suspended, not cancelled",
      bgTask.contains("self.backgroundSuspended = true")
      && bgTask.contains("suspending agent loop"))

// Not asserted here, deliberately: `Agent/Chat/AIChatViewModel+AgentLoop.swift` is not
// part of this tree, so upstream's guard about the loop cannot be ported with it.

print("[3] what this run actually read")
print("  files=\(filesRead) lines=\(linesRead)")
check("read at least 2 source files", filesRead >= 2)
check("read at least 200 lines", linesRead >= 200)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
