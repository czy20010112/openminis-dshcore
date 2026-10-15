//
//  DSHTypes.swift
//  Minis
//
//  DSH agent framework core types, ported from DeepSeek Harness
//  (packages/llm/llm/src/types.ts, packages/core/tools/src/types.ts).
//
//  This module carries the provider-neutral message and tool vocabulary the
//  agent loop reasons about. Provider wire translation stays in the existing
//  OpenMinis provider implementations; this layer is what replaces the loop
//  and prompt assembly.
//

import Foundation

// MARK: - Content Blocks

/// Plain text visible to the end user.
public struct DSHTextBlock: DSHContentBlock, Sendable {
    public let type = "text"
    public let text: String

    public init(text: String) { self.text = text }
}

/// Reasoning / thinking content, distinct from visible text.
public struct DSHReasoningBlock: DSHContentBlock, Sendable {
    public let type = "reasoning"
    public let text: String

    public init(text: String) { self.text = text }
}

/// A tool invocation requested by the model.
public struct DSHToolCallBlock: DSHContentBlock, Sendable {
    public let type = "tool-call"
    /// Provider-issued call id; correlates with the matching tool result.
    public let id: String
    public let name: String
    /// Raw JSON string as produced by the model.
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The result of one tool call, ready to enter model context.
///
/// A tool result is not always text. `read_image` returns pixels for a
/// native-vision model (or a written description from a Vision Group for one
/// without), and `browser_use` returns a page screenshot plus the URL it landed
/// on. Those ride here alongside the text rather than as a separate message, so
/// the provider sees the same shape Minis' original loop produced: an image
/// attached to the tool_result part itself.
public struct DSHToolResultBlock: DSHContentBlock, Sendable {
    public let type = "tool-result"
    /// Correlates with the originating {@link DSHToolCallBlock.id}.
    public let callId: String
    public let name: String
    public let content: String
    public let isError: Bool
    /// Pixels to attach to this result, when the tool produced an image.
    public let imageData: Data?
    public let imageMimeType: String?
    /// The URL a browser action landed on, for the transcript card.
    public let pageURL: String?
    /// Durable sandbox path of the attached image, so it can be re-fetched.
    public let imageLinuxPath: String?

    public init(
        callId: String,
        name: String,
        content: String,
        isError: Bool,
        imageData: Data? = nil,
        imageMimeType: String? = nil,
        pageURL: String? = nil,
        imageLinuxPath: String? = nil
    ) {
        self.callId = callId
        self.name = name
        self.content = content
        self.isError = isError
        self.imageData = imageData
        self.imageMimeType = imageMimeType
        self.pageURL = pageURL
        self.imageLinuxPath = imageLinuxPath
    }
}

/// An image carried by a user turn.
public struct DSHImageBlock: DSHContentBlock, Sendable {
    public let type = "image"
    public let data: Data
    public let mimeType: String
    /// Optional durable path, used to emit a re-fetchable placeholder.
    public let path: String?

    public init(data: Data, mimeType: String, path: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.path = path
    }
}

/// A file carried by a user turn.
public struct DSHFileBlock: DSHContentBlock, Sendable {
    public let type = "file"
    public let name: String
    public let size: Int
    public let path: String?

    public init(name: String, size: Int, path: String? = nil) {
        self.name = name
        self.size = size
        self.path = path
    }
}

/// Merge-extensible content block. New blocks must land with adapter, UI, and
/// compaction support.
public protocol DSHContentBlock: Sendable {
    var type: String { get }
}

/// One message in the agent conversation.
public struct DSHMessage: Sendable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
        /// A tool result folded back into the conversation.
        case tool
        /// Developer-authored instructions carried ahead of the first user turn.
        case developer
    }

    public let role: Role
    public var blocks: [DSHContentBlock]

    public init(role: Role, blocks: [DSHContentBlock]) {
        self.role = role
        self.blocks = blocks
    }

    public init(role: Role, text: String) {
        self.role = role
        self.blocks = [DSHTextBlock(text: text)]
    }

    /// Plain text of this message, concatenating its text blocks.
    public var text: String {
        blocks.compactMap { block -> String? in
            switch block {
            case let b as DSHTextBlock: return b.text
            case let b as DSHReasoningBlock: return b.text
            case let b as DSHToolResultBlock: return b.content
            default: return nil
            }
        }.joined(separator: "\n")
    }
}

// MARK: - Finish Reason

/// Why a model response stopped.
public enum DSHFinishReason: Sendable {
    case stop
    case toolCalls
    case maxTokens
    case aborted(failure: DSHFailure)
    case error(failure: DSHFailure)
}

/// Serializable provider or transport failure facts.
public struct DSHFailure: Sendable, Error {
    public let message: String
    /// Stable provider-neutral machine-routing code.
    public let code: String
    public let status: Int?
    /// Provider-requested delay in milliseconds, when valid and available.
    public let providerRetryAfterMs: Int?

    public init(message: String, code: String, status: Int? = nil, providerRetryAfterMs: Int? = nil) {
        self.message = message
        self.code = code
        self.status = status
        self.providerRetryAfterMs = providerRetryAfterMs
    }
}

// MARK: - Token Usage

/// Token accounting for one model call.
///
/// Counts are disjoint: `inputTokens` is uncached input only; cached input is
/// reported separately.
public struct DSHTokenUsage: Sendable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var totalTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?

    public init() {}
}

// MARK: - Tool Schema

/// JSON-schema description of a tool, as sent to the model.
public struct DSHToolSchema: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema object for the arguments.
    public let parameters: [String: Any]
    /// Requests deferred loading of the tool definition into model context.
    public let deferLoading: Bool

    public init(
        name: String,
        description: String,
        parameters: [String: Any],
        deferLoading: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.deferLoading = deferLoading
    }
}

// MARK: - Stream Chunks

/// Raw streaming protocol emitted by adapters.
public enum DSHStreamChunk: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(id: String, name: String?, argumentsDelta: String)
    case toolCallComplete(id: String, name: String, arguments: String)
    case usage(DSHTokenUsage)
    case finish(DSHFinishReason)
}
