//
//  DSHToolHandlerImpl.swift
//  Minis
//
//  The DSH tool handlers, implemented over Minis' existing tool code.
//
//  The underlying implementations are unchanged — `executeCommand`,
//  `executeFileRead`, `executeFileWrite`, `executeFileEdit`, the image reader,
//  and the memory store. These adapters only translate between the DSH tool
//  argument dictionary and the JSON those implementations already accept.
//

import Foundation

extension AIChatViewModel {

    /// Run a shell command and return its captured output.
    func dshRunShell(command: String, timeout: TimeInterval) async -> String {
        guard !command.isEmpty else { return "Error: empty command" }
        do {
            let result = try await executeCommand(command, timeout: timeout) { _ in
                // Per-line streaming goes to the UI block through the existing
                // path; the DSH result carries the final captured output.
            }
            var out = result.output
            if result.exitCode != 0 {
                out += "\n[exit code: \(result.exitCode)]"
            }
            return out.isEmpty ? "(no output)" : out
        } catch {
            return "Error: \(String(describing: error))"
        }
    }

    /// Read a file from the sandbox.
    func dshReadFile(path: String) async -> String {
        let args: [String: Any] = ["path": path]
        guard let json = try? JSONSerialization.data(withJSONObject: args),
              let text = String(data: json, encoding: .utf8) else {
            return "Error: could not encode arguments"
        }
        guard let result = try? await executeFileRead(from: text) else {
            return "Error: read failed"
        }
        return result.output
    }

    /// Write a file to the sandbox.
    func dshWriteFile(path: String, content: String, append: Bool) async -> String {
        let args: [String: Any] = ["path": path, "content": content, "append": append]
        guard let json = try? JSONSerialization.data(withJSONObject: args),
              let text = String(data: json, encoding: .utf8) else {
            return "Error: could not encode arguments"
        }
        guard let result = try? await executeFileWrite(from: text) else {
            return "Error: write failed"
        }
        return result.output
    }

    /// Apply a targeted edit to a file.
    func dshEditFile(path: String, oldString: String, newString: String, replaceAll: Bool) async -> String {
        let args: [String: Any] = [
            "path": path,
            "old_string": oldString,
            "new_string": newString,
            "replace_all": replaceAll,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: args),
              let text = String(data: json, encoding: .utf8) else {
            return "Error: could not encode arguments"
        }
        guard let result = try? await executeFileEdit(from: text) else {
            return "Error: edit failed"
        }
        return result.output
    }

    /// Read an image and return its metadata for the model.
    ///
    /// The image itself rides the request's image budget path; this returns the
    /// re-fetchable reference plus dimensions, which is what the model needs to
    /// decide whether to look at it.
    func dshReadImage(path: String) async -> String {
        guard let url = await resolvePathForDirectRead(path) else {
            return "Error: Invalid path: \(path)"
        }
        guard let data = try? Data(contentsOf: url) else {
            return "Error: could not read \(path)"
        }
        let sizeKB = data.count / 1024
        return "Image \(url.lastPathComponent): \(sizeKB) KB at \(path)"
    }

    /// Write a memory entry.
    func dshWriteMemory(content: String) async -> String {
        // Driven through the existing JSON entry point so the daily-log layout
        // and timestamp format stay identical.
        let args: [String: Any] = ["content": content]
        guard let json = try? JSONSerialization.data(withJSONObject: args),
              let text = String(data: json, encoding: .utf8) else {
            return "Error: could not encode arguments"
        }
        let result = executeMemoryWrite(from: text)
        return result.output
    }

    /// Read memories by keyword.
    func dshGetMemory(keywords: String, scope: String) async -> String {
        var args: [String: Any] = [:]
        if !keywords.isEmpty { args["keywords"] = keywords }
        args["scope"] = scope
        guard let json = try? JSONSerialization.data(withJSONObject: args),
              let text = String(data: json, encoding: .utf8) else {
            return "Error: could not encode arguments"
        }
        let result = executeMemoryGet(from: text)
        return result.output
    }
}
