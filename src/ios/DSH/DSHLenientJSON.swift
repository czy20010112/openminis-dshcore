import Foundation

// MARK: - Lenient JSON plumbing
//
// The harness is a moving target: the same field is a string in one build and an
// object in the next (`event.data.reason` was a string in session-e902df26 while
// every earlier log had `{ "kind": … }`). A strict `Decodable` turns that into a
// 506 KB snapshot that decodes to NOTHING, i.e. a Session that looks empty — so
// every optional shape in the wire types below goes through one of these three
// helpers instead of asking for an exact type.
//
// Rule: a wrong shape may cost one field or one record, never the frame.

/// A JSON value of unknown shape.
enum DSHJSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([DSHJSONValue])
    case object([String: DSHJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode([DSHJSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: DSHJSONValue].self) { self = .object(value); return }
        self = .null
    }

    /// Raw text: strings verbatim, numbers/booleans formatted, structures encoded
    /// back to compact JSON (which is exactly what a tool's `arguments` needs).
    var text: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value == value.rounded() && abs(value) < 1e15
            ? String(Int(value)) : String(value)
        case .null: return ""
        case .array, .object:
            guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]),
                  let encoded = String(data: data, encoding: .utf8) else { return "" }
            return encoded
        }
    }

    /// One readable line out of a nested value: the first of these keys holding a
    /// non-empty string wins, else the compact JSON. `{"kind":"model-selection"}`
    /// therefore reads as `model-selection`, not as punctuation.
    var summaryText: String {
        if case .object(let dictionary) = self {
            for key in ["summary", "text", "message", "title", "kind", "type", "reason", "name"] {
                if let value = dictionary[key], case .string(let inner) = value, !inner.isEmpty {
                    return inner
                }
            }
        }
        return text
    }

    var jsonObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map { $0.jsonObject }
        case .object(let dictionary): return dictionary.mapValues { $0.jsonObject }
        }
    }
}

/// A field that the harness writes as a string *or* as an object with the text
/// somewhere inside. Never throws — an unreadable field becomes `""`.
struct DSHFlexibleText: Decodable, Equatable {
    var text: String

    init(_ text: String) { self.text = text }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if let value = try? container.decode(String.self) { text = value; return }
            if let value = try? container.decode(DSHJSONValue.self) {
                text = value.summaryText
                return
            }
        }
        text = ""
    }
}

/// A field that is usually a string but may arrive as a number/object.
struct DSHFlexibleString: Decodable, Equatable {
    var value: String?

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else { value = nil; return }
        if let string = try? container.decode(String.self) { value = string; return }
        if let raw = try? container.decode(DSHJSONValue.self) {
            let text = raw.summaryText
            value = text.isEmpty ? nil : text
            return
        }
        value = nil
    }
}

/// An array whose ELEMENTS decode independently: a single malformed record is
/// dropped and counted instead of failing the whole page.
struct DSHLossyArray<Element: Decodable>: Decodable {
    var values: [Element] = []
    /// Number of elements the decoder saw (values.count + failures.count).
    var total = 0
    /// One short description per dropped element, in order.
    var failures: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            total += 1
            // `superDecoder()` advances past the element BEFORE we decode it, so a
            // failure cannot desynchronise the rest of the array.
            let element = try container.superDecoder()
            do {
                values.append(try Element(from: element))
            } catch {
                failures.append(DSHLossyArray.describe(error))
            }
        }
    }

    /// `<path>: <reason>` — short enough for one log line, specific enough to fix
    /// the schema.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        switch decoding {
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx),
             .keyNotFound(_, let ctx), .dataCorrupted(let ctx):
            context = ctx
        @unknown default:
            return decoding.localizedDescription
        }
        var path: [String] = []
        for key in context.codingPath {
            if let index = key.intValue { path.append("[\(index)]") }
            else if !key.stringValue.isEmpty { path.append(key.stringValue) }
        }
        let joined = path.isEmpty ? "-" : path.joined(separator: ".")
        return "\(joined): \(context.debugDescription)"
    }
}
