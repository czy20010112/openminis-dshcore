//
//  DSHToolHandlerImpl.swift
//  Minis
//
//  The DSH tool handlers, implemented over Minis' existing tool code.
//
//  The underlying implementations are untouched — `executeCommand`,
//  `executeFileRead`, `executeFileWrite`, `executeFileEdit`, the image reader and
//  the memory store. These adapters translate between the DSH tool argument
//  dictionary and the JSON those implementations already accept.
//
//  They pass the WHOLE argument dictionary through. The Minis tool
//  implementations were built around the model's raw JSON, so re-serialising the
//  dictionary is both the shortest adapter and the only one that cannot lose a
//  parameter: an adapter that reads the fields it happens to know about will
//  silently drop every field it does not, while the schema keeps advertising
//  them. That is exactly what happened here — `file_read` was passed only
//  `path`, so `offset`, `lines`, `direction` and `max_length` were advertised and
//  then ignored, and paging through a large file stopped working.
//

import Foundation
import UIKit

extension AIChatViewModel {

    /// Re-serialise a tool argument dictionary as the JSON the Minis tool
    /// implementations consume.
    func dshToolArgumentsJSON(_ args: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Run a shell command and return its captured output.
    func dshRunShell(args: [String: Any]) async -> DSHToolExecutionResult {
        let command = DSHToolArguments.string(args, "command", or: "")
        guard !command.isEmpty else {
            return DSHToolExecutionResult(content: "Error: empty command", isError: false)
        }
        let timeout = TimeInterval(DSHToolArguments.int(args, "timeout", or: 900))

        // The schema advertises `delay`; honour it. The wait happens before the
        // command is submitted, so the call still occupies its scheduler slot —
        // which is why `shell_execute` is declared `.exclusive`.
        let delay = DSHToolArguments.int(args, "delay", or: 0)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }

        do {
            let result = try await executeCommand(command, timeout: timeout) { _ in
                // Per-line streaming goes to the UI block through the existing
                // path; the DSH result carries the final captured output.
            }
            var out = result.output
            if result.exitCode != 0 {
                out += "\n[exit code: \(result.exitCode)]"
            }
            return DSHToolExecutionResult(content: out.isEmpty ? "(no output)" : out, isError: false)
        } catch {
            return DSHToolExecutionResult(content: "Error: \(String(describing: error))", isError: false)
        }
    }

    /// Read a file from the sandbox, honouring the paging parameters.
    func dshReadFile(args: [String: Any]) async -> DSHToolExecutionResult {
        do {
            let result = try await executeFileRead(from: dshToolArgumentsJSON(args))
            return DSHToolExecutionResult(content: result.output, isError: false)
        } catch {
            return DSHToolExecutionResult(content: "Error: read failed — \(String(describing: error))", isError: false)
        }
    }

    /// Write a file to the sandbox, honouring `create_dirs`.
    func dshWriteFile(args: [String: Any]) async -> DSHToolExecutionResult {
        do {
            let result = try await executeFileWrite(from: dshToolArgumentsJSON(args))
            return DSHToolExecutionResult(content: result.output, isError: false)
        } catch {
            return DSHToolExecutionResult(content: "Error: write failed — \(String(describing: error))", isError: false)
        }
    }

    /// Apply a targeted edit to a file.
    func dshEditFile(args: [String: Any]) async -> DSHToolExecutionResult {
        do {
            let result = try await executeFileEdit(from: dshToolArgumentsJSON(args))
            return DSHToolExecutionResult(content: result.output, isError: false)
        } catch {
            return DSHToolExecutionResult(content: "Error: edit failed — \(String(describing: error))", isError: false)
        }
    }

    /// Write a memory entry.
    func dshWriteMemory(args: [String: Any]) async -> DSHToolExecutionResult {
        // Driven through the existing JSON entry point so the daily-log layout
        // and timestamp format stay identical.
        let result = executeMemoryWrite(from: dshToolArgumentsJSON(args))
        return DSHToolExecutionResult(content: result.output, isError: false)
    }

    /// Read memories by keyword.
    func dshGetMemory(args: [String: Any]) async -> DSHToolExecutionResult {
        let result = executeMemoryGet(from: dshToolArgumentsJSON(args))
        return DSHToolExecutionResult(content: result.output, isError: false)
    }

    /// Read an image and hand it to the model.
    ///
    /// Two branches, exactly as the original loop has them:
    ///
    /// - a model with native vision gets the pixels, attached to its tool result;
    /// - a model without it only reaches this tool because a Vision Group is
    ///   configured to see images on its behalf, so the bytes go to that group
    ///   and its written description comes back as text. The image is
    ///   deliberately withheld on that branch: attaching pixels a text-only
    ///   model cannot decode is what providers silently drop.
    func dshReadImage(args: [String: Any], callId: String) async -> DSHToolExecutionResult {
        let pathArg = DSHToolArguments.string(args, "path", or: "")
        guard !pathArg.isEmpty else {
            return DSHToolExecutionResult(content: "Error: missing 'path'", isError: false)
        }
        guard let fileURL = await resolveMinisPath(pathArg) else {
            return DSHToolExecutionResult(content: "Error: invalid path: \(pathArg)", isError: false)
        }
        guard let fileData = try? Data(contentsOf: fileURL), let uiImage = UIImage(data: fileData) else {
            return DSHToolExecutionResult(content: "Error: could not read \(pathArg)", isError: false)
        }

        let originalSize = fileData.count
        let originalW = uiImage.cgImage.map { $0.width } ?? Int(uiImage.size.width)
        let originalH = uiImage.cgImage.map { $0.height } ?? Int(uiImage.size.height)

        let inferenceData: Data
        let resizedW: Int
        let resizedH: Int
        if let resized = Self.resizedImageData(fileData, maxLongEdge: 2000),
           let resizedImage = UIImage(data: resized) {
            inferenceData = resized
            resizedW = resizedImage.cgImage.map { $0.width } ?? Int(resizedImage.size.width)
            resizedH = resizedImage.cgImage.map { $0.height } ?? Int(resizedImage.size.height)
        } else {
            inferenceData = uiImage.jpegData(compressionQuality: 0.85) ?? fileData
            resizedW = originalW
            resizedH = originalH
        }

        // The durable sandbox path the model can re-fetch, distinct from a
        // minis:// URL or an absolute one.
        let linuxPath: String?
        if pathArg.hasPrefix("/var/minis/") {
            linuxPath = pathArg
        } else if pathArg.hasPrefix("minis://") {
            let tail = String(pathArg.dropFirst("minis://".count))
            linuxPath = tail.isEmpty ? nil : "/var/minis/\(tail)"
        } else {
            linuxPath = nil
        }

        var meta = "Image loaded successfully."
        meta += "\nPath: \(pathArg)"
        meta += "\nOriginal: \(originalW)x\(originalH), \(formatBytes(originalSize))"
        if resizedW != originalW || resizedH != originalH {
            meta += "\nResized for analysis: \(resizedW)x\(resizedH)"
        }
        meta += "\nMIME: image/jpeg"

        let visionPrompt = DSHToolArguments.string(args, "prompt", or: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if activeModelHasNativeVision {
            let content = visionPrompt.isEmpty ? meta : meta + "\nRequested focus: \(visionPrompt)"
            return DSHToolExecutionResult(
                content: content,
                isError: false,
                imageData: inferenceData,
                imageMimeType: "image/jpeg",
                imageLinuxPath: linuxPath
            )
        }

        do {
            let groupLabel = VisionGroupResolver.groupName()
            let outcome = try await VisionGroupResolver.describe(
                imageData: inferenceData,
                mimeType: "image/jpeg",
                customPrompt: visionPrompt.isEmpty ? nil : visionPrompt,
                seed: abs(callId.hashValue),
                onAttempt: { [weak self] attempt in
                    guard let self else { return }
                    let via = groupLabel.map { " (\($0))" } ?? ""
                    let retry = attempt.index > 1 ? " — attempt \(attempt.index)/\(attempt.total)" : ""
                    self.dshSetToolBlockContent(
                        callId: callId,
                        content: "Reading image \(pathArg) via \(attempt.modelName)\(via)\(retry)…"
                    )
                }
            )
            let framed = VisionGroupResolver.framedDescription(
                outcome,
                groupName: groupLabel,
                question: visionPrompt.isEmpty ? nil : visionPrompt
            )
            return DSHToolExecutionResult(content: meta + "\n\n" + framed, isError: false)
        } catch {
            // Deliberately a SUCCESSFUL result carrying failure text: an errored
            // tool result tends to make models retry in a loop, whereas this lets
            // the model tell the user plainly.
            let reason = (error as? VisionGroupResolver.VisionError)?.errorDescription
                ?? String(describing: error)
            return DSHToolExecutionResult(
                content: meta + "\n\nCould not describe the image: \(reason)",
                isError: false
            )
        }
    }

    // MARK: - Transcript Block Updates

    /// Set the transcript text of the block carrying a call id, if it exists.
    ///
    /// The block is found by call id rather than by position, because blocks can
    /// be appended by other paths while a tool is still running.
    func dshSetToolBlockContent(callId: String, content: String) {
        guard dshStreamingMsgIdx >= 0, dshStreamingMsgIdx < messages.count else { return }
        let idx = dshStreamingMsgIdx
        guard let blockIdx = messages[idx].blocks.firstIndex(where: { $0.toolUseId == callId }) else { return }
        messages[idx].blocks[blockIdx].content = content
    }
}
