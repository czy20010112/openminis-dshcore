//
//  DSHSpillHook.swift
//  Minis
//
//  Wiring for the tool-result spill: the policy decision (`DSHSpill`), the
//  storage (`DSHSpillStore`), and the app-side facts only they are missing —
//  which bucket to write into and how a result's image is dropped.
//
//  The hook type itself lives here because the scheduler has to name it, and the
//  scheduler is `src/ios/DSH/` code that must stay free of `AIChatViewModel`.
//  The install site is the extension at the bottom of this file: the view model
//  hands the driver a closure, and the driver runs it on every settled tool
//  result before that result reaches the session.
//
//  WHY A HOOK AND NOT A CALL SITE
//  ------------------------------
//  DSH reaches the same behaviour through a plugin listener on
//  `tools/post-execute` — an extension point, not an edit inside the tool loop.
//  Here the extension point is one closure on the driver, installed where the
//  turn is set up. So this feature adds no branch to the tool path and can be
//  turned off without touching it: with no configuration the hook is never
//  installed and the scheduler's `applyOverflow` is nil.
//

import Foundation

/// Post-execute handler for an oversized tool result.
///
/// Runs after the tool settled and before the result is published to the
/// ordered committer. Returns the result the model should receive, or nil to
/// leave it untouched.
///
/// The hook is responsible for writing the complete result before it returns:
/// whatever it does not write is gone, because the caller keeps no copy of the
/// original.
public typealias DSHResultOverflowHook = @MainActor (DSHToolCallBlock, DSHToolExecutionResult) async -> DSHToolExecutionResult?

// MARK: - Feature

/// The app-side entry point for spill.
///
/// Kept separate from `DSHSpillConfig` so the settings question ("is it on, and
/// with what budget") stays answerable without a view model, and separate from
/// `DSHSpillStore` so the storage question ("where does the file go") stays
/// answerable without a policy.
public enum DSHSpillFeature {

    /// The configuration in force, or nil while the feature is off.
    ///
    /// Read per call rather than cached: a turn is a long-lived thing and the
    /// value is cheap to read, whereas a cached copy would keep a stale budget
    /// for the rest of the process after the setting changed.
    public static var config: DSHSpillConfig? {
        DSHSpillConfig.resolvedFromDefaults()
    }

    /// Build the hook the driver runs, or nil while the feature is off.
    ///
    /// - Parameter sessionId: the conversation whose bucket the spill files land
    ///   in. Captured, not read later: the view model's `sessionId` can change
    ///   under a running turn (the user switches conversations), and a spill file
    ///   written into the wrong session's bucket is unreachable from the notice.
    /// - Parameter offloadsRoot: host URL of that session's `offloads` bucket.
    /// - Returns: the hook, or nil when no budget is configured.
    public static func makeHook(sessionId: String, offloadsRoot: URL) -> DSHResultOverflowHook? {
        guard let config = config, let budget = config.effectiveBudget else { return nil }
        let directory = DSHSpillStore.sessionDirectory(sessionId: sessionId, offloadsRoot: offloadsRoot)
        // One sweep per process, kicked off the first time a spill is actually
        // possible — never at launch, where the subtree usually does not exist.
        DSHSpillStore.sweepExpiredOnce(offloadsRoot: offloadsRoot, cleanupPeriodDays: config.cleanupPeriodDays)
        // Best-effort: `DSHSpillStore.write` creates the directory itself and
        // reports failure by returning nil, which the hook below already treats as
        // "storage unavailable". Swallowing the error here keeps a full disk or a
        // missing mount from turning a tool result into a thrown turn.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A probe build's whole purpose is to answer "is this package the one that
        // spills?" from the log alone, without hunting for a decision line that may
        // never come. So say it when the hook is installed, not only when it fires.
        if DSHSpillConfig.probeEnabled {
            AppLogger(category: "DSHSpill").warning(
                "[DSHSpill] probe build — budget forced to \(budget) tokens, folder \(DSHSpillStore.offloadsDisplayPath)"
            )
        }

        return { block, result in
            let text = result.content
            guard !text.isEmpty else { return nil }

            // DSH's unit is tokens. The log line reports the estimate so a device
            // session can be checked against the threshold from the log alone.
            let tokens = DSHSpill.tokenEstimate(text)
            var content: [DSHSpillContent] = [.text(text)]
            if result.imageData != nil { content.append(.image) }

            guard let planned = DSHSpill.plan(
                toolName: block.name,
                content: content,
                budget: budget,
                locatorPlaceholder: DSHSpill.locatorPlaceholder,
                imageTokens: config.imageTokens
            ) else { return nil }

            // The complete result has to be on disk before the notice naming it
            // is, so the model can never be handed a path to nothing.
            var locator = ""
            if let saved = DSHSpillStore.write(
                text: text,
                toolName: block.name,
                sessionId: sessionId,
                offloadsRoot: offloadsRoot,
                cleanupPeriodDays: config.cleanupPeriodDays
            ) {
                locator = saved.linuxPath
            } else if result.imageData != nil, let stated = result.imageLinuxPath {
                // Text could not be written, but the result's own image already
                // has a durable path — point the notice at that rather than at a
                // locator that does not exist.
                locator = stated
            } else {
                // Storage unavailable. DSH's contract for this case is to keep
                // the inline content and report the reason, never to hand the
                // model a pointer to a file that was not written.
                AppLogger(category: "DSHSpill").warning(
                    "[DSH][Spill] storage unavailable for tool=\(block.name) id=\(block.id) — keeping the inline result"
                )
                return nil
            }

            let bound = DSHSpill.binding(planned, to: locator)
            AppLogger(category: "DSHSpill").warning(
                DSHSpill.logLine(
                    toolName: block.name,
                    callId: block.id,
                    tokens: tokens,
                    omittedBytes: bound.omittedBytes,
                    locator: locator,
                    keptChars: bound.text.count,
                    priorLocator: bound.priorLocator
                )
            )
            // The one line every shortening leaves, in one shape, so "was this
            // result shortened, and was the model told" is answerable from a device
            // log without knowing which mechanism did it. This pass always notifies:
            // the notice is part of `bound.text`, which is what the model receives.
            AppLogger(category: "ToolResult").warning(
                DSHSpill.truncationLogLine(
                    toolName: block.name,
                    callId: block.id,
                    mechanism: "spill",
                    originalChars: text.count,
                    keptChars: bound.text.count,
                    locator: locator,
                    notified: true
                )
            )

            var bounded = result
            bounded.content = bound.text
            if bound.imageDropped {
                // The image did not fit in the retained ends, so it is dropped
                // whole — and the result's own pixels go with it, or the request
                // would carry an image the notice just claimed to have omitted.
                // Its bytes are written to the same bucket so `read_image` can
                // still reach them.
                if let data = result.imageData {
                    let savedImage = DSHSpillStore.writeImage(
                        data: data,
                        toolName: block.name,
                        sessionId: sessionId,
                        offloadsRoot: offloadsRoot,
                        fileExtension: imageExtension(for: result.imageMimeType)
                    )
                    bounded.imageLinuxPath = savedImage?.linuxPath ?? result.imageLinuxPath
                }
                bounded.imageData = nil
                bounded.imageMimeType = nil
            }
            return bounded
        }
    }

    /// File extension for a media type, defaulting to `bin`.
    public static func imageExtension(for mimeType: String?) -> String {
        switch (mimeType ?? "").lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        default: return "bin"
        }
    }
}

// MARK: - Install Site

extension AIChatViewModel {

    /// Hand the driver a spill hook built from the live session.
    ///
    /// Called once per turn, where the driver is constructed. Passing nil while
    /// the feature is unconfigured is what keeps the default path byte-for-byte
    /// what it was: the scheduler skips the hook entirely.
    ///
    /// - Parameter driver: the driver for the turn about to run.
    func dshInstallSpillHook(on driver: DSHTurnDriver) {
        guard let sid = sessionId else {
            driver.spillHook = nil
            return
        }
        let root = Self.minisOffloadsPersistentDir(for: sid)
        driver.spillHook = DSHSpillFeature.makeHook(sessionId: sid, offloadsRoot: root)
    }
}
