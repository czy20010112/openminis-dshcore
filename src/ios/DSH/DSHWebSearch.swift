//
//  DSHWebSearch.swift
//  Minis
//
//  The `web_search` tool: one query in, a list of titled hits out.
//
//  WHY THIS EXISTS
//  ---------------------------------------------------------------------------
//  The app shipped no search tool at all. Its tool surface was shell / files /
//  browser / memory / todo / plan, so "look something up on the web" had exactly
//  two possible answers: drive `browser_use` to a search-engine home page and
//  scrape the results (which is what the model did — Baidu by default, because
//  that is what a phone with a Chinese locale opens), or curl something from
//  `shell_execute`. Both are slow, both are brittle, and the second one is not
//  reachable on a fresh install. The user's report — "asked for one novel, got
//  three results and a broken-chain story" — is that failure, not a bad engine.
//
//  A real search API returns ten structured hits in under a second. That is the
//  whole point of this file.
//
//  WHY PROVIDERS INSTEAD OF ONE ENGINE
//  ---------------------------------------------------------------------------
//  There is no single best engine: Tavily is built for agents (it returns
//  extracted page content, which is what a model actually needs), Serper is
//  Google's index through a reseller, Brave has its own crawler, Exa is
//  semantic, SearXNG is whatever the user self-hosts, and Jina needs no key at
//  all. Rather than pick one, the shape of the request and the shape of the
//  response are the only two things each provider has to declare.
//
//  WHY A PRIORITY QUEUE INSTEAD OF ONE CONFIGURED PROVIDER
//  ---------------------------------------------------------------------------
//  One backend is a single point of failure, and the failures are ordinary: a
//  key that runs out of quota, a mirror that is down, an endpoint whose path is
//  one segment off. So the settings hold an ORDERED list of entries — each entry
//  is a provider with its own key and endpoint — and a call walks that list from
//  the top. The first entry that answers with hits is the answer; every entry
//  that failed is reported with its own reason, so a broken first entry cannot
//  hide the fact that it is broken. The same provider may appear more than once
//  (two Tavily keys, two mirrors), which is the case this shape exists for.
//
//  THE DEFAULT THAT SHIPS
//  ---------------------------------------------------------------------------
//  One enabled Tavily entry pointed at Tavily's own endpoint, carrying no key.
//  A key is required before it will answer, the settings row says `needs a key`,
//  and any user can add entries, reorder them by priority, or switch one off.
//
//  STORAGE
//  ---------------------------------------------------------------------------
//  `UserDefaults`, read live on every call rather than cached: this app registers
//  its own defaults at launch and rewrites the plist, so a cached copy would be
//  the one way for a settings change to need a relaunch. The queue is a single
//  JSON object under `minis.webSearch.entries`. The three keys of the pre-queue
//  shape (`minis.webSearch.provider`, `.apiKey.<provider>`, `.endpoint.<provider>`)
//  are read once by `DSHWebSearchConfig.migrate()`, turned into entries in the
//  order they were in force, and then deleted — after migration the old keys are
//  written by nothing and read by nothing.
//

import Foundation

// MARK: - Result

/// One search result, in the shape every provider is normalised to.
struct DSHWebSearchHit: Equatable {
    let title: String
    let url: String
    let snippet: String
}

// MARK: - Errors

/// A search failure that the MODEL has to be able to act on.
///
/// Every message names the provider, and an HTTP failure names the status and
/// the first part of the body, because those are the two facts that tell a model
/// whether to retry the same call, change the query, or stop and tell the user
/// that the key is wrong. A bare `URLError` reaching the transcript as "The
/// request timed out" is what makes a model loop.
struct DSHWebSearchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func transportError(provider: DSHWebSearchProvider, underlying: Error) -> DSHWebSearchError {
        let ns = underlying as NSError
        let hint: String
        switch ns.code {
        case NSURLErrorTimedOut:
            hint = "the request timed out"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            hint = "the device appears to be offline"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            hint = "the endpoint could not be reached (check the endpoint host)"
        default:
            hint = ns.localizedDescription
        }
        return DSHWebSearchError(
            message: "\(provider.displayName) search failed: \(hint) (\(ns.domain) \(ns.code))."
        )
    }

    static func invalidEndpoint(_ raw: String) -> DSHWebSearchError {
        DSHWebSearchError(
            message: "The configured search endpoint is not a usable http(s) URL: \"\(raw)\". "
                + "Fix the endpoint in Settings → Agent Runtime → Web Search."
        )
    }

    static func missingKey(_ provider: DSHWebSearchProvider) -> DSHWebSearchError {
        DSHWebSearchError(
            message: "\(provider.displayName) needs an API key and none is configured. "
                + "Add one in Settings → Agent Runtime → Web Search, or switch to a provider "
                + "that needs no key (Jina, or a self-hosted SearXNG)."
        )
    }

    static func httpFailure(provider: DSHWebSearchProvider, status: Int, body: String) -> DSHWebSearchError {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty ? "(empty response body)" : String(trimmed.prefix(200))
        let advice: String
        switch status {
        case 401, 403:
            advice = " The API key was rejected or lacks the search scope."
        case 404:
            advice = " The path is wrong for this provider — check the entry's endpoint."
        case 429:
            advice = " The quota or rate limit for this key is exhausted."
        case 500...599:
            advice = " The provider itself failed; a retry later may work."
        default:
            advice = ""
        }
        return DSHWebSearchError(
            message: "\(provider.displayName) returned HTTP \(status).\(advice) Response began: \(shown)"
        )
    }

    static func undecodable(
        provider: DSHWebSearchProvider,
        keys: [String],
        body: String
    ) -> DSHWebSearchError {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return DSHWebSearchError(
            message: "\(provider.displayName) returned a response with no result array "
                + "(looked for \(keys.joined(separator: " / "))). Decoding it as JSON failed or the "
                + "shape is unexpected. Response began: \(String(trimmed.prefix(200)))"
        )
    }
}

// MARK: - Transport

/// Everything a provider needs to build its request, so no provider has to
/// touch URLSession itself.
enum DSHWebSearchTransport {

    /// A 20s ceiling per request. A search API answers in about a second;
    /// anything past this is a hung connection, and letting a tool call hang
    /// blocks the whole turn. The queue multiplies this by the number of enabled
    /// entries it has to walk before one answers.
    static let timeout: TimeInterval = 20

    /// Identifies the app honestly. Deliberately NOT a browser UA: a search API
    /// wants to know it is serving a program, and pretending to be Safari is how
    /// a provider decides to start serving captchas.
    static var userAgent: String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1"
        return "Minis-iOS/\(version) (DeepSeek Harness; +https://openminis.app)"
    }

    static func get(
        _ url: URL,
        headers: [String: String] = [:]
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        return try await perform(request, headers: headers)
    }

    static func postJSON(
        _ url: URL,
        body: [String: Any],
        headers: [String: String] = [:]
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Not `try?`: a body that fails to encode used to be dropped silently, so
        // the request went out with no body at all and the provider's 400/422
        // read as the provider's fault. Nothing is sent now, and the message the
        // model sees says what actually broke.
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw DSHWebSearchError(
                message: "The search request body could not be encoded as JSON "
                    + "(\(error.localizedDescription)); the request was not sent. "
                    + "This is a bug in the app, not a provider failure."
            )
        }
        return try await perform(request, headers: headers)
    }

    private static func perform(
        _ request: URLRequest,
        headers: [String: String]
    ) async throws -> (status: Int, body: String) {
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        return (status, body)
    }

    /// Decode a JSON object body, throwing an error the model can read.
    static func object(
        _ body: String,
        provider: DSHWebSearchProvider,
        expecting keys: [String]
    ) throws -> [String: Any] {
        guard let data = body.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            throw DSHWebSearchError.undecodable(provider: provider, keys: keys, body: body)
        }
        return object
    }

    /// Pull `[[String: Any]]` out of an array field, tolerating `null`.
    static func array(_ object: [String: Any], _ keyPath: String) -> [[String: Any]] {
        var current: Any? = object
        for component in keyPath.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return [] }
            current = dict[String(component)]
        }
        return (current as? [[String: Any]]) ?? []
    }
}

// MARK: - Provider

/// One search backend.
///
/// This is the whole interface: the id the settings store, the label the screen
/// shows, whether it needs a key, the base URL to fall back on, and a function
/// that turns a query into hits. Adding a backend is adding a case.
enum DSHWebSearchProvider: String, CaseIterable, Identifiable {

    case tavily
    case serper
    case brave
    case exa
    case searxng
    case jina

    var id: String { rawValue }

    /// The name shown in the picker and in every error message.
    ///
    /// Rendered `verbatim` in the UI — these are product names, not words.
    var displayName: String {
        switch self {
        case .tavily: return "Tavily"
        case .serper: return "Serper"
        case .brave: return "Brave"
        case .exa: return "Exa"
        case .searxng: return "SearXNG"
        case .jina: return "Jina"
        }
    }

    /// Whether a key has to be present for this provider to be usable.
    var needsKey: Bool {
        switch self {
        case .jina, .searxng: return false
        case .tavily, .serper, .brave, .exa: return true
        }
    }

    /// The endpoint used when an entry has not overridden one.
    var defaultBase: String {
        switch self {
        case .tavily: return "https://api.tavily.com"
        case .serper: return "https://google.serper.dev"
        case .brave: return "https://api.search.brave.com/res/v1"
        case .exa: return "https://api.exa.ai"
        case .searxng: return ""
        case .jina: return "https://s.jina.ai"
        }
    }

    /// Whether the endpoint field has to be filled in by the user before the
    /// provider can work at all.
    var needsEndpoint: Bool {
        self == .searxng
    }

    // MARK: Search

    /// Run one query for one configured entry.
    ///
    /// The key and the base are passed in rather than read from the settings:
    /// one provider can be configured several times with different credentials,
    /// so the provider cannot be the thing that decides which one is in use. The
    /// queue owns that decision and hands the winner's values to this call.
    ///
    /// - Parameters:
    ///   - query: what to search for. Percent-encoded by `URLComponents` where
    ///     the provider takes it in a query string.
    ///   - limit: how many hits to ask for, already clamped by the caller.
    ///   - apiKey: the entry's key, empty when the entry has none.
    ///   - base: the entry's endpoint, or the provider's default.
    /// - Throws: a `DSHWebSearchError` whose message is written for the model.
    func search(
        query: String,
        limit: Int,
        apiKey: String,
        base: String
    ) async throws -> [DSHWebSearchHit] {
        guard !base.isEmpty, let root = DSHWebSearchEndpoint(base: base) else {
            throw DSHWebSearchError.invalidEndpoint(base)
        }
        if needsKey && apiKey.isEmpty {
            throw DSHWebSearchError.missingKey(self)
        }

        switch self {
        case .tavily:
            return try await searchTavily(root: root, key: apiKey, query: query, limit: limit)
        case .serper:
            return try await searchSerper(root: root, key: apiKey, query: query, limit: limit)
        case .brave:
            return try await searchBrave(root: root, key: apiKey, query: query, limit: limit)
        case .exa:
            return try await searchExa(root: root, key: apiKey, query: query, limit: limit)
        case .searxng:
            return try await searchSearXNG(root: root, query: query, limit: limit)
        case .jina:
            return try await searchJina(root: root, query: query, limit: limit)
        }
    }

    /// Relative path added to the base for this provider.
    ///
    /// Tavily's own API puts `/search` on the host root. An endpoint may carry a
    /// path of its own — a mirror, or a gateway that mounts the API under a
    /// prefix — which is why the base's own path is kept and this is appended to
    /// it: base `https://host/tavily` becomes `https://host/tavily/search`.
    private var searchPath: String {
        switch self {
        case .tavily: return "/search"
        case .serper: return "/search"
        case .brave: return "/web/search"
        case .exa: return "/search"
        case .searxng: return "/search"
        case .jina: return "/"
        }
    }

    private func searchTavily(
        root: DSHWebSearchEndpoint,
        key: String,
        query: String,
        limit: Int
    ) async throws -> [DSHWebSearchHit] {
        guard let url = root.url(path: searchPath) else {
            throw DSHWebSearchError.invalidEndpoint(root.raw)
        }
        let (status, body) = try await transport {
            try await DSHWebSearchTransport.postJSON(
                url,
                body: [
                    "query": query,
                    "max_results": min(max(limit, 1), 20),
                    "search_depth": "basic",
                ],
                headers: ["Authorization": "Bearer \(key)"]
            )
        }
        try check(status: status, body: body)
        // Newer responses wrap the array in `results`; the pre-2024 shape used
        // the same key, and older self-hosted builds use `data`. Both are read.
        let object = try DSHWebSearchTransport.object(
            body, provider: self, expecting: ["results", "data"]
        )
        var rows = DSHWebSearchTransport.array(object, "results")
        if rows.isEmpty { rows = DSHWebSearchTransport.array(object, "data") }
        return rows.compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            let title = (row["title"] as? String)?.nonEmpty ?? url
            let content = (row["content"] as? String)
                ?? (row["raw_content"] as? String)
                ?? (row["snippet"] as? String)
                ?? ""
            return DSHWebSearchHit(title: title, url: url, snippet: content)
        }
    }

    private func searchSerper(
        root: DSHWebSearchEndpoint,
        key: String,
        query: String,
        limit: Int
    ) async throws -> [DSHWebSearchHit] {
        guard let url = root.url(path: searchPath) else {
            throw DSHWebSearchError.invalidEndpoint(root.raw)
        }
        let (status, body) = try await transport {
            try await DSHWebSearchTransport.postJSON(
                url,
                body: ["q": query, "num": min(max(limit, 1), 10)],
                headers: ["X-API-KEY": key]
            )
        }
        try check(status: status, body: body)
        let object = try DSHWebSearchTransport.object(
            body, provider: self, expecting: ["organic", "answerBox"]
        )
        return DSHWebSearchTransport.array(object, "organic").compactMap { row in
            guard let url = row["link"] as? String, !url.isEmpty else { return nil }
            let title = (row["title"] as? String)?.nonEmpty ?? url
            let snippet = (row["snippet"] as? String)
                ?? (row["description"] as? String)
                ?? ""
            return DSHWebSearchHit(title: title, url: url, snippet: snippet)
        }
    }

    private func searchBrave(
        root: DSHWebSearchEndpoint,
        key: String,
        query: String,
        limit: Int
    ) async throws -> [DSHWebSearchHit] {
        guard let url = root.url(
            path: searchPath,
            query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "count", value: String(min(max(limit, 1), 20))),
            ]
        ) else {
            throw DSHWebSearchError.invalidEndpoint(root.raw)
        }
        let (status, body) = try await transport {
            try await DSHWebSearchTransport.get(
                url,
                headers: [
                    "X-Subscription-Token": key,
                    "Accept": "application/json",
                ]
            )
        }
        try check(status: status, body: body)
        let object = try DSHWebSearchTransport.object(
            body, provider: self, expecting: ["web.results"]
        )
        return DSHWebSearchTransport.array(object, "web.results").compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            let title = (row["title"] as? String)?.nonEmpty ?? url
            let snippet = (row["description"] as? String)
                ?? (row["snippet"] as? String)
                ?? ""
            return DSHWebSearchHit(title: title, url: url, snippet: snippet)
        }
    }

    private func searchExa(
        root: DSHWebSearchEndpoint,
        key: String,
        query: String,
        limit: Int
    ) async throws -> [DSHWebSearchHit] {
        guard let url = root.url(path: searchPath) else {
            throw DSHWebSearchError.invalidEndpoint(root.raw)
        }
        let (status, body) = try await transport {
            try await DSHWebSearchTransport.postJSON(
                url,
                body: [
                    "query": query,
                    "numResults": min(max(limit, 1), 20),
                    "contents": ["text": ["maxCharacters": 600]],
                ],
                headers: ["x-api-key": key]
            )
        }
        try check(status: status, body: body)
        let object = try DSHWebSearchTransport.object(body, provider: self, expecting: ["results"])
        return DSHWebSearchTransport.array(object, "results").compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            let title = (row["title"] as? String)?.nonEmpty ?? url
            // Exa's newest shape returns the text per result; older responses
            // carry it on the row itself.
            var snippet = (row["text"] as? String) ?? ""
            if snippet.isEmpty, let highlights = row["highlights"] as? [String] {
                snippet = highlights.joined(separator: " … ")
            }
            if snippet.isEmpty { snippet = (row["summary"] as? String) ?? "" }
            return DSHWebSearchHit(title: title, url: url, snippet: snippet)
        }
    }

    private func searchSearXNG(
        root: DSHWebSearchEndpoint,
        query: String,
        limit: Int
    ) async throws -> [DSHWebSearchHit] {
        guard let url = root.url(
            path: searchPath,
            query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "format", value: "json"),
            ]
        ) else {
            throw DSHWebSearchError.invalidEndpoint(root.raw)
        }
        let (status, body) = try await transport {
            try await DSHWebSearchTransport.get(url)
        }
        try check(status: status, body: body)
        let object = try DSHWebSearchTransport.object(body, provider: self, expecting: ["results"])
        return DSHWebSearchTransport.array(object, "results").compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            let title = (row["title"] as? String)?.nonEmpty ?? url
            let snippet = (row["content"] as? String) ?? (row["snippet"] as? String) ?? ""
            return DSHWebSearchHit(title: title, url: url, snippet: snippet)
        }
    }

    /// Jina's reader returns prose, not JSON, so the hits are parsed out of it.
    ///
    /// Two shapes are handled: a markdown page whose headings are links
    /// (`## [Title](url)`) and a plain link list (`[Title](url)` anywhere). When
    /// neither matches, the text is returned as a single hit whose URL is the
    /// reader URL itself — a model can still read it, and reporting nothing at
    /// all would be the worse answer.
    private func searchJina(
        root: DSHWebSearchEndpoint,
        query: String,
        limit: Int
    ) async throws -> [DSHWebSearchHit] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw DSHWebSearchError.invalidEndpoint(root.raw)
        }
        guard let url = URL(string: root.raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/" + encoded) else {
            throw DSHWebSearchError.invalidEndpoint(root.raw)
        }
        let (status, body) = try await transport {
            try await DSHWebSearchTransport.get(url, headers: ["Accept": "text/plain"])
        }
        try check(status: status, body: body)
        let parsed = DSHWebSearchText.parse(links: body, limit: limit)
        if !parsed.isEmpty { return parsed }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [DSHWebSearchHit(title: query, url: url.absoluteString, snippet: text)]
    }

    // MARK: Shared steps

    private func check(status: Int, body: String) throws {
        guard (200...299).contains(status) else {
            throw DSHWebSearchError.httpFailure(provider: self, status: status, body: body)
        }
    }

    /// Map a transport failure onto a provider-named error.
    private func transport<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as DSHWebSearchError {
            throw error
        } catch {
            throw DSHWebSearchError.transportError(provider: self, underlying: error)
        }
    }
}

// MARK: - Endpoint

/// A base URL that paths and query items can be appended to.
///
/// Hand-rolled rather than `URL.appendingPathComponent`, because that method
/// silently percent-encodes characters a search endpoint legitimately contains
/// and because a base with a path component of its own has to keep it. Anything
/// that will not parse is rejected here, once, instead of producing a request to
/// a nonsense host.
struct DSHWebSearchEndpoint {
    let raw: String
    private let components: URLComponents

    init?(base: String) {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              (components.host?.isEmpty == false) else { return nil }
        self.raw = trimmed
        self.components = components
    }

    func url(path: String, query: [URLQueryItem] = []) -> URL? {
        var components = self.components
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        var suffix = path
        if !suffix.hasPrefix("/") { suffix = "/" + suffix }
        components.path = basePath + (suffix == "/" ? "" : suffix)
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        return components.url
    }
}

// MARK: - Prose parsing

/// Link extraction for providers that answer in text rather than JSON.
enum DSHWebSearchText {

    /// Find markdown links in `body`, in order, de-duplicated by URL.
    static func parse(links body: String, limit: Int) -> [DSHWebSearchHit] {
        var hits: [DSHWebSearchHit] = []
        var seen = Set<String>()
        var lineStart = body.startIndex

        while lineStart < body.endIndex, hits.count < max(limit, 1) {
            guard let lineEnd = body[lineStart...].firstIndex(of: "\n") else { break }
            let rawLine = String(body[lineStart..<lineEnd])
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let link = firstMarkdownLink(in: line), seen.insert(link.url).inserted {
                hits.append(DSHWebSearchHit(
                    title: link.title.nonEmpty ?? link.url,
                    url: link.url,
                    // The heading text after the link is Jina's one-line summary
                    // when it has one; there is nothing else to use as a snippet.
                    snippet: line.replacingOccurrences(of: link.raw, with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#-* \t"))
                ))
            }
            lineStart = body.index(after: lineEnd)
        }
        return hits
    }

    /// The first `[title](url)` in a line, with the matched substring so the
    /// caller can strip it back out.
    static func firstMarkdownLink(in line: String) -> (title: String, url: String, raw: String)? {
        var searchStart = line.startIndex
        while let open = line[searchStart...].firstIndex(of: "[") {
            guard let close = line[line.index(after: open)...].firstIndex(of: "]") else { return nil }
            let afterClose = line.index(after: close)
            guard afterClose < line.endIndex, line[afterClose] == "(" else {
                searchStart = line.index(after: open)
                continue
            }
            guard let paren = line[line.index(after: afterClose)...].firstIndex(of: ")") else {
                return nil
            }
            let title = String(line[line.index(after: open)..<close])
            let url = String(line[line.index(after: afterClose)..<paren])
            guard url.lowercased().hasPrefix("http") else {
                searchStart = line.index(after: open)
                continue
            }
            let raw = String(line[open...paren])
            return (title, url, raw)
        }
        return nil
    }
}

// MARK: - Entry

/// One position in the search priority queue: a provider, plus the credentials
/// that this particular occurrence of it uses.
///
/// The same provider can appear any number of times — two Tavily keys, one
/// vendor endpoint and one mirror — which is why the key and the endpoint live
/// here and not on `DSHWebSearchProvider`. `id` is what makes a list of these
/// editable and reorderable in place.
struct DSHWebSearchEntry: Identifiable, Equatable {
    let id: String
    var enabled: Bool
    var provider: DSHWebSearchProvider
    var label: String
    var apiKey: String
    var endpoint: String

    init(
        id: String = UUID().uuidString,
        enabled: Bool = true,
        provider: DSHWebSearchProvider = .tavily,
        label: String = "",
        apiKey: String = "",
        endpoint: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.provider = provider
        self.label = label
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    /// The endpoint in force: the entry's own, or the provider's default.
    var base: String {
        endpoint.isEmpty ? provider.defaultBase : endpoint
    }

    /// What the settings row and the transcript call this entry: the note the
    /// user gave it, or the provider's name when there is no note.
    var title: String {
        label.nonEmpty ?? provider.displayName
    }

    /// One-line identity for the transcript and for error text:
    /// `Tavily "mirror" (api.tavily.com)`. The host is included so two entries
    /// for one provider can be told apart in a failure report.
    var describe: String {
        var text = title
        if let host = URL(string: base)?.host, !host.isEmpty {
            text += " (\(host))"
        }
        return text
    }

    /// What is wrong with this entry as configured, or nil when it can run.
    /// A disabled entry is not a problem — it is switched off on purpose.
    var status: String? {
        guard enabled else { return nil }
        if provider.needsKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "needs a key"
        }
        if base.isEmpty { return "needs an endpoint" }
        return nil
    }

    /// Run one query through this entry.
    func search(query: String, limit: Int) async throws -> [DSHWebSearchHit] {
        try await provider.search(query: query, limit: limit, apiKey: apiKey, base: base)
    }
}

extension DSHWebSearchEntry {

    /// The stored shape: flat, string-keyed, so a field added later reads back
    /// as its default instead of invalidating the whole row.
    var json: [String: Any] {
        [
            "id": id,
            "enabled": enabled,
            "provider": provider.rawValue,
            "label": label,
            "apiKey": apiKey,
            "endpoint": endpoint,
        ]
    }

    /// Read one stored entry. A row with no provider, or with one this build
    /// does not know, is dropped rather than guessed at.
    init?(json: Any) {
        guard let row = json as? [String: Any],
              let raw = row["provider"] as? String,
              let provider = DSHWebSearchProvider(rawValue: raw) else { return nil }
        self.init(
            id: (row["id"] as? String)?.nonEmpty ?? UUID().uuidString,
            enabled: (row["enabled"] as? Bool) ?? true,
            provider: provider,
            label: (row["label"] as? String) ?? "",
            apiKey: ((row["apiKey"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: ((row["endpoint"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Configuration

/// The stored settings, read live.
///
/// Everything is `static` and reads `UserDefaults` on each access on purpose:
/// the tool call path is not the main actor, this app rewrites its defaults at
/// launch, and a cached copy would be the one way for a settings change to need
/// a relaunch.
enum DSHWebSearchConfig {

    enum Key {
        /// The whole queue, as one JSON object: `{"version": 1, "entries": [ … ]}`.
        /// One key, so a reorder is one atomic write and no entry can be left
        /// half-saved against another.
        static let entries = "minis.webSearch.entries"
    }

    /// The pre-queue shape. Read by `migrate()` and deleted by it; nothing else
    /// in the app touches these, and nothing writes them any more.
    enum LegacyKey {
        static let provider = "minis.webSearch.provider"
        static func apiKey(_ provider: DSHWebSearchProvider) -> String {
            "minis.webSearch.apiKey.\(provider.rawValue)"
        }
        static func endpoint(_ provider: DSHWebSearchProvider) -> String {
            "minis.webSearch.endpoint.\(provider.rawValue)"
        }
    }

    /// The queue in force, in priority order (highest first), migrating the
    /// pre-queue settings the first time it is read.
    static var entries: [DSHWebSearchEntry] {
        load()
    }

    /// The most hits a query may ask for, and the default when the model does
    /// not say. Ten is the point past which a model stops reading them.
    static let defaultLimit = 5
    static let maxLimit = 10

    // MARK: Reading

    private static func load() -> [DSHWebSearchEntry] {
        if let raw = UserDefaults.standard.string(forKey: Key.entries),
           let data = raw.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let rows = object["entries"] as? [Any] {
            // A stored list is authoritative even when it is empty: an empty
            // queue is a decision the user made, and it is reported as one
            // rather than silently refilled with a default entry.
            return deduplicated(rows.compactMap { DSHWebSearchEntry(json: $0) })
        }
        return migrate()
    }

    /// Drop rows whose id repeats, so `ForEach` cannot collapse two entries into
    /// one row (which would make a reorder silently discard one of them).
    private static func deduplicated(_ entries: [DSHWebSearchEntry]) -> [DSHWebSearchEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    // MARK: Writing

    /// Persist the queue. Returns false if the object could not be serialised, which
    /// cannot happen for a dictionary of strings in practice — but the previous
    /// `try?` swallowed it into a silent "the edit disappeared", and a silent write
    /// failure in settings is the one kind of bug nobody can diagnose later.
    @discardableResult
    static func setEntries(_ entries: [DSHWebSearchEntry]) -> Bool {
        let object: [String: Any] = [
            "version": 1,
            "entries": entries.map { $0.json },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            assertionFailure("web_search queue could not be encoded; the edit is lost")
            return false
        }
        UserDefaults.standard.set(text, forKey: Key.entries)
        return true
    }

    /// Back to the shipped default: one enabled Tavily entry, no key.
    static func resetToDefaults() {
        setEntries([DSHWebSearchEntry(provider: .tavily)])
        clearLegacyKeys()
    }

    // MARK: Migration

    /// Turn the pre-queue settings into queue entries, once.
    ///
    /// The old shape was one key and one endpoint PER PROVIDER plus one selected
    /// provider. Every provider that carried a key or an endpoint becomes an
    /// entry — nothing the user typed is dropped — with the selected one first,
    /// because that is the one that was in force and it keeps priority 1.
    /// Providers that were never touched are skipped rather than turned into
    /// rows that ask for a key the user never had. If nothing at all was stored,
    /// the queue is the shipped default.
    ///
    /// The legacy keys are deleted once the queue is written, so a later read
    /// cannot migrate the same values twice and the two shapes can never
    /// disagree about what is configured.
    private static func migrate() -> [DSHWebSearchEntry] {
        let defaults = UserDefaults.standard
        let selected = defaults.string(forKey: LegacyKey.provider)
            .flatMap { DSHWebSearchProvider(rawValue: $0) }

        var order: [DSHWebSearchProvider] = []
        if let selected { order.append(selected) }
        for provider in DSHWebSearchProvider.allCases where !order.contains(provider) {
            order.append(provider)
        }

        var migrated: [DSHWebSearchEntry] = []
        for provider in order {
            let key = trimmed(defaults.string(forKey: LegacyKey.apiKey(provider)))
            let endpoint = trimmed(defaults.string(forKey: LegacyKey.endpoint(provider)))
            guard provider == selected || !key.isEmpty || !endpoint.isEmpty else { continue }
            migrated.append(DSHWebSearchEntry(provider: provider, apiKey: key, endpoint: endpoint))
        }
        if migrated.isEmpty {
            migrated = [DSHWebSearchEntry(provider: .tavily)]
        }
        setEntries(migrated)
        clearLegacyKeys()
        return migrated
    }

    /// Delete the pre-queue keys. Called after migration, and by the reset.
    static func clearLegacyKeys() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: LegacyKey.provider)
        for provider in DSHWebSearchProvider.allCases {
            defaults.removeObject(forKey: LegacyKey.apiKey(provider))
            defaults.removeObject(forKey: LegacyKey.endpoint(provider))
        }
    }

    private static func trimmed(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Queue

/// One entry's turn: what it was, where it sat, and what came back.
struct DSHWebSearchAttempt {
    let entry: DSHWebSearchEntry
    /// 1-based position among the entries that were tried.
    let index: Int
    /// How many entries were enabled for this call.
    let total: Int
    /// Hits the entry returned; 0 for a failure.
    let hits: Int
    /// Why it failed, or nil when it answered (even with nothing to report).
    let error: String?

    /// One line: which entry, and what it did.
    var line: String {
        "\(entry.describe) — \(error ?? "returned 0 results")"
    }
}

/// The priority queue: walk the enabled entries from the top, and stop at the
/// first one that produces hits.
///
/// "Failed" means the entry could not answer at all — an unusable endpoint, a
/// missing key, an HTTP error status, a body that would not decode, a hung
/// connection. An entry that answers correctly with an empty result list is not
/// a failure; it is tried, recorded as having found nothing, and the queue moves
/// on, because a mirror that returns 200-and-nothing is exactly the case a
/// second entry is for. If every entry answers empty, the tool reports "no
/// results" with the entries it asked. If every entry fails, the tool reports
/// every reason, one per line, in the order they were tried.
enum DSHWebSearchQueue {

    /// What one call did.
    struct Run {
        let hits: [DSHWebSearchHit]
        /// The entry that produced the hits, or the last one that answered
        /// cleanly when nothing was found anywhere.
        let answered: DSHWebSearchAttempt?
        /// Every entry that was tried, in order, failures included.
        let attempts: [DSHWebSearchAttempt]

        var failed: [DSHWebSearchAttempt] { attempts.filter { $0.error != nil } }
    }

    /// Thrown when there was nothing to try, or when every entry that was tried
    /// failed. The message carries one line per entry.
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Run one query down the queue.
    ///
    /// - Parameter entries: the whole queue, in priority order — including the
    ///   entries that are switched off, so the "nothing enabled" message can say
    ///   how many were skipped.
    static func run(
        query: String,
        limit: Int,
        entries: [DSHWebSearchEntry]
    ) async throws -> Run {
        let queue = entries.filter(\.enabled)
        guard !queue.isEmpty else {
            throw Failure(message: nothingEnabled(entries: entries))
        }

        var attempts: [DSHWebSearchAttempt] = []
        for (offset, entry) in queue.enumerated() {
            let index = offset + 1
            do {
                let hits = try await entry.search(query: query, limit: limit)
                let attempt = DSHWebSearchAttempt(
                    entry: entry,
                    index: index,
                    total: queue.count,
                    hits: hits.count,
                    error: nil
                )
                attempts.append(attempt)
                // An entry that found nothing does not end the walk.
                if hits.isEmpty { continue }
                return Run(hits: hits, answered: attempt, attempts: attempts)
            } catch {
                attempts.append(DSHWebSearchAttempt(
                    entry: entry,
                    index: index,
                    total: queue.count,
                    hits: 0,
                    error: error.localizedDescription
                ))
            }
        }

        if let answered = attempts.last(where: { $0.error == nil }) {
            return Run(hits: [], answered: answered, attempts: attempts)
        }
        throw Failure(message: allFailed(query: query, attempts: attempts))
    }

    // MARK: Messages

    /// The line that says which entry answered: provider, the user's note for it,
    /// the endpoint host, and where it sat in the queue.
    static func sourceLine(hits: Int, query: String, answered: DSHWebSearchAttempt) -> String {
        var text = "web_search: \(hits) result\(hits == 1 ? "" : "s") for \"\(query)\" "
            + "via \(answered.entry.describe)"
        if answered.total > 1 {
            text += " (entry \(answered.index) of \(answered.total))"
        }
        return text + "."
    }

    static func nothingEnabled(entries: [DSHWebSearchEntry]) -> String {
        if entries.isEmpty {
            return "web_search has no search entries configured. "
                + "Add one in Settings → Agent Runtime → Web Search."
        }
        return "web_search: all \(entries.count) search entries are switched off. "
            + "Enable one in Settings → Agent Runtime → Web Search."
    }

    /// One line per attempted entry, in the order they were tried.
    static func summary(_ attempts: [DSHWebSearchAttempt]) -> String {
        attempts.map { "\($0.index). \($0.line)" }.joined(separator: "\n")
    }

    static func allFailed(query: String, attempts: [DSHWebSearchAttempt]) -> String {
        "web_search failed: all \(attempts.count) enabled "
            + "\(attempts.count == 1 ? "entry" : "entries") failed for \"\(query)\".\n"
            + summary(attempts) + "\n"
            + "Fix a key or an endpoint, reorder the entries, or switch one off, "
            + "in Settings → Agent Runtime → Web Search."
    }
}

// MARK: - Tool

/// The `web_search` tool's model-facing behaviour.
///
/// Kept out of the dispatcher switch so the whole feature — settings, provider
/// dispatch, the fallback walk, result formatting — lives in one file, and so
/// the formatting can be exercised without a ViewModel.
enum DSHWebSearchTool {

    /// Run one `web_search` call.
    ///
    /// - Parameters:
    ///   - args: the call's parsed arguments (`query`, optional `limit`).
    ///   - entries: the queue to use; defaults to the configured one, and is
    ///     injectable so this can be exercised against fixed entries.
    static func run(
        args: [String: Any],
        entries: [DSHWebSearchEntry]? = nil
    ) async -> DSHToolOutcome {
        let query = ((args["query"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .failed("web_search: `query` is required and was empty.")
        }
        let limit = clampLimit(args["limit"])
        let queue = entries ?? DSHWebSearchConfig.entries

        do {
            let run = try await DSHWebSearchQueue.run(query: query, limit: limit, entries: queue)
            guard let answered = run.answered, !run.hits.isEmpty else {
                return .ok(noResults(query: query, attempts: run.attempts))
            }
            return .ok(format(run: run, query: query, answered: answered))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Clamp the model's `limit` into something a provider will accept.
    ///
    /// The schema declares it as an integer, but a provider that ignores the
    /// schema may send a string, so both are read — the same tolerance
    /// `todo_write` shows for its array.
    static func clampLimit(_ raw: Any?) -> Int {
        var value: Int?
        if let n = raw as? Int {
            value = n
        } else if let n = raw as? NSNumber {
            value = n.intValue
        } else if let s = raw as? String {
            value = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let value, value > 0 else { return DSHWebSearchConfig.defaultLimit }
        return min(value, DSHWebSearchConfig.maxLimit)
    }

    /// Render hits as a numbered list, after the line naming the entry that
    /// answered and a line for each higher-priority entry that failed.
    ///
    /// Every snippet is truncated: a Tavily hit carries a full extracted page
    /// section, and five of those is more context than the search was worth.
    /// The model can `browser_use` or `fetch` a URL when it needs the rest.
    static func format(
        run: DSHWebSearchQueue.Run,
        query: String,
        answered: DSHWebSearchAttempt
    ) -> String {
        var lines = [
            DSHWebSearchQueue.sourceLine(hits: run.hits.count, query: query, answered: answered)
        ]
        let skipped = run.failed
        if !skipped.isEmpty {
            lines.append("Skipped \(skipped.count) higher-priority "
                + "\(skipped.count == 1 ? "entry" : "entries") that failed:")
            for attempt in skipped { lines.append("   \(attempt.line)") }
        }
        lines.append("")
        for (index, hit) in run.hits.enumerated() {
            lines.append("\(index + 1). \(hit.title)")
            lines.append("   \(hit.url)")
            let snippet = hit.snippet
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty {
                lines.append("   \(String(snippet.prefix(snippetLimit)))")
            }
        }
        lines.append("")
        lines.append("Open a result's URL with `browser_use` if you need the full page.")
        return lines.joined(separator: "\n")
    }

    /// What a call says when entries answered but none had a hit: which entries
    /// were asked, and what each of them did.
    static func noResults(query: String, attempts: [DSHWebSearchAttempt]) -> String {
        var lines = ["web_search: no results for \"\(query)\". Tried \(attempts.count) "
            + "\(attempts.count == 1 ? "entry" : "entries"):"]
        for attempt in attempts { lines.append("   \(attempt.line)") }
        lines.append("Try fewer or different words, or a different spelling of the name.")
        return lines.joined(separator: "\n")
    }

    /// Characters of one snippet that reach the model.
    static let snippetLimit = 300
}

// MARK: - Small helpers

private extension String {
    /// The string itself, or nil when it is blank — so `??` chains can fall
    /// through to the next candidate field.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
