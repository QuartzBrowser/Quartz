import Foundation
import UniformTypeIdentifiers
@preconcurrency import WebKit

final class QuartzSandboxedExtensionSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resourceRootURL: URL

    init(resourceRootURL: URL) {
        self.resourceRootURL = resourceRootURL.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = fileURL(for: requestURL)
        else {
            urlSchemeTask.didFailWithError(resourceError(for: urlSchemeTask.request.url))
            return
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false
        else {
            urlSchemeTask.didFailWithError(resourceError(for: requestURL))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let response = response(for: requestURL, fileURL: fileURL, contentLength: data.count)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fileURL(for requestURL: URL) -> URL? {
        let path = normalizedResourcePath(requestURL.path)
        guard path.isEmpty == false,
              path.split(separator: "/").contains("..") == false
        else {
            return nil
        }

        let fileURL = resourceRootURL
            .appendingPathComponent(path, isDirectory: false)
            .standardizedFileURL
        guard fileURL.path.hasPrefix(resourceRootURL.path + "/") else {
            return nil
        }

        return fileURL
    }

    private func normalizedResourcePath(_ path: String) -> String {
        var trimmedPath = path.removingPercentEncoding ?? path
        while trimmedPath.hasPrefix("/") {
            trimmedPath.removeFirst()
        }

        return trimmedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "html", "htm":
            return "text/html"
        case "js":
            return "application/javascript"
        case "css":
            return "text/css"
        case "json":
            return "application/json"
        case "wasm":
            return "application/wasm"
        case "data":
            return "application/octet-stream"
        case "ico":
            return "image/x-icon"
        default:
            return UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }

    private func response(for requestURL: URL, fileURL: URL, contentLength: Int) -> URLResponse {
        let mimeType = mimeType(for: fileURL)
        var contentType = mimeType
        if let encoding = textEncodingName(for: fileURL) {
            contentType += "; charset=\(encoding)"
        }

        return HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(contentLength),
                "Cache-Control": "no-store"
            ]
        ) ?? URLResponse(
            url: requestURL,
            mimeType: mimeType,
            expectedContentLength: contentLength,
            textEncodingName: textEncodingName(for: fileURL)
        )
    }

    private func textEncodingName(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "css", "html", "htm", "js", "json", "svg", "txt":
            return "utf-8"
        default:
            return nil
        }
    }

    private func resourceError(for url: URL?) -> NSError {
        NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorFileDoesNotExist,
            userInfo: [NSURLErrorFailingURLErrorKey: url as Any]
        )
    }
}
