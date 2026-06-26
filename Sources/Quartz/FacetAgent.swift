import AppKit
import Foundation

struct FacetPageContext: Sendable {
    let url: String
    let title: String
    let selectedText: String
    let description: String
    let textExcerpt: String

    var hasUsefulContent: Bool {
        [url, title, selectedText, description, textExcerpt].contains { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}

struct FacetCodexResult: Sendable {
    let output: String
    let exitStatus: Int32
    let wasCancelled: Bool

    var didSucceed: Bool {
        exitStatus == 0 && wasCancelled == false
    }
}

struct FacetCodexModelOption: Sendable, Equatable {
    let slug: String
    let displayName: String

    var menuTitle: String {
        displayName == slug ? slug : "\(displayName) (\(slug))"
    }

    static let fallbackOptions = [
        FacetCodexModelOption(slug: "gpt-5.5", displayName: "GPT-5.5"),
        FacetCodexModelOption(slug: "gpt-5.4", displayName: "GPT-5.4"),
        FacetCodexModelOption(slug: "gpt-5.4-mini", displayName: "GPT-5.4-Mini"),
        FacetCodexModelOption(slug: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
        FacetCodexModelOption(slug: "gpt-5.2", displayName: "GPT-5.2")
    ]
}

struct FacetCodexConfiguration: Sendable, Equatable {
    let model: String?
    let reasoningEffort: String?

    var modelArgument: String? {
        clean(model)
    }

    var reasoningEffortArgument: String? {
        clean(reasoningEffort)
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
protocol FacetPanelViewDelegate: AnyObject {
    func facetPanel(_ panel: FacetPanelView, didSubmit prompt: String, includePageContext: Bool, configuration: FacetCodexConfiguration)
    func facetPanelDidRequestCancel(_ panel: FacetPanelView)
    func facetPanelDidRequestClose(_ panel: FacetPanelView)
}

@MainActor
final class FacetPanelView: NSView {
    weak var delegate: FacetPanelViewDelegate?

    private let titleLabel = NSTextField(labelWithString: "Facet")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let transcriptTextView = NSTextView()
    private let promptField = NSTextField()
    private let includePageCheckbox = NSButton(checkboxWithTitle: "Current page", target: nil, action: nil)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reasoningPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sendButton = FacetPanelView.makeCommandButton(
        title: "Send",
        symbolName: "paperplane.fill",
        description: "Send to Facet"
    )
    private let stopButton = FacetPanelView.makeCommandButton(
        title: "Stop",
        symbolName: "stop.fill",
        description: "Stop Facet"
    )
    private let closeButton = FacetPanelView.makeIconButton(symbolName: "xmark", description: "Hide Facet")

    private(set) var isRunning = false

    private enum PreferenceKeys {
        static let model = "Facet.codex.model"
        static let reasoningEffort = "Facet.codex.reasoningEffort"
    }

    private let reasoningOptions = [
        (title: "Default", value: ""),
        (title: "Low", value: "low"),
        (title: "Medium", value: "medium"),
        (title: "High", value: "high"),
        (title: "Extra High", value: "xhigh")
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    func focusPrompt() {
        window?.makeFirstResponder(promptField)
    }

    func appendUserMessage(_ body: String) {
        appendMessage(author: "You", body: body, color: .controlAccentColor)
    }

    func appendAgentMessage(_ body: String) {
        appendMessage(author: "Facet", body: body, color: .labelColor)
    }

    func appendSystemMessage(_ body: String) {
        appendMessage(author: "Facet", body: body, color: .secondaryLabelColor)
    }

    func setRunning(_ running: Bool) {
        isRunning = running
        statusLabel.stringValue = running ? "Thinking..." : "Ready"
        promptField.isEnabled = !running
        sendButton.isHidden = running
        stopButton.isHidden = !running
        includePageCheckbox.isEnabled = !running
        modelPopup.isEnabled = !running
        reasoningPopup.isEnabled = !running
    }

    func setModelOptions(_ options: [FacetCodexModelOption]) {
        let selectedModel = currentModelSlug() ?? UserDefaults.standard.string(forKey: PreferenceKeys.model)
        let uniqueOptions = Self.uniqueModelOptions(options)

        modelPopup.removeAllItems()
        addItem(to: modelPopup, title: "Default", value: "")

        if uniqueOptions.isEmpty == false {
            modelPopup.menu?.addItem(.separator())
        }

        for option in uniqueOptions {
            addItem(to: modelPopup, title: option.menuTitle, value: option.slug)
        }

        if let selectedModel,
           selectedModel.isEmpty == false,
           uniqueOptions.contains(where: { $0.slug == selectedModel }) == false {
            addItem(to: modelPopup, title: selectedModel, value: selectedModel)
        }

        selectItem(in: modelPopup, value: selectedModel ?? "")
    }

    private func buildView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right

        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))

        let titleRow = NSStackView(views: [titleLabel, statusLabel, closeButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        transcriptTextView.isEditable = false
        transcriptTextView.isSelectable = true
        transcriptTextView.drawsBackground = false
        transcriptTextView.textContainerInset = NSSize(width: 0, height: 8)
        transcriptTextView.font = .systemFont(ofSize: 13)
        transcriptTextView.string = ""

        let transcriptScrollView = NSScrollView()
        transcriptScrollView.borderType = .noBorder
        transcriptScrollView.hasVerticalScroller = true
        transcriptScrollView.drawsBackground = false
        transcriptScrollView.documentView = transcriptTextView
        transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false

        promptField.placeholderString = "Ask Facet..."
        promptField.target = self
        promptField.action = #selector(sendPressed(_:))
        promptField.font = .systemFont(ofSize: 13)
        promptField.translatesAutoresizingMaskIntoConstraints = false

        includePageCheckbox.state = .on
        includePageCheckbox.font = .systemFont(ofSize: 12)

        configurePopup(modelPopup, description: "Codex model")
        setModelOptions(FacetCodexModelOption.fallbackOptions)

        configurePopup(reasoningPopup, description: "Codex reasoning level")
        for option in reasoningOptions {
            addItem(to: reasoningPopup, title: option.title, value: option.value)
        }
        selectItem(
            in: reasoningPopup,
            value: UserDefaults.standard.string(forKey: PreferenceKeys.reasoningEffort) ?? ""
        )

        let modelLabel = FacetPanelView.makeSettingLabel("Model")
        let reasoningLabel = FacetPanelView.makeSettingLabel("Reasoning")
        let settingsGrid = NSGridView(views: [
            [modelLabel, modelPopup],
            [reasoningLabel, reasoningPopup]
        ])
        settingsGrid.column(at: 0).xPlacement = .trailing
        settingsGrid.column(at: 1).xPlacement = .fill
        settingsGrid.column(at: 1).width = 190
        settingsGrid.rowSpacing = 6
        settingsGrid.columnSpacing = 8
        settingsGrid.translatesAutoresizingMaskIntoConstraints = false

        sendButton.target = self
        sendButton.action = #selector(sendPressed(_:))
        stopButton.target = self
        stopButton.action = #selector(stopPressed(_:))
        stopButton.isHidden = true

        let actionRow = NSStackView(views: [includePageCheckbox, sendButton, stopButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [titleRow, transcriptScrollView, settingsGrid, promptField, actionRow])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(content)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            content.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),

            closeButton.widthAnchor.constraint(equalToConstant: 28),
            transcriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            promptField.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func appendMessage(author: String, body: String, color: NSColor) {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanBody.isEmpty == false else {
            return
        }

        let authorAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: color
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        let storage = transcriptTextView.textStorage
        storage?.append(NSAttributedString(string: "\(author)\n", attributes: authorAttributes))
        storage?.append(NSAttributedString(string: "\(cleanBody)\n\n", attributes: bodyAttributes))
        transcriptTextView.scrollToEndOfDocument(nil)
    }

    @objc private func sendPressed(_ sender: Any?) {
        submitPrompt()
    }

    @objc private func settingChanged(_ sender: Any?) {
        let configuration = currentConfiguration()
        UserDefaults.standard.set(configuration.modelArgument ?? "", forKey: PreferenceKeys.model)
        UserDefaults.standard.set(configuration.reasoningEffortArgument ?? "", forKey: PreferenceKeys.reasoningEffort)
    }

    @objc private func stopPressed(_ sender: Any?) {
        delegate?.facetPanelDidRequestCancel(self)
    }

    @objc private func closePressed(_ sender: Any?) {
        delegate?.facetPanelDidRequestClose(self)
    }

    private func submitPrompt() {
        guard isRunning == false else {
            return
        }

        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.isEmpty == false else {
            return
        }

        promptField.stringValue = ""
        settingChanged(nil)
        delegate?.facetPanel(
            self,
            didSubmit: prompt,
            includePageContext: includePageCheckbox.state == .on,
            configuration: currentConfiguration()
        )
    }

    private func configurePopup(_ popup: NSPopUpButton, description: String) {
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        popup.target = self
        popup.action = #selector(settingChanged(_:))
        popup.toolTip = description
    }

    private func currentConfiguration() -> FacetCodexConfiguration {
        FacetCodexConfiguration(
            model: currentModelSlug(),
            reasoningEffort: selectedValue(in: reasoningPopup)
        )
    }

    private func currentModelSlug() -> String? {
        selectedValue(in: modelPopup)
    }

    private func selectedValue(in popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }

    private func addItem(to popup: NSPopUpButton, title: String, value: String) {
        popup.addItem(withTitle: title)
        popup.lastItem?.representedObject = value
    }

    private func selectItem(in popup: NSPopUpButton, value: String) {
        guard let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) else {
            popup.selectItem(at: 0)
            return
        }

        popup.select(item)
    }

    private static func makeIconButton(symbolName: String, description: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.controlSize = .regular
        button.imagePosition = .imageOnly
        button.toolTip = description
        return button
    }

    private static func makeCommandButton(title: String, symbolName: String, description: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        button.imagePosition = .imageLeading
        button.toolTip = description
        return button
    }

    private static func makeSettingLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private static func uniqueModelOptions(_ options: [FacetCodexModelOption]) -> [FacetCodexModelOption] {
        var seen = Set<String>()
        return options.filter { option in
            guard seen.contains(option.slug) == false else {
                return false
            }

            seen.insert(option.slug)
            return true
        }
    }
}

final class FacetCodexRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FacetCodexRunner", qos: .userInitiated)
    private let lock = NSLock()
    private var activeProcess: Process?

    func run(prompt: String, configuration: FacetCodexConfiguration) async -> FacetCodexResult {
        await withCheckedContinuation { continuation in
            queue.async { [self, prompt, configuration, continuation] in
                let result = runSynchronously(prompt: prompt, configuration: configuration)
                continuation.resume(returning: result)
            }
        }
    }

    func loadModelOptions() async -> [FacetCodexModelOption] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.loadModelOptionsSynchronously())
            }
        }
    }

    func cancel() {
        lock.lock()
        let process = activeProcess
        lock.unlock()

        process?.terminate()
    }

    private func runSynchronously(prompt: String, configuration: FacetCodexConfiguration) -> FacetCodexResult {
        guard let executableURL = Self.codexExecutableURL() else {
            return FacetCodexResult(
                output: "Facet could not find the Codex CLI. Install Codex or make sure the `codex` command is available at ~/.local/bin/codex, /opt/homebrew/bin/codex, /usr/local/bin/codex, or on PATH.",
                exitStatus: 127,
                wasCancelled: false
            )
        }

        let process = Process()
        process.executableURL = executableURL
        let lastMessageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("facet-codex-\(UUID().uuidString).txt", isDirectory: false)
        var arguments = [
            "--ask-for-approval",
            "never"
        ]
        if let model = configuration.modelArgument {
            arguments.append(contentsOf: ["--model", model])
        }
        if let reasoningEffort = configuration.reasoningEffortArgument {
            arguments.append(contentsOf: ["--config", "model_reasoning_effort=\"\(reasoningEffort)\""])
        }
        arguments.append(contentsOf: [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--color",
            "never",
            "--output-last-message",
            lastMessageURL.path,
            "-C",
            FileManager.default.homeDirectoryForCurrentUser.path,
            "-"
        ])
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = environment["TERM"] ?? "dumb"
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        lock.lock()
        activeProcess = process
        lock.unlock()

        do {
            try process.run()
            if let inputData = prompt.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(inputData)
            }
            try? inputPipe.fileHandleForWriting.close()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            lock.lock()
            if activeProcess === process {
                activeProcess = nil
            }
            lock.unlock()

            let rawOutput = String(data: outputData, encoding: .utf8) ?? ""
            let lastMessage = (try? String(contentsOf: lastMessageURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: lastMessageURL)
            let output: String
            if let lastMessage, lastMessage.isEmpty == false {
                output = lastMessage
            } else {
                output = rawOutput
            }
            let wasCancelled = process.terminationStatus == 15
            return FacetCodexResult(
                output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                exitStatus: process.terminationStatus,
                wasCancelled: wasCancelled
            )
        } catch {
            try? FileManager.default.removeItem(at: lastMessageURL)
            lock.lock()
            if activeProcess === process {
                activeProcess = nil
            }
            lock.unlock()

            return FacetCodexResult(
                output: error.localizedDescription,
                exitStatus: 1,
                wasCancelled: false
            )
        }
    }

    private static func codexExecutableURL() -> URL? {
        let pathValues = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let fallbackPaths = [
            "~/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let expandedSearchPaths = (pathValues + fallbackPaths).map { path in
            (path as NSString).expandingTildeInPath
        }

        for directory in expandedSearchPaths {
            let candidate = (directory as NSString).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    private static func loadModelOptionsSynchronously() -> [FacetCodexModelOption] {
        guard let executableURL = codexExecutableURL() else {
            return FacetCodexModelOption.fallbackOptions
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["debug", "models", "--bundled"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return FacetCodexModelOption.fallbackOptions
            }

            let catalog = try JSONDecoder().decode(CodexModelCatalog.self, from: outputData)
            let options = catalog.models
                .filter { $0.visibility == "list" }
                .map {
                    FacetCodexModelOption(
                        slug: $0.slug,
                        displayName: $0.displayName?.isEmpty == false ? $0.displayName! : $0.slug
                    )
                }

            return options.isEmpty ? FacetCodexModelOption.fallbackOptions : options
        } catch {
            return FacetCodexModelOption.fallbackOptions
        }
    }

    private struct CodexModelCatalog: Decodable {
        let models: [CodexModelRecord]
    }

    private struct CodexModelRecord: Decodable {
        let slug: String
        let displayName: String?
        let visibility: String?

        private enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case visibility
        }
    }
}
