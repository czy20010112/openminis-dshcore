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
        var toolArguments: [String: AgentToolArguments.Record] = [:]
        for block in entry.message.blocks {
            switch block {
            case let text as DSHTextBlock:
                parts.append(.text(text.text))
            case let reasoning as DSHReasoningBlock:
                parts.append(.text(reasoning.text))
            case let call as DSHToolCallBlock:
                // See projectMessages in DSHTurnDriver: the block's own bytes are
                // what replays, the dictionary is for execution.
                let args = (try? JSONSerialization.jsonObject(
                    with: Data(call.arguments.utf8)
                )) as? [String: Any] ?? [:]
                parts.append(.toolUse(id: call.id, name: call.name, input: args))
                // Only a parsed JSON object replays verbatim: an empty or
                // malformed arguments string is sent as `{}`, exactly as it was
                // before this fix.
                if !args.isEmpty {
                    toolArguments[call.id] = AgentToolArguments.Record(text: call.arguments, input: args)
                }
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
            role: DSHSessionProjection.agentRole(for: entry.message.role),
            parts: parts
        )
        message.dshSeq = entry.seq.value
        message.toolArguments = toolArguments
        return message
    }

    /// Map a session role onto the provider-facing role.
    ///
    /// Only `.assistant` is an assistant turn. A tool result is carried in a
    /// **user** message — that is the shape Minis' original loop produced
    /// (`AgentMessage(role: .user, parts: toolResultParts)`), and it is what the
    /// Anthropic path requires: a `tool_result` block inside an assistant message
    /// is rejected. Collapsing `.tool` into `.assistant`, as this did, happens to
    /// survive the OpenAI-compatible path and breaks everywhere else.
    static func agentRole(for role: DSHMessage.Role) -> AgentMessage.Role {
        role == .assistant ? .assistant : .user
    }

    /// Project a UI message back onto a session entry, for seeding a session
    /// from an existing conversation.
    static func toDSHMessage(_ message: AgentMessage) -> DSHMessage {
        var blocks: [DSHContentBlock] = []
        for part in message.parts {
            switch part {
            case .text(let text):
                blocks.append(DSHTextBlock(text: text))
            case .toolUse(let id, let name, let input):
                let raw: String
                if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    raw = text
                } else {
                    raw = "{}"
                }
                blocks.append(DSHToolCallBlock(id: id, name: name, arguments: raw))
            case .toolResult(let id, let name, let content, let isError,
                             let imageData, let imageMimeType, let pageURL, let imageLinuxPath):
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

    /// Lift a settled tool result out of the executor's outcome part.
    ///
    /// This lives here, and not in the tool handler, because it is the one place
    /// in the module that pattern-matches the provider's content part — and that
    /// enum's shape is precisely what differs between the iOS 15 and iOS 26
    /// lines. Confining the branch difference to this file keeps the other
    /// nineteen identical, so the core can be fixed once and verified once.
    static func toolExecutionResult(from part: AgentContentPart) -> DSHToolExecutionResult? {
        guard case let .toolResult(_, _, content, isError,
                                   imageData, imageMimeType, pageURL, imageLinuxPath) = part else {
            return nil
        }
        return DSHToolExecutionResult(
            content: content,
            isError: isError,
            imageData: imageData,
            imageMimeType: imageMimeType,
            pageURL: pageURL,
            imageLinuxPath: imageLinuxPath
        )
    }
}

// MARK: - Tool Handler Adapter

/// Block kinds that exist on only one of the two source lines.
///
/// `DSHToolBlockKind` is shared between the iOS 15 and iOS 26 lines, and the two
/// lines do not have the same `AssistantBlockKind` cases: v1.14 added
/// `delegateTool(title:)` for its sub-agent tool, and the iOS 15 line's enum has
/// no such case. Returning nil here is the correct answer on this line.
extension DSHToolBlockKind {

    /// The block kind for a tool this line may not have.
    static func lineSpecificKind(for name: String, arguments: [String: Any]) -> AssistantBlockKind? {
        nil
    }
}

