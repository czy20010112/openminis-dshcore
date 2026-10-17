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
//  THE DEFAULT THAT SHIPS
//  ---------------------------------------------------------------------------
//  Default provider is Tavily, pointed at Tavily's own endpoint. A key is required
//  before it will answer, and the settings screen says so. Any user can replace
//  the endpoint, the key, or the provider in Settings → Agent Runtime → Web Search.
//
//  STORAGE
//  ---------------------------------------------------------------------------
//  `UserDefaults`, read live on every call rather than cached: this app registers
//  its own defaults at launch and rewrites the plist, so a value written from
//  outside the app is discarded. Everything below reads through
//  `DSHWebSearchProvider.effectiveKey()` and friends at call time, which is what
//  makes a settings change take effect on the very next search with no relaunch.
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
            advice = " The path is wrong for this provider — check the endpoint override"
                + " (Tavily's proxy path is /tavily, so the base ends in /tavily)."
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

    /// A 20s ceiling. A search API answers in about a second; anything past this
    /// is a hung connection, and letting a tool call hang blocks the whole turn.
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
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
/// This is the whole interface: the id the setting stores, the label the screen
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

    /// One line of what the backend is, and what a caller gets from it.
    /// A catalog key.
    var summary: String {
        switch self {
        case .tavily:
            return "A search API built for AI agents: it returns page content, not just links."
        case .serper:
            return "Google's index through a reseller; good coverage of Chinese-language results."
        case .brave:
            return "Brave's own independent index, with a free tier."
        case .exa:
            return "Neural search: it matches meaning rather than keywords."
        case .searxng:
            return "A self-hosted meta-search instance. Point the endpoint at your own."
        case .jina:
            return "Jina's reader endpoint. No API key required."
        }
    }

    /// Whether a key has to be present for this provider to be usable.
    var needsKey: Bool {
        switch self {
        case .jina, .searxng: return false
        case .tavily, .serper, .brave, .exa: return true
        }
    }

    /// The endpoint used when the user has not overridden one.
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

    /// The API key in force: whatever the user stored, or nothing.
    func effectiveKey() -> String {
        DSHWebSearchConfig.apiKey(for: self)
    }

    /// The base endpoint in force: the user's override, or the default.
    func effectiveBase() -> String {
        let override = DSHWebSearchConfig.endpointOverride(for: self)
        return override.isEmpty ? defaultBase : override
    }

    // MARK: Search

    /// Run one query.
    ///
    /// - Parameters:
    ///   - query: what to search for. Percent-encoded by `URLComponents` where
    ///     the provider takes it in a query string.
    ///   - limit: how many hits to ask for, already clamped by the caller.
    /// - Throws: a `DSHWebSearchError` whose message is written for the model.
    func search(query: String, limit: Int) async throws -> [DSHWebSearchHit] {
        let base = effectiveBase()
        guard let root = DSHWebSearchEndpoint(base: base), !base.isEmpty else {
            throw DSHWebSearchError.invalidEndpoint(base)
        }
        let key = effectiveKey()
        if needsKey && key.isEmpty {
            throw DSHWebSearchError.missingKey(self)
        }

        switch self {
        case .tavily:
            return try await searchTavily(root: root, key: key, query: query, limit: limit)
        case .serper:
            return try await searchSerper(root: root, key: key, query: query, limit: limit)
        case .brave:
            return try await searchBrave(root: root, key: key, query: query, limit: limit)
        case .exa:
            return try await searchExa(root: root, key: key, query: query, limit: limit)
        case .searxng:
            return try await searchSearXNG(root: root, query: query, limit: limit)
        case .jina:
            return try await searchJina(root: root, query: query, limit: limit)
        }
    }

    /// Relative path added to the base for this provider.
    ///
    /// Tavily's own API puts `/search` on the host root; the operator's proxy
    /// puts the whole API under `/tavily`, which is why the shipped base ends in
    /// `/tavily` and the path here is still `/search`. A user overriding the
    /// endpoint with `https://api.tavily.com` gets the same correct request.
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
/// and because a base with a path component (the shipped `/tavily`) has to keep
/// it. Anything that will not parse is rejected here, once, instead of
/// producing a request to a nonsense host.
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

// MARK: - Configuration

/// The stored settings, read live.
///
/// Everything is `static` and reads `UserDefaults` on each access on purpose:
/// the tool call path is not the main actor, this app rewrites its defaults at
/// launch, and a cached copy would be the one way for a settings change to need
/// a relaunch.
enum DSHWebSearchConfig {


    enum Key {
        static let provider = "minis.webSearch.provider"
        static func apiKey(_ provider: DSHWebSearchProvider) -> String {
            "minis.webSearch.apiKey.\(provider.rawValue)"
        }
        static func endpoint(_ provider: DSHWebSearchProvider) -> String {
            "minis.webSearch.endpoint.\(provider.rawValue)"
        }
    }

    /// The provider in force, defaulting to the shipped one.
    static var provider: DSHWebSearchProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.provider),
                  let provider = DSHWebSearchProvider(rawValue: raw) else { return .tavily }
            return provider
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.provider) }
    }

    /// The key the user typed for one provider. Empty when unset.
    ///
    /// Per provider, not global: switching providers and back must not lose the
    /// key that was already working.
    static func apiKey(for provider: DSHWebSearchProvider) -> String {
        (UserDefaults.standard.string(forKey: Key.apiKey(provider)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setAPIKey(_ value: String, for provider: DSHWebSearchProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Key.apiKey(provider))
        } else {
            UserDefaults.standard.set(trimmed, forKey: Key.apiKey(provider))
        }
    }

    /// The endpoint the user typed for one provider. Empty means "use the
    /// default".
    static func endpointOverride(for provider: DSHWebSearchProvider) -> String {
        (UserDefaults.standard.string(forKey: Key.endpoint(provider)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setEndpointOverride(_ value: String, for provider: DSHWebSearchProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Key.endpoint(provider))
        } else {
            UserDefaults.standard.set(trimmed, forKey: Key.endpoint(provider))
        }
    }

    /// Forget everything, so the shipped default applies again.
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: Key.provider)
        for provider in DSHWebSearchProvider.allCases {
            UserDefaults.standard.removeObject(forKey: Key.apiKey(provider))
            UserDefaults.standard.removeObject(forKey: Key.endpoint(provider))
        }
    }

    /// The most hits a query may ask for, and the default when the model does
    /// not say. Ten is the point past which a model stops reading them.
    static let defaultLimit = 5
    static let maxLimit = 10
}

// MARK: - Tool

/// The `web_search` tool's model-facing behaviour.
///
/// Kept out of the dispatcher switch so the whole feature — settings, provider
/// dispatch, result formatting — lives in one file, and so the formatting can be
/// exercised without a ViewModel.
enum DSHWebSearchTool {

    /// Run one `web_search` call.
    ///
    /// - Parameters:
    ///   - args: the call's parsed arguments (`query`, optional `limit`).
    ///   - provider: the provider to use; defaults to the configured one, and is
    ///     injectable so this can be tested against a fixed backend.
    static func run(
        args: [String: Any],
        provider: DSHWebSearchProvider? = nil
    ) async -> DSHToolOutcome {
        let query = ((args["query"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .failed("web_search: `query` is required and was empty.")
        }
        let resolved = provider ?? DSHWebSearchConfig.provider
        let limit = clampLimit(args["limit"])

        do {
            let hits = try await resolved.search(query: query, limit: limit)
            guard !hits.isEmpty else {
                return .ok(
                    "web_search: no results for \"\(query)\" via \(resolved.displayName). "
                        + "Try fewer or different words, or a different spelling of the name."
                )
            }
            return .ok(format(hits: hits, query: query, provider: resolved))
        } catch let error as DSHWebSearchError {
            return .failed(error.message)
        } catch {
            return .failed("web_search failed: \(error.localizedDescription)")
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

    /// Render hits as a numbered list.
    ///
    /// Every snippet is truncated: a Tavily hit carries a full extracted page
    /// section, and five of those is more context than the search was worth.
    /// The model can `browser_use` or `fetch` a URL when it needs the rest.
    static func format(
        hits: [DSHWebSearchHit],
        query: String,
        provider: DSHWebSearchProvider
    ) -> String {
        var lines = [
            "web_search: \(hits.count) result\(hits.count == 1 ? "" : "s") for \"\(query)\" via \(provider.displayName).",
            "",
        ]
        for (index, hit) in hits.enumerated() {
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
