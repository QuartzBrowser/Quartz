import Foundation
import WebKit

enum QuartzWebMCPError: LocalizedError {
    case unavailable, pageChanged, invalidTools, timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable: "Page tools are available on loaded HTTPS pages and localhost development pages."
        case .pageChanged: "The page or its tools changed. Send your request again to use the current page."
        case .invalidTools: "This page provided an unsupported WebMCP tool definition or result."
        case .timedOut: "The page tool took too long to respond."
        }
    }
}

struct QuartzWebMCPTool: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let inputSchema: FacetJSONValue
    let title: String?
    let annotations: FacetJSONValue?
}

struct QuartzWebMCPPage: Sendable {
    let documentID: String
    let url: URL
    let generation: UInt64
    let tools: [QuartzWebMCPTool]

    // Provider function names have tighter constraints than WebMCP names. Keep
    // the page's names as data and use request-local aliases on the model wire.
    var definitions: [FacetToolDefinition] {
        tools.enumerated().map { index, tool in
            var schema = tool.inputSchema
            if case .object(var properties) = schema, properties["type"] == nil {
                properties["type"] = .string("object")
                schema = .object(properties)
            }
            return FacetToolDefinition(
                name: "quartz_page_tool_\(index)",
                description: "Page tool \(tool.name) on \(url.absoluteString):\n\(tool.description)",
                inputSchema: schema
            )
        }
    }

    func tool(named alias: String) -> QuartzWebMCPTool? {
        guard let index = definitions.firstIndex(where: { $0.name == alias }) else { return nil }
        return tools[index]
    }
}

/// An in-process bridge into the current main document. It exposes no native
/// message handlers or remote MCP endpoint to websites.
@MainActor
final class QuartzWebMCPBridge {
    private(set) var generation: UInt64 = 0
    private var policyAllowsTools = true
    private var pendingPolicyAllowsTools: Bool?
    private var historyPolicies: [ObjectIdentifier: (WKBackForwardListItem, Bool)] = [:]

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: QuartzWebMCPScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
    }

    func invalidate() {
        generation &+= 1
        pendingPolicyAllowsTools = nil
    }

    func commitMainDocument(history: WKBackForwardList? = nil, isHistoryNavigation: Bool = false) {
        let item = history?.currentItem
        let saved = item.flatMap { historyPolicies[ObjectIdentifier($0)]?.1 }
        // A back/forward cache restoration may have no navigation response. Retain
        // the policy associated with the native history item, never page metadata.
        policyAllowsTools = pendingPolicyAllowsTools ?? saved ?? !isHistoryNavigation
        pendingPolicyAllowsTools = nil
        if let history {
            let retained = Set((history.backList + history.forwardList + (item.map { [$0] } ?? [])).map(ObjectIdentifier.init))
            historyPolicies = historyPolicies.filter { retained.contains($0.key) }
        }
        if let item { historyPolicies[ObjectIdentifier(item)] = (item, policyAllowsTools) }
    }

    func receiveMainDocumentResponse(_ response: URLResponse) {
        guard let response = response as? HTTPURLResponse else { return }
        pendingPolicyAllowsTools = Self.policyAllowsTools(
            response.value(forHTTPHeaderField: "Permissions-Policy"), url: response.url
        )
    }

    static func isEligibleURL(_ url: URL?) -> Bool {
        guard let url, url.absoluteString.utf8.count <= 8192,
              let host = url.host?.lowercased(), !host.isEmpty, host.utf8.count <= 253,
              url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        guard url.scheme?.lowercased() == "http" else { return false }
        return host == "localhost" || host.hasSuffix(".localhost")
            || host == "127.0.0.1" || host == "[::1]" || host == "::1"
    }

    static func policyAllowsTools(_ header: String?, url: URL?) -> Bool {
        guard let header else { return true }
        let directives = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for directive in directives {
            let parts = directive.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first == "tools" else { continue }
            guard parts.count == 2 else { return false }
            if parts[1] == "*" { continue }
            guard parts[1].hasPrefix("("), parts[1].hasSuffix(")") else { return false }
            let entries = parts[1].dropFirst().dropLast().split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if entries.contains("self") { continue }
            guard let url, entries.contains(where: { entry in
                guard entry.hasPrefix("\""), entry.hasSuffix("\""),
                      let allowed = URL(string: String(entry.dropFirst().dropLast())) else { return false }
                return origin(allowed) == origin(url)
            }) else { return false }
        }
        return true
    }

    private static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)"
    }

    func discover(in webView: WKWebView) async throws -> QuartzWebMCPPage? {
        try Task.checkCancellation()
        guard policyAllowsTools, !webView.isLoading, Self.isEligibleURL(webView.url), let url = webView.url else {
            return nil
        }
        let expectedGeneration = generation
        let data = try await evaluate(QuartzWebMCPScript.snapshotScript, in: webView)
        guard generation == expectedGeneration, webView.url == url, !webView.isLoading, policyAllowsTools else {
            throw QuartzWebMCPError.pageChanged
        }
        if data == Data("null".utf8) { return nil }
        struct Snapshot: Decodable {
            let documentID: String
            let tools: [QuartzWebMCPTool]
        }
        guard data.count <= 512 * 1024,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.documentID.isEmpty, snapshot.documentID.utf8.count <= 200,
              snapshot.tools.count <= 64,
              Set(snapshot.tools.map(\.id)).count == snapshot.tools.count,
              snapshot.tools.allSatisfy(Self.validTool) else {
            throw QuartzWebMCPError.invalidTools
        }
        return QuartzWebMCPPage(documentID: snapshot.documentID, url: url, generation: generation, tools: snapshot.tools)
    }

    private static func validTool(_ tool: QuartzWebMCPTool) -> Bool {
        guard !tool.id.isEmpty, tool.id.utf8.count <= 200,
              !tool.name.isEmpty, tool.name.utf8.count <= 200,
              !tool.description.isEmpty, tool.description.utf8.count <= 16_384,
              (tool.title?.utf8.count ?? 0) <= 1024,
              case .object(let schema) = tool.inputSchema,
              schema["type"] == nil || schema["type"] == .string("object"),
              let data = try? JSONEncoder().encode(tool.inputSchema), data.count <= 65_536 else { return false }
        return true
    }

    func validate(_ page: QuartzWebMCPPage, tool: QuartzWebMCPTool, in webView: WKWebView) async throws {
        guard page.generation == generation, page.url == webView.url,
              let current = try await discover(in: webView), current.documentID == page.documentID,
              current.tools.contains(tool) else { throw QuartzWebMCPError.pageChanged }
    }

    func execute(_ tool: QuartzWebMCPTool, input: FacetJSONValue, page: QuartzWebMCPPage, in webView: WKWebView) async throws -> FacetJSONValue {
        try await validate(page, tool: tool, in: webView)
        guard case .object = input else { throw QuartzWebMCPError.invalidTools }
        let inputData = try JSONEncoder().encode(input)
        guard inputData.count <= 65_536 else { throw QuartzWebMCPError.invalidTools }
        let data: Data
        do {
            data = try await evaluate(
                QuartzWebMCPScript.executeScript,
                arguments: ["toolID": tool.id, "input": try JSONSerialization.jsonObject(with: inputData), "documentID": page.documentID],
                in: webView, timeout: 35
            )
        } catch {
            cancel(in: webView, documentID: page.documentID)
            throw error
        }
        guard generation == page.generation, webView.url == page.url, !webView.isLoading else {
            throw QuartzWebMCPError.pageChanged
        }
        guard let result = try? JSONDecoder().decode(String.self, from: data),
              result.utf8.count <= 262_144,
              let value = try? JSONDecoder().decode(FacetJSONValue.self, from: Data(result.utf8)) else {
            throw QuartzWebMCPError.invalidTools
        }
        return value
    }

    func cancel(in webView: WKWebView, documentID: String) {
        webView.callAsyncJavaScript(
            QuartzWebMCPScript.cancelScript, arguments: ["documentID": documentID],
            in: nil, in: .page, completionHandler: nil
        )
    }

    private func evaluate(_ script: String, arguments: [String: Any] = [:], in webView: WKWebView, timeout: Double = 5) async throws -> Data {
        let operation = Evaluation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.continuation = continuation
                operation.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    operation.finish(.failure(QuartzWebMCPError.timedOut))
                }
                webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                    operation.finish(result.flatMap { value in
                        Result { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) }
                    })
                }
            }
        } onCancel: {
            Task { @MainActor in operation.finish(.failure(CancellationError())) }
        }
    }

    @MainActor
    private final class Evaluation {
        var continuation: CheckedContinuation<Data, Error>?
        var timeout: Task<Void, Never>?

        func finish(_ result: Result<Data, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            continuation.resume(with: result)
        }
    }
}
