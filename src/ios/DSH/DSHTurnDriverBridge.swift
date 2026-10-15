//
//  DSHTurnDriverBridge.swift
//  Minis
//
//  Wires DSHTurnDriver into AIChatViewModel.
//
//  The driver owns the decision core — request derivation, tool scheduling,
//  result commit, compaction. AIChatViewModel keeps everything it already does
//  well: streaming presentation, persistence, image budgeting, group fallback,
//  queued prompts, cancel cleanup, TTS, and the UI.
//
//  The one real problem is identity. The driver addresses conversation entries
//  by DSHSeq; the UI addresses them by array index. Bridging the two by index is
//  exactly the defect that produced the loop's resync patches, so every
//  AgentMessage carries the seq of the session entry it was projected from. A
//  UI mutation can then be reconciled by seq rather than by position.
//

import Foundation

// MARK: - Session Projection

/// Projects between the driver's session surface and the UI's message array.
@MainActor
enum DSHSessionProjection {

    /// Project a session entry onto a provider message.
    static func toAgentMessage(_ entry: DSHLogEntry) -> AgentMessage {
        var parts: [AgentContentPart] = []
        for block in entry.message.blocks {
            switch block {
            case let text as DSHTextBlock:
                parts.append(.text(text.text))
            case let reasoning as DSHReasoningBlock:
                parts.append(.text(reasoning.text))
            case let call as DSHToolCallBlock:
                let args = (try? JSONSerialization.jsonObject(
                    with: Data(call.arguments.utf8)
                )) as? [String: Any] ?? [:]
                parts.append(.toolUse(id: call.id, name: call.name, input: args))
            case let result as DSHToolResultBlock:
                parts.append(.toolResult(
                    id: result.callId,
                    name: result.name,
                    content: result.content,
                    isError: result.isError,
                    imageData: result.imageData,
                    imageMimeType: result.imageMimeType,
                    pageURL: result.pageURL,
                    imageLinuxPath: result.imageLinuxPath
                ))
            case let image as DSHImageBlock:
                parts.append(.imageData(
                    data: image.data, mimeType: image.mimeType, linuxPath: image.path
                ))
            case let file as DSHFileBlock:
                parts.append(.text("[file: \(file.name) (\(file.size) bytes)]"))
            default:
                continue
            }
        }
        var message = AgentMessage(
            role: entry.message.role == .user ? .user : .assistant,
            parts: parts
        )
        message.dshSeq = entry.seq.value
        return message
    }

    /// Project a UI message back onto a session entry, for seeding a session
    /// from an existing conversation.
    static func toDSHMessage(_ message: AgentMessage) -> DSHMessage {
        var blocks: [DSHContentBlock] = []
        for part in message.parts {
            switch part {
            case .text(let text):
                blocks.append(DSHTextBlock(text: text))
            case .toolUse(let id, let name, let input, _):
                let raw: String
                if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    raw = text
                } else {
                    raw = "{}"
                }
                blocks.append(DSHToolCallBlock(id: id, name: name, arguments: raw))
            // v1.14 grew `.toolResult` to nine associated values by adding
            // `isOffloadReadback`; the three image/page values before it are the
            // ones this bridge projects. See DSHTurnDriver.swift for the other
            // place v1.14's enum arity differs from the iOS 15 line.
            case .toolResult(let id, let name, let content, let isError,
                             let imageData, let imageMimeType, let pageURL, let imageLinuxPath, _):
                blocks.append(DSHToolResultBlock(
                    callId: id,
                    name: name,
                    content: content,
                    isError: isError,
                    imageData: imageData,
                    imageMimeType: imageMimeType,
                    pageURL: pageURL,
                    imageLinuxPath: imageLinuxPath
                ))
            case .imageData(let data, let mimeType, let path):
                blocks.append(DSHImageBlock(data: data, mimeType: mimeType, path: path))
            }
        }
        return DSHMessage(
            role: message.role == .user ? .user : .assistant,
            blocks: blocks
        )
    }

    /// Project a session entry onto a provider message, preserving the seq the
    /// caller already knows.
    ///
    /// `AgentMessage` is a struct, so the returned copy is the only place the
    /// caller's stamp can land — it is assigned on the result, not on the input.
    static func toAgentMessage(_ entry: DSHLogEntry, seq: Int?) -> AgentMessage {
        var message = toAgentMessage(entry)
        message.dshSeq = seq
        return message
    }
}

// MARK: - Tool Handler Adapter

/// Runs one DSH tool call through the ViewModel's existing handler.
///
/// The handlers are unchanged. This adapter only supplies the concurrency mode
/// the scheduler needs and routes the result back as a `DSHToolExecutionResult`.
@MainActor
enum DSHToolHandler {

    /// Execute one tool call.
    ///
    /// - Parameters:
    ///   - name: the tool being called.
    ///   - arguments: parsed arguments.
    ///   - run: the existing per-tool handler, which owns streaming output into
    ///     the UI block and returns the final content.
    /// - Returns: the settled result.
    static func execute(
        name: String,
        arguments: [String: Any],
        run: @MainActor @escaping ([String: Any]) async throws -> String
    ) async -> DSHToolExecutionResult {
        do {
            let content = try await run(arguments)
            return DSHToolExecutionResult(content: content, isError: false)
        } catch {
            return DSHToolExecutionResult(
                content: "Error: \(String(describing: error))",
                isError: true
            )
        }
    }
}
