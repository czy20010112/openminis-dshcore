import Foundation

// MARK: - Tool Definitions (Canonical)

extension AIChatViewModel {

    /// [T-ios-vision-branch-mismatch #182] THE single source of truth for
    /// "can the model that will actually receive this turn see images itself".
    ///
    /// Both the `read_image` registration (which picks the tool DESCRIPTION) and
    /// its handler (which picks pixels-vs-Vision-Group) must agree, or the model
    /// is told one thing and handed another. They previously each wrote
    /// `selectedModel.capabilities.supportedModalities.contains(.imageInput)` —
    /// textually identical, yet wrong: `selectedModel` is the @Published UI
    /// property, while the REQUEST is built from `resolveCurrentEntry()` (see
    /// `activeModel` in runAgentLoop). With group routing or a session binding
    /// those are different models, so a text-only model could be registered with
    /// the Vision Group tool description and then served by the native pixel
    /// branch — returning metadata and no description at all.
    ///
    /// Resolve from the same entry the request uses, and fall back to
    /// `selectedModel` only when that resolution fails.
    var activeModelHasNativeVision: Bool {
        let model = resolveCurrentEntry()?.model ?? selectedModel
        return model.capabilities.supportedModalities.contains(.imageInput)
    }

    // MARK: - Tool Definitions (Canonical)

    func makeAgentTools() -> [AgentToolDefinition] {
        // [T-memory-toggle-gates-injection-and-tools-ios] memory_get and
        // memory_write are conditionally registered. When the per-session
        // toggle is off, drop both tool definitions so the LLM never sees
        // them. The system prompt also switches to a "memory disabled"
        // wording (see baseSystemPrompt below) so the model can correctly
        // tell the user to re-enable memory via /memory or Settings.
        let includeMemoryTools = memoryEnabled
        var tools: [AgentToolDefinition] = [
            AgentToolDefinition(
                name: "shell_execute",
                description: "Execute a command in an isolated Linux process (iSH/Alpine Linux). The command runs via /bin/sh -c with stdout and stderr captured separately via pipes. Each invocation spawns a fresh process — there is no shared terminal session. Default timeout is 15 minutes.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Install Python data analysis packages', 'List files in home directory'). Use the same language as the user."),
                    "command": AgentToolParam(type: .string, description: "The shell command to execute. Supports multi-line commands directly — no special escaping needed. Keep under 1000 chars; for longer scripts, write to a file with file_write first, then run it."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default: 900). Use a larger value for long-running commands like package installs."),
                    "delay": AgentToolParam(type: .integer, description: "Delay in seconds before execution begins. The tool blocks the agent flow during this wait WITHOUT occupying the iSH shell, so other concurrent tasks can use it. Use this instead of sleep commands to avoid resource contention."),
                ],
                required: ["tool_title", "command"],
                propertyOrdering: ["tool_title", "command", "timeout", "delay"]
            ),
            AgentToolDefinition(
                name: "file_read",
                description: "Read a file from the Linux filesystem. Faster than shell_execute for reading files — no shell overhead. Returns file content with metadata. Rejects binary files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Read Python script contents', 'Check system configuration file'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to read (e.g. /var/minis/workspace/data.csv)"),
                    "offset": AgentToolParam(type: .integer, description: "1-based line number to start reading from (default: 1). Ignored when direction is 'tail'. If a previous read was truncated, its header ends with next_offset=N — pass that as offset to continue from where it stopped."),
                    "lines": AgentToolParam(type: .integer, description: "Maximum number of lines to return (default: all lines up to max_length)"),
                    "max_length": AgentToolParam(type: .integer, description: "Maximum character length of returned content (default: 15000). Honoured up to 80000, but ONE tool result carries at most 15000 characters, so a larger value is capped at 14488 (15000 minus the header allowance) and the header states the value actually used. To read further, page with the next_offset the header names."),
                    "direction": AgentToolParam(type: .string, description: "Read direction: 'head' (from start, default) or 'tail' (from end of file)"),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "offset", "lines", "direction", "max_length"]
            ),
            AgentToolDefinition(
                name: "file_write",
                // [T-file-write-large-content-timeout] GH#223. Every byte of
                // `content` has to be GENERATED by the model as tool-call
                // arguments, streamed over the network, before the write even
                // starts. So a single 50-100KB write is a very long, fragile
                // request — the failures users report as "file_write timed out"
                // are the LLM request dying mid-generation, not the (purely
                // local, instant) filesystem write. Splitting into appends makes
                // each request short, and any part that can be COMPUTED rather
                // than transcribed should be, because generated bytes are the
                // actual cost. Without this guidance the model happily emits one
                // giant argument and the turn dies with no useful diagnostic.
                description: "Write content to a file on the Linux filesystem. Faster than shell_execute for writing files. Creates the file if it doesn't exist. Use append mode to add to existing files.\n\nIMPORTANT for large files (roughly >8KB): do NOT emit it as one call. Every byte of `content` is generated and streamed as tool arguments, so one huge call is slow and frequently dies mid-request. Instead either (a) write the first chunk, then extend it with further calls using append: true, or (b) when the content is repetitive or computable (SVG charts, generated tables, boilerplate), write a short script and run it with shell_execute — generating 2KB of code that emits 100KB beats transcribing 100KB.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Create Python statistics script', 'Write configuration file'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to write (e.g. /root/test.txt)"),
                    "content": AgentToolParam(type: .string, description: "The text content to write to the file. For large content prefer several appending calls over one huge one — see the tool description."),
                    "append": AgentToolParam(type: .boolean, description: "If true, append to existing file instead of overwriting (default: false)"),
                    "create_dirs": AgentToolParam(type: .boolean, description: "If true, create parent directories if they don't exist (default: false)"),
                        "overwrite": AgentToolParam(type: .boolean, description: "Only when deliberately replacing an existing file with clearly shorter content. Without it, file_write refuses to shrink an existing file below half its size, or to a prefix of it — use append: true to add to a file, file_edit to change part of one, and overwrite: true only for a real replacement. (default: false)"),
                ],
                required: ["tool_title", "path", "content"],
                propertyOrdering: ["tool_title", "path", "content", "append", "create_dirs", "overwrite"]
            ),
            AgentToolDefinition(
                name: "file_edit",
                description: "Make targeted edits to an existing file using exact string replacement. ALWAYS use file_read first to see the current file contents before editing. Prefer file_edit over file_write when modifying existing files — only the changed part needs to be specified. The old_string must match exactly one location in the file (including whitespace/indentation), unless replace_all is true.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Fix typo in Python script', 'Update config value'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to the file to edit (e.g. /root/script.py)"),
                    "old_string": AgentToolParam(type: .string, description: "The exact text to find in the file. Must match precisely including whitespace and indentation. Must be unique in the file unless replace_all is true."),
                    "new_string": AgentToolParam(type: .string, description: "The replacement text. Use empty string to delete old_string."),
                    "replace_all": AgentToolParam(type: .boolean, description: "If true, replace ALL occurrences of old_string (default: false)"),
                ],
                required: ["tool_title", "path", "old_string", "new_string"],
                propertyOrdering: ["tool_title", "path", "old_string", "new_string", "replace_all"]
            ),
            AgentToolDefinition(
                name: "browser_use",
                description: "Control a web browser with up to 3 tabs. Do NOT use this tool for minis:// action URLs (open_terminal, views, settings) — those are app deep links, use Markdown links in chat instead. The browser supports both web URLs and minis:// resource URLs. Use minis:// URLs to preview session files (e.g. navigate to minis://workspace/index.html). Sub-resources (JS, CSS, images, fonts) referenced via minis:// absolute paths or relative paths within HTML pages resolve correctly. Use navigate to open URLs, screenshot to see the page (returns an image), click/type to interact with elements, get_text/get_readable to extract content, scroll to navigate long pages, scroll_and_collect to scroll through infinite-scroll/virtual-rendered pages (like Twitter/X timelines) and accumulate unique content items across scroll positions in a single call, find_elements to discover interactive elements, get_page_info for page metadata, get_backbone to get a structural overview of the page DOM as a simplified tree, fetch to download files/resources using the page's session (returns metadata and a minis:// URL), new_tab to open an additional tab, close_tab to close a tab, and list_tabs to see all open tabs. Use set_viewport with viewport_width + viewport_height to override the viewport for the current session (e.g. before screenshotting a 1920×1080 HTML composition that would otherwise be cropped to the phone viewport); pass reset=true to drop the session override and fall back to the global browser setting. Use get_cookies to retrieve cookies for the current page URL / current site root domain only (including HttpOnly cookies). get_cookies supports optional 'keyword' (filter by cookie name) and 'fuzzy' (true=contains match, false=exact match, default true). It returns only a summary and an offload env file path — raw cookie values are NOT included in the tool response. To reuse cookies in shell commands: `. /var/minis/offloads/env_cookies_xxx.sh && command`. You may define alias variables when needed. Use set_cookies to write cookies into the current page's cookie store via the native cookie store (so even HttpOnly cookies, which JS cannot set, land). Pass a 'cookies' array of objects, each with name + value (required) and optional domain (defaults to the current page host), path (defaults to '/'), secure, http_only, and expires (Unix timestamp in seconds; omit for a session cookie). Use wait_for_dom_stable to wait until the page DOM stops changing (useful after navigation or interactions that trigger async data loading — polls every 0.5s, resolves when mutation rate gradient is stable for 3+ intervals, default timeout 10s). Use tab_id to target a specific tab (defaults to the most recently used tab).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Open Wikipedia homepage', 'Take screenshot of current page'). Use the same language as the user."),
                    "action": AgentToolParam(type: .string, description: "The browser action to perform", enumValues: BrowserAction.allCases.map(\.rawValue)),
                    "url": AgentToolParam(type: .string, description: "URL to navigate to (for navigate action) or resource to download (for fetch action)"),
                    "selector": AgentToolParam(type: .string, description: "CSS selector for targeting elements (click, type, get_text, scroll, hover, find_elements). For scroll: specify a scrollable container to scroll (e.g. 'div.timeline'); if omitted, auto-detects the best scrollable element."),
                    "text": AgentToolParam(type: .string, description: "Text to type (for type action)"),
                    "coordinate_x": AgentToolParam(type: .integer, description: "X coordinate for click (alternative to selector)"),
                    "coordinate_y": AgentToolParam(type: .integer, description: "Y coordinate for click (alternative to selector)"),
                    "direction": AgentToolParam(type: .string, description: "Scroll direction", enumValues: ["up", "down"]),
                    "amount": AgentToolParam(type: .integer, description: "Scroll amount in pixels (default: 500)"),
                    "script": AgentToolParam(type: .string, description: "JavaScript code to execute (for execute_js action). The script runs inside an async function wrapper — `await` and top-level `return` are both supported (e.g. `var r = await fetch(url); return await r.json()`). DOM values may be returned directly — a DOMRect, Date, Error, element or NodeList is converted to plain JSON before it reaches you."),
                    "user_agent": AgentToolParam(type: .string, description: "User agent profile to switch to", enumValues: ["desktop_safari", "mobile_safari"]),
                    "max_depth": AgentToolParam(type: .integer, description: "Maximum tree depth for get_backbone (default: 5)"),
                    "scroll_count": AgentToolParam(type: .integer, description: "Number of scroll steps for scroll_and_collect (default: 10, max: 20). Each step scrolls by 'amount' pixels and waits for new content."),
                    "item_selector": AgentToolParam(type: .string, description: "CSS selector for individual content items in scroll_and_collect (e.g. 'article', '[data-testid=\"tweet\"]'). If omitted, auto-detects repeated elements."),
                    "tab_id": AgentToolParam(type: .integer, description: "Target tab ID (optional, defaults to most recently used tab). Use list_tabs to see available tabs."),
                    "keywords": AgentToolParam(type: .string, description: "Filter cookies by name (for get_cookies). A space-separated string or array of strings. With fuzzy=true (default), ALL keywords must appear in the cookie name (case-insensitive). With fuzzy=false, cookie name must exactly equal any one of the provided keywords (case-insensitive). Omit to return all cookies for the current site."),
                    "fuzzy": AgentToolParam(type: .boolean, description: "Whether keyword matching is fuzzy (contains-all) or exact-any (for get_cookies, default: true)."),
                    "cookies": AgentToolParam(type: .string, description: "For set_cookies: a JSON array of cookie objects to write. Pass it as a JSON array (a JSON-encoded string of the array is also accepted). Each object: {\"name\": str (required), \"value\": str (required), \"domain\": str (optional, defaults to current page host), \"path\": str (optional, defaults to \"/\"), \"secure\": bool (optional), \"http_only\": bool (optional — sets an HttpOnly cookie that JS cannot read/set), \"expires\": int (optional, Unix timestamp in seconds; omit for a session cookie)}. Field-name variants from common cookie exports are accepted: httpOnly (=http_only), expirationDate (=expires), sameSite, and case/camel variants — so you can paste cookies verbatim from browser extensions (EditThisCookie / Cookie-Editor) or Playwright/Puppeteer storage."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds for wait_for_dom_stable (default: 10). The action polls every 0.5s and resolves when DOM mutation rate stabilizes."),
                    "viewport_width": AgentToolParam(type: .integer, description: "Viewport width in CSS pixels for set_viewport (e.g. 1920). Required together with viewport_height unless reset=true."),
                    "viewport_height": AgentToolParam(type: .integer, description: "Viewport height in CSS pixels for set_viewport (e.g. 1080). Required together with viewport_width unless reset=true."),
                    "reset": AgentToolParam(type: .boolean, description: "For set_viewport: when true, clear the session-level viewport override and fall back to the global browser setting."),
                    "full_page": AgentToolParam(type: .boolean, description: "For screenshot: capture the entire scrollable page by temporarily resizing the WebView to document.documentElement.scrollHeight. Default false captures viewport only. Capped at 32768px tall; when capped, result text includes 'Truncated: true' and the original height."),
                ],
                required: ["tool_title", "action"],
                propertyOrdering: ["tool_title", "action", "tab_id", "url", "selector", "text", "coordinate_x", "coordinate_y", "direction", "amount", "scroll_count", "item_selector", "script", "user_agent", "max_depth", "keywords", "fuzzy", "cookies", "timeout", "viewport_width", "viewport_height", "reset", "full_page"]
            ),
        ]

        if includeMemoryTools {
            tools.append(AgentToolDefinition(
                name: "memory_write",
                description: "Write a memory entry to today's daily log (YYYY-MM-DD.md). Memories persist across all sessions. Each entry is prepended with a timestamp. Save: user preferences, recurring patterns, key facts, project conventions, reusable knowledge. Avoid saving passwords, API keys, tokens, or secrets unless the user explicitly confirms after being warned. Keep entries concise and general-purpose. GLOBAL.md is read-only (user-maintained via Settings).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Save user preference for Python', 'Note today's project context'). Use the same language as the user."),
                    "content": AgentToolParam(type: .string, description: "The memory content to write. Use concise Markdown with a short heading (## Topic) and context about what was done/learned."),
                ],
                required: ["tool_title", "content"],
                propertyOrdering: ["tool_title", "content"]
            ))
            tools.append(AgentToolDefinition(
                name: "memory_get",
                description: "Retrieve memories from persistent storage. Supports keyword-based fuzzy search across memory files. Returns matching lines with surrounding context. Use this to recall previous knowledge, user preferences, or past notes.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Recall user preferences', 'Search past notes'). Use the same language as the user."),
                    "scope": AgentToolParam(type: .string, description: "Memory scope to search: 'daily' for daily logs only, 'all' for daily logs + GLOBAL.md.", enumValues: ["daily", "all"]),
                    "keywords": AgentToolParam(type: .string, description: "Space-separated keywords for fuzzy matching (e.g. 'python preference' or 'API key setup'). All keywords must appear in a line or its surrounding context for a match. Leave empty to return full memory files."),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title", "scope", "keywords"]
            ))
        }

        // [T-ios-vision-group #182] Expose read_image when the model can see
        // images ITSELF, or when a Vision Group is configured to see them on its
        // behalf. Previously a text-only model simply never got this tool, so an
        // image on disk was invisible to it with no recourse. The handler picks
        // the matching branch: native models get pixels, others get the Vision
        // Group's description as text.
        //
        // `isConfigured` is strict (group must resolve AND hold a usable
        // image-capable member), so we never advertise a tool whose non-native
        // path has nothing behind it.
        let nativeVision = activeModelHasNativeVision
        // Evaluate FIRST, not inside the `||` below: short-circuiting on
        // `nativeVision` would skip the call, and this read is also what keeps
        // `isConfiguredCached` — which the off-main T264 placeholder builder
        // relies on — up to date.
        let visionGroupConfigured = VisionGroupResolver.isConfigured
        if nativeVision || visionGroupConfigured {
            // Describe what this model will ACTUALLY receive. Promising "the
            // image is returned directly" to a text-only model would set up a
            // false expectation and invite it to re-call the tool when no pixels
            // arrive; the non-native branch returns a written description instead.
            let readImageDescription = nativeVision
                ? "Read an image file from the Linux filesystem and return it for visual analysis. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, or any visual output. The image is returned directly for your analysis along with metadata (dimensions, file size)."
                : "Read an image file from the Linux filesystem and return a written description of it. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, user-attached photos, or any visual output. You cannot see images directly, so the image is analyzed by a separate vision model and you receive its detailed description plus a transcription of any visible text, along with metadata (dimensions, file size). Because you cannot look again yourself, use the optional 'prompt' argument to ask for exactly what you need from the image — that is your only way to follow up on specific details."
            // [T-ios-vision-group-t264 #182] The `prompt` argument is what makes
            // the non-native branch usable for anything but a generic caption:
            // the host model can't look at the image, so this is its only lever
            // for directing the describing model. On the native branch the model
            // sees the pixels itself, so the argument is documented as optional
            // context rather than a question.
            let promptDescription = nativeVision
                ? "Optional. A note about what you are looking for in the image. Recorded alongside the result; the image itself is returned to you in full either way."
                : "Optional. A specific question or instruction about the image, e.g. 'transcribe the table', 'what error message is shown in this screenshot', 'describe the people and their expressions'. This is passed to the vision model that reads the image for you, so ask for exactly the detail you need. If omitted, a generic detailed description with full text transcription is returned."
            tools.append(AgentToolDefinition(
                name: "read_image",
                description: readImageDescription,
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'View generated bar chart', 'Inspect downloaded screenshot'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Linux path (e.g. /var/minis/attachments/chart.png) or minis:// URL (e.g. minis://attachments/chart.png)"),
                    "prompt": AgentToolParam(type: .string, description: promptDescription),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "prompt"]
            ))
        }

        // [T-tools-web-search] A real search API, because there was none.
        //
        // The roster had no way to look something up. A model asked for a fact
        // only on the web reached for `browser_use`, opened a search-engine home
        // page (Baidu, on a Chinese-locale device), and scraped whatever the
        // results page rendered — which is slow, gives a handful of hits, and
        // fails outright on a page that needs JS. `shell_execute` + curl was the
        // other route, and it is not reachable on a fresh install.
        //
        // Untitled in the required list on purpose: `tool_title` drives the live
        // pill header, and `preflightNonBlockingFields` already refuses to block
        // a call over it, so requiring it would only mean an extra field every
        // search has to get right.
        tools.append(AgentToolDefinition(
            name: "web_search",
            description: "Search the web and get back titled results with URLs and excerpts. Use this for any fact you do not already have: a work by name, a person, a place, a current event, a documentation page, an error message you have not seen before. Do NOT open a search engine's home page with `browser_use` to search — that scrapes a rendered results page, is far slower, and fails when the page needs JavaScript. Prefer this tool, then use `browser_use` only to open a URL this returned when you need the full page. The query is forwarded to a search provider, so write it as a search query (keywords, not a sentence or a question) in the language the sources are likely to be written in. Quote a name if it must match exactly. Return up to `limit` results, each a title, a URL and a short excerpt; the excerpt is truncated, so open the URL if you need the whole page.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user, e.g. 'Search for the novel’s author'. Use the same language as the user."),
                "query": AgentToolParam(type: .string, description: "The search query: keywords, not a sentence. Include the distinctive terms (a title, an author, a version) and the language the sources use. Use quotes for an exact phrase."),
                "limit": AgentToolParam(type: .integer, description: "How many results to return (default: 5, maximum: 10). Use more only when you need to compare several sources; each result costs context."),
            ],
            required: ["query"],
            propertyOrdering: ["tool_title", "query", "limit"]
        ))

        // [T-tools-todo-plan] The session task list, and the only way out of plan
        // mode.
        //
        // `todo_write`'s description is DSH's own text (`packages/todo/tool-todo`,
        // the `allowParallelInProgress: true` branch): it is what the model was
        // tuned against, and rewording it to "fit" this app would be a silent
        // behaviour change. `tool_title` is the one addition, because every other
        // tool in this app carries it.
        //
        // `todos` is declared as a STRING because the app's tool schema has no
        // array parameter type (`AgentParamType` is string / integer / boolean).
        // The description therefore has to say "JSON array" and show the shape —
        // the same workaround `browser_use`'s `cookies` uses. The parser accepts a
        // real array too, so a provider that ignores the schema still works.
        tools.append(AgentToolDefinition(
            name: "todo_write",
            description: "Record and update a structured task list for the current work. Send the ENTIRE list every call — it REPLACES the previous list (there are no partial updates, no per-item edits). Use it to plan multi-step work and show progress: add one todo per concrete step before you start. Mark every todo being actively worked on `in_progress` — several at once when work genuinely runs in parallel (e.g. concurrent subagents or background commands), one for sequential work; while work remains, at least one task should be `in_progress`. Mark a todo `completed` the moment it is done (do not batch completions), and allow no `in_progress` item only once all work is complete. Skip the list for trivial single-step tasks. Statuses: `pending` (not started), `in_progress` (being worked on now), `completed` (finished). The list is shown to the user in a panel above the input box, so keep each line short.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user, e.g. 'Plan the compression rewrite'. Use the same language as the user."),
                "todos": AgentToolParam(type: .string, description: #"The COMPLETE task list, as a JSON array — this replaces whatever list exists now. Shape: [{"content": "Read the existing parser", "status": "completed"}, {"content": "Add the fallback branch", "status": "in_progress"}]. Each item needs `content` (a short imperative line, unique within the list) and `status` (pending | in_progress | completed)."#),
            ],
            required: ["todos"],
            propertyOrdering: ["tool_title", "todos"]
        ))

        // DSH keeps this registered in every mode rather than adding it on entry,
        // so the tool catalog of a request does not change when the mode flips.
        // The call itself is refused outside plan mode.
        tools.append(AgentToolDefinition(
            name: "exit_plan_mode",
            // DSH's own wording (`plan-mode/src/index.ts`). It was paraphrased
            // here while the mode exited on the call itself; now that approving is
            // a real user decision, the review's outcome comes back in the tool
            // result, which is what this says.
            description: "Use only in plan mode. Present your plan for the user's review and, on approval, leave plan mode. Send the COMPLETE plan as markdown, starting with a # heading that names it. The user may approve (carry out the plan from your next step) or keep planning — their feedback comes back in the tool result; revise and present again.",
            parameters: [
                "plan": AgentToolParam(type: .string, description: "The complete plan, as markdown, starting with a # heading that names it."),
            ],
            required: ["plan"],
            propertyOrdering: ["plan"]
        ))

        // [T-tools-goal] DSH's goal tools (`packages/goal/tool-goal`): one
        // long-running completion objective per session, with the round budget
        // that makes it safe to leave running. Their schemas live in
        // `DSHGoalTools.definitions` because both iOS lines keep separate copies
        // of this file, and registered for every turn like the plan tools above,
        // so the catalog does not change when a goal appears.
        tools.append(contentsOf: DSHGoalTools.definitions)

        // [T-remote-team-dispatch] Teammates on the PAIRED computer
        // (`verify/DSH-REMOTE-TEAM-CONTRACT.md` §2). Registered only when a
        // computer is paired — the tools mean nothing without one, and a catalog
        // that promises a dispatch the device cannot perform is worse than no
        // tool at all. The auto-dispatch SWITCH does not gate registration: off
        // means "do not do this unprompted" (the prompt paragraph disappears),
        // not "this cannot be done" (contract §3, acceptance 9).
        if remoteTeamToolsEnabled {
            tools.append(contentsOf: remoteTeamToolDefinitions())
        }

        return tools
    }

    // MARK: - Remote team (paired computer)

    /// Whether the paired computer can serve teammates at all.
    ///
    /// `DSHRemoteTeamTools.availability` is the ONE owner of that answer (it
    /// probes `/dsh/team/members` and caches a throttled result); this property
    /// only renames it for the two readers here — the registration above and
    /// `remoteTeamPromptFragment` — so the tools and the policy can never
    /// disagree about whether the feature exists on this device.
    var remoteTeamAvailability: DSHRemoteTeamTools.Availability {
        DSHRemoteTeamTools.availability
    }

    /// Register the four tools ONLY when the paired host can actually serve them
    /// (`availability == .available`).
    ///
    /// `.notPaired` — nothing to dispatch to. `.unavailable` — the host has no
    /// agent-team service, and a dead tool that fails every call is worse than no
    /// tool: the model would burn turns discovering it. In that state the system
    /// prompt carries one sentence saying so instead (`remoteTeamPromptFragment`).
    var remoteTeamToolsEnabled: Bool {
        remoteTeamAvailability == .available
    }


    /// The dispatch policy (`verify/DSH-REMOTE-TEAM-CONTRACT.md` §3), appended to
    /// the local agent's system prompt.
    ///
    /// Empty string when there is nothing to say, so the call site is one line:
    /// * no paired computer → the tools do not exist, so a policy about them
    ///   would be a constant invitation to a missing capability;
    /// * `remoteTeamAutoDispatch` off → the tools stay, the policy goes (the user
    ///   asked for no unprompted dispatch, not for no dispatch);
    /// * host confirmed unavailable → one sentence instead of the policy, so the
    ///   model does the work here and tells the user why instead of calling a
    ///   tool it knows will fail.
    var remoteTeamPromptFragment: String {
        switch remoteTeamAvailability {
        case .notPaired:
            return ""
        case .unavailable:
            // Tools are NOT registered in this state, so the prompt says why one
            // is missing rather than describing a tool that will fail.
            return "\n\nRemote teammates: the computer this phone is paired with does not have the teammate feature enabled, so no `remote_team_*` tools are available. Do the work on this phone instead; if the task truly needs that machine, tell the user to update DS Bot on it."
        case .available:
            guard DSHRemoteTeamSettings.shared.autoDispatch else { return "" }
            return "\n\n" + Self.remoteTeamDispatchPolicy
        }
    }

    /// Contract §3, translated 1:1 (the contract states it in Chinese; this
    /// prompt is English like the rest of `baseSystemPrompt`). Conditions are
    /// ORs — any one of them is enough — and the last two sentences exist because
    /// the failure mode of "dispatch" is spawning a second teammate for the same
    /// job or forgetting to tell the user who is doing it.
    private static let remoteTeamDispatchPolicy: String = """
    Remote teammates: you have a computer paired with this phone (the `remote_team_*` tools). When a task meets ANY of the following, dispatch it to that computer instead of forcing it here:
    1. It needs a full desktop environment — Xcode / xcodebuild, Windows toolchains, Docker, large compiles, system-level dependencies, or devices on that computer's local network.
    2. The user explicitly points at that machine — "that computer", "my computer", "my mac", "on my computer", a `D:\\…` path, "ssh m2".
    3. It needs data this phone does not have — that workspace's large repositories, logs, or session records.
    4. You expect it to take more than 3 minutes to build or test here.
    Plain conversation, analysis, reading files on this phone, and small scripts stay here.
    When dispatching, write the COMPLETE initial task in `remote_team_spawn` — the teammate cannot see this phone, this conversation, or its files — and tell the user in your reply who you dispatched it to.
    For follow-ups on the same goal use `remote_team_message` to that same teammate (it keeps its context); do not spawn again.
    """

    /// The four tools of contract §2. Names and parameter keys are the registry
    /// `DSHRemoteTeamTools.run(name:arguments:)` parses, character for
    /// character — the schema and the handler cannot drift without this file
    /// changing too. Descriptions are the contract's own wording: the model reads
    /// "runs on the real desktop, self-contained task, follow up with message"
    /// and that is the whole behaviour spec it needs.
    private func remoteTeamToolDefinitions() -> [AgentToolDefinition] {
        let title = AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Run the build on my Mac', 'Ask ui-verify for the log'). Use the same language as the user.")
        return [
            AgentToolDefinition(
                name: "remote_team_spawn",
                description: "Dispatch a task to a teammate on the paired computer, which has the full desktop environment (Xcode, Windows tooling, real workspace). The teammate cannot see this device's context, so `task` must be self-contained. Returns the teammate name and host session id; follow up with remote_team_message.",
                parameters: [
                    "tool_title": title,
                    "task": AgentToolParam(type: .string, description: "The complete initial task. The teammate is a fresh agent on that computer: it cannot see this conversation, this phone, or its files, so include every path, command, constraint and the output you expect back."),
                    "name": AgentToolParam(type: .string, description: "Optional kebab-case teammate name. Omit it and one is generated from the task; a duplicate is retried automatically with -2/-3."),
                    "description": AgentToolParam(type: .string, description: "Optional one-line description of what this teammate is for, shown in the roster on that computer."),
                ],
                required: ["tool_title", "task"],
                propertyOrdering: ["tool_title", "task", "name", "description"]
            ),
            AgentToolDefinition(
                name: "remote_team_message",
                description: "Send another message to a teammate previously dispatched with remote_team_spawn. Same teammate, same session — it keeps its context.",
                parameters: [
                    "tool_title": title,
                    "target": AgentToolParam(type: .string, description: "The teammate's name, as returned by remote_team_spawn or listed by remote_team_list."),
                    "text": AgentToolParam(type: .string, description: "What to tell the teammate. It cannot see this conversation, so restate the question or the new requirement in full."),
                ],
                required: ["tool_title", "target", "text"],
                propertyOrdering: ["tool_title", "target", "text"]
            ),
            AgentToolDefinition(
                name: "remote_team_list",
                description: "List teammates on the paired computer with their role, status and session id.",
                parameters: [
                    "tool_title": title,
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title"]
            ),
            AgentToolDefinition(
                name: "remote_team_interrupt",
                description: "Stop a teammate's current turn on the paired computer.",
                parameters: [
                    "tool_title": title,
                    "target": AgentToolParam(type: .string, description: "The teammate to interrupt, by name."),
                ],
                required: ["tool_title", "target"],
                propertyOrdering: ["tool_title", "target"]
            ),
        ]
    }
}
