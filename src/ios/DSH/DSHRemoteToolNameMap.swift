import Foundation

/// Normalizes harness tool calls into the names `RawMessage.toChatMessage` knows.
///
/// `toChatMessage` switches on an exact set of tool names (`ChatStore.swift:4891`);
/// anything else falls into `default` and becomes a bare shell card whose title is
/// the raw tool name and whose arguments never render. The harness uses its own
/// names (`pwsh`, `Read`, `Edit`, …) and its own argument keys (`file_path`), so
/// both are translated here rather than teaching the renderer about every host.
enum DSHRemoteToolNameMap {

    /// harness name → Minis renderer name
    private static let names: [String: String] = [
        "pwsh": "shell_execute",
        "bash": "shell_execute",
        "shell": "shell_execute",
        "shell_execute": "shell_execute",
        "execute_shell": "shell_execute",
        "read": "file_read",
        "read_file": "file_read",
        "write": "file_write",
        "write_file": "file_write",
        "edit": "file_edit",
        "edit_file": "file_edit",
        "multiedit": "file_edit",
        "websearch": "browser_use",
        "web_search": "browser_use",
        "webfetch": "browser_use",
        "web_fetch": "browser_use",
        "browser_use": "browser_use",
        "read_image": "read_image",
        "readimage": "read_image",
        "memory_write": "memory_write",
        "memory_get": "memory_get",
    ]

    /// argument key → the key the renderer reads
    private static let argumentKeys: [String: String] = [
        "file_path": "path",
        "filePath": "path",
        "cmd": "command",
        "query": "action",
        "url": "url",
    ]

    static func normalize(name: String, argumentsJSON: String) -> (name: String, arguments: String) {
        let mapped = names[name.lowercased()] ?? name
        guard let data = argumentsJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (mapped, argumentsJSON)
        }
        var changed = false
        for (from, to) in argumentKeys where object[to] == nil {
            if let value = object[from] {
                object[to] = value
                changed = true
            }
        }
        // A browser tool shows its action; fall back to the tool name so the card
        // is never titled with an empty action.
        if mapped == "browser_use", object["action"] == nil {
            object["action"] = name
            changed = true
        }
        guard changed,
              let rewritten = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: rewritten, encoding: .utf8) else {
            return (mapped, argumentsJSON)
        }
        return (mapped, text)
    }
}
