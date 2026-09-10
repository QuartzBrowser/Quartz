import AppKit
import WebKit

enum QuartzDownloadPolicy {
    static func shouldDownload(_ response: URLResponse, canShowMIMEType: Bool) -> Bool {
        if !canShowMIMEType { return true }
        guard let response = response as? HTTPURLResponse,
              let disposition = response.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        return disposition.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
    }
}

/// WebKit requires a destination that does not exist. Download beside the chosen
/// file, then commit only a completed transfer, including when replacing a file.
struct QuartzDownloadDestination {
    let selectedURL: URL
    let stagingDirectory: URL
    var transferURL: URL { stagingDirectory.appendingPathComponent("download") }

    init(selectedURL: URL) throws {
        guard selectedURL.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        self.selectedURL = selectedURL
        stagingDirectory = selectedURL.deletingLastPathComponent()
            .appendingPathComponent(".quartz-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
    }

    func commit() throws {
        if FileManager.default.fileExists(atPath: selectedURL.path) {
            _ = try FileManager.default.replaceItemAt(selectedURL, withItemAt: transferURL, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: transferURL, to: selectedURL)
        }
        discard()
    }

    func discard() { try? FileManager.default.removeItem(at: stagingDirectory) }
}

@MainActor
final class QuartzDownloadCoordinator: NSObject, WKDownloadDelegate {
    typealias DestinationPicker = (String, @escaping @MainActor (URL?) -> Void) -> Void
    private struct Transfer {
        let download: WKDownload
        var destination: QuartzDownloadDestination?
    }
    private let chooseDestination: DestinationPicker
    private let report: (Result<URL, Error>) -> Void
    private var transfers = [ObjectIdentifier: Transfer]()

    init(chooseDestination: @escaping DestinationPicker, report: @escaping (Result<URL, Error>) -> Void) {
        self.chooseDestination = chooseDestination
        self.report = report
    }

    convenience init(window: @escaping () -> NSWindow?) {
        self.init(chooseDestination: { filename, completion in
            let panel = NSSavePanel()
            panel.title = "Save Download"
            panel.nameFieldStringValue = URL(fileURLWithPath: filename).lastPathComponent
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            if let parent = window() {
                panel.beginSheetModal(for: parent) { response in
                    completion(response == .OK ? panel.url : nil)
                }
            } else {
                panel.begin { response in completion(response == .OK ? panel.url : nil) }
            }
        }, report: { result in
            let alert = NSAlert()
            switch result {
            case .success(let url):
                alert.messageText = "Download complete"
                alert.informativeText = "Saved \(url.lastPathComponent) in \(url.deletingLastPathComponent().path)."
                alert.addButton(withTitle: "Done")
                alert.addButton(withTitle: "Show in Finder")
            case .failure(let error):
                alert.alertStyle = .warning
                alert.messageText = "Quartz could not save the download."
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
            }
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertSecondButtonReturn, case .success(let url) = result {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if let parent = window(), parent.isVisible {
                alert.beginSheetModal(for: parent, completionHandler: handle)
            } else {
                handle(alert.runModal())
            }
        })
    }

    var activeDownloadCount: Int { transfers.count }

    func begin(_ download: WKDownload) {
        transfers[ObjectIdentifier(download)] = Transfer(download: download)
        download.delegate = self
    }

    func cancelAll(discardStagingImmediately: Bool = false) {
        let cancelled = transfers.values
        transfers.removeAll()
        for transfer in cancelled {
            // Application termination cannot wait for another delegate callback.
            // Only the private staging copy is discarded, never the chosen file.
            if discardStagingImmediately { transfer.destination?.discard() }
            // Do not remove a destination until WebKit has stopped writing it.
            transfer.download.cancel { _ in transfer.destination?.discard() }
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let identifier = ObjectIdentifier(download)
        chooseDestination(suggestedFilename) { [weak self] selectedURL in
            guard let self, self.transfers[identifier] != nil else {
                completionHandler(nil)
                return
            }
            guard let selectedURL else {
                self.transfers.removeValue(forKey: identifier)
                completionHandler(nil)
                return
            }
            do {
                let destination = try QuartzDownloadDestination(selectedURL: selectedURL)
                self.transfers[identifier]?.destination = destination
                completionHandler(destination.transferURL)
            } catch {
                self.transfers.removeValue(forKey: identifier)
                completionHandler(nil)
                self.report(.failure(error))
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let transfer = transfers.removeValue(forKey: ObjectIdentifier(download)),
              let destination = transfer.destination else { return }
        do {
            try destination.commit()
            report(.success(destination.selectedURL))
        } catch {
            destination.discard()
            report(.failure(error))
        }
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let transfer = transfers.removeValue(forKey: ObjectIdentifier(download)) else { return }
        transfer.destination?.discard()
        if (error as NSError).domain != NSURLErrorDomain || (error as NSError).code != NSURLErrorCancelled {
            report(.failure(error))
        }
    }
}
