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

@MainActor
protocol FacetPanelViewDelegate: AnyObject {
    func facetPanel(_ panel: FacetPanelView, didSubmit prompt: String, includePageContext: Bool, configuration: FacetConfiguration, apiKey: String)
    func facetPanelDidRequestCancel(_ panel: FacetPanelView)
    func facetPanelDidRequestClose(_ panel: FacetPanelView)
    func facetPanelDidRequestModelRefresh(_ panel: FacetPanelView)
    func facetPanelDidRequestClearHistory(_ panel: FacetPanelView)
    func facetPanelSettingsDidChange(_ panel: FacetPanelView)
}

@MainActor
final class FacetPanelView: NSView {
    weak var delegate: FacetPanelViewDelegate?

    private let titleLabel = NSTextField(labelWithString: "Facet")
    private let statusLabel = NSTextField(labelWithString: "OpenRouter")
    private let apiKeyField = NSSecureTextField()
    private let apiKeyStatusLabel = NSTextField(labelWithString: "Add your OpenRouter API key to get started.")
    private let saveKeyButton = NSButton(title: "Save", target: nil, action: nil)
    private let removeKeyButton = NSButton(title: "Remove", target: nil, action: nil)
    private let getKeyButton = NSButton(title: "Get API key", target: nil, action: nil)
    private let clearHistoryButton = NSButton(title: "Clear saved chats", target: nil, action: nil)
    private let refreshModelsButton = FacetPanelView.makeIconButton(symbolName: "arrow.clockwise", description: "Refresh OpenRouter models")
    private let apiKeyStore = FacetAPIKeyStore()
    private var modelOptions = [FacetModelOption]()
    private let transcriptTextView = NSTextView()
    private let promptField = NSTextField()
    private let includePageCheckbox = NSButton(checkboxWithTitle: "Current page", target: nil, action: nil)
    private let pageToolsCheckbox = NSButton(checkboxWithTitle: "Page tools (WebMCP)", target: nil, action: nil)
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
    private var pageToolsAvailable = false
    var usesPageTools: Bool { pageToolsAvailable && pageToolsCheckbox.state == .on }
    private var isLoadingModels = false

    private enum PreferenceKeys {
        static let model = "Facet.openrouter.model"
        static let reasoningEffort = "Facet.openrouter.reasoningEffort"
    }

    private let reasoningOptions = [
        (title: "Default", value: ""),
        (title: "None", value: "none"),
        (title: "Minimal", value: "minimal"),
        (title: "Low", value: "low"),
        (title: "Medium", value: "medium"),
        (title: "High", value: "high"),
        (title: "Extra High", value: "xhigh"),
        (title: "Maximum", value: "max")
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

    func clearTranscript() {
        transcriptTextView.string = ""
    }

    func setRunning(_ running: Bool) {
        isRunning = running
        updateStatus()
        promptField.isEnabled = !running
        sendButton.isHidden = running
        stopButton.isHidden = !running
        includePageCheckbox.isEnabled = !running
        pageToolsCheckbox.isEnabled = !running && pageToolsAvailable
        modelPopup.isEnabled = !running
        reasoningPopup.isEnabled = !running && !supportedReasoningEfforts.isEmpty
        apiKeyField.isEnabled = !running
        saveKeyButton.isEnabled = !running
        removeKeyButton.isEnabled = !running
        refreshModelsButton.isEnabled = !running && !isLoadingModels
    }

    func setModelsLoading(_ loading: Bool) {
        isLoadingModels = loading
        refreshModelsButton.isEnabled = !isRunning && !loading
        updateStatus()
    }

    func setPageToolsAvailable(_ available: Bool) {
        pageToolsAvailable = available
        if !available { pageToolsCheckbox.state = .off }
        pageToolsCheckbox.isEnabled = available && !isRunning
        pageToolsCheckbox.toolTip = available
            ? "Send this site's WebMCP tool descriptions and approved results to OpenRouter. Quartz asks before each tool runs."
            : "Enable WebMCP at quartz://flags/ and reload the website to use page tools."
        pageToolsCheckbox.setAccessibilityHelp(pageToolsCheckbox.toolTip)
    }

    private func updateStatus() {
        statusLabel.stringValue = isRunning ? "Thinking..." : (isLoadingModels ? "Loading models..." : "OpenRouter")
    }

    func prepareForDisplay() {
        updateAPIKeyStatus()
    }

    func setModelOptions(_ options: [FacetModelOption]) {
        let selectedModel = currentModelSlug() ?? UserDefaults.standard.string(forKey: PreferenceKeys.model) ?? "openrouter/auto"
        let availableOptions = Self.uniqueModelOptions(options + FacetModelOption.fallbackOptions)
        modelOptions = availableOptions.filter { $0.slug == "openrouter/auto" }
            + availableOptions.filter { $0.slug != "openrouter/auto" }
        modelPopup.removeAllItems()
        for option in modelOptions {
            addItem(to: modelPopup, title: option.menuTitle, value: option.slug)
        }
        if !modelOptions.contains(where: { $0.slug == selectedModel }) {
            addItem(to: modelPopup, title: selectedModel, value: selectedModel)
        }
        selectItem(in: modelPopup, value: selectedModel)
        updateReasoningOptions()
    }

    private var supportedReasoningEfforts: [String] {
        modelOptions.first(where: { $0.slug == currentModelSlug() })?.supportedReasoningEfforts ?? []
    }

    private func updateReasoningOptions() {
        let selectedEffort = selectedValue(in: reasoningPopup)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? UserDefaults.standard.string(forKey: PreferenceKeys.reasoningEffort) ?? ""
        reasoningPopup.removeAllItems()
        for option in reasoningOptions where option.value.isEmpty || supportedReasoningEfforts.contains(option.value) {
            addItem(to: reasoningPopup, title: option.title, value: option.value)
        }
        selectItem(in: reasoningPopup, value: selectedEffort)
        reasoningPopup.isEnabled = !isRunning && !supportedReasoningEfforts.isEmpty
        reasoningPopup.toolTip = supportedReasoningEfforts.isEmpty
            ? "This model uses its default reasoning settings."
            : "OpenRouter reasoning effort for the selected model"
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

        includePageCheckbox.toolTip = "Send this page's URL, title, selected text, and text excerpt to OpenRouter with your question."
        pageToolsCheckbox.state = .off
        pageToolsCheckbox.font = .systemFont(ofSize: 12)
        setPageToolsAvailable(false)
        configurePopup(modelPopup, description: "OpenRouter model")
        configurePopup(reasoningPopup, description: "OpenRouter reasoning effort")
        setModelOptions(FacetModelOption.fallbackOptions)
        modelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshModelsButton.target = self
        refreshModelsButton.action = #selector(refreshModelsPressed(_:))
        let modelRow = NSStackView(views: [modelPopup, refreshModelsButton])
        modelRow.spacing = 4
        modelRow.alignment = .centerY

        apiKeyField.placeholderString = "OpenRouter API key"
        apiKeyField.setAccessibilityLabel("OpenRouter API key")
        apiKeyField.font = .systemFont(ofSize: 12)
        apiKeyField.target = self
        apiKeyField.action = #selector(saveKeyPressed(_:))
        apiKeyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveKeyPressed(_:))
        saveKeyButton.toolTip = "Save API key in macOS Keychain"
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeKeyPressed(_:))
        getKeyButton.target = self
        getKeyButton.action = #selector(getKeyPressed(_:))
        for button in [saveKeyButton, removeKeyButton, getKeyButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let keyRow = NSStackView(views: [apiKeyField, saveKeyButton, removeKeyButton])
        keyRow.alignment = .centerY
        keyRow.spacing = 4
        apiKeyStatusLabel.font = .systemFont(ofSize: 11)
        apiKeyStatusLabel.textColor = .secondaryLabelColor
        apiKeyStatusLabel.lineBreakMode = .byTruncatingTail
        apiKeyStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keyStatusRow = NSStackView(views: [apiKeyStatusLabel, getKeyButton])
        keyStatusRow.alignment = .centerY
        keyStatusRow.spacing = 4

        let historyDisclosure = NSTextField(wrappingLabelWithString:
            "Completed chats are saved on this Mac. Facet sends recent chats to OpenRouter daily to personalize Curiosity Spark.")
        historyDisclosure.font = .systemFont(ofSize: 11)
        historyDisclosure.textColor = .secondaryLabelColor
        historyDisclosure.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearHistoryButton.target = self
        clearHistoryButton.action = #selector(clearHistoryPressed(_:))
        clearHistoryButton.bezelStyle = .rounded
        clearHistoryButton.controlSize = .small
        clearHistoryButton.toolTip = "Clear saved Facet chats and reset your personalized Curiosity Spark."
        let historyControls = NSStackView(views: [historyDisclosure, clearHistoryButton])
        historyControls.orientation = .vertical
        historyControls.alignment = .leading
        historyControls.spacing = 4

        let modelLabel = FacetPanelView.makeSettingLabel("Model")
        let reasoningLabel = FacetPanelView.makeSettingLabel("Reasoning")
        let settingsGrid = NSGridView(views: [
            [modelLabel, modelRow],
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

        let content = NSStackView(views: [titleRow, keyRow, keyStatusRow, transcriptScrollView, historyControls, settingsGrid, pageToolsCheckbox, promptField, actionRow])
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
            historyDisclosure.widthAnchor.constraint(equalTo: historyControls.widthAnchor),
            transcriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
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
        if let popup = sender as? NSPopUpButton, popup === modelPopup {
            updateReasoningOptions()
        }
        let configuration = currentConfiguration()
        UserDefaults.standard.set(configuration.modelID, forKey: PreferenceKeys.model)
        UserDefaults.standard.set(configuration.reasoningEffortValue ?? "", forKey: PreferenceKeys.reasoningEffort)
        delegate?.facetPanelSettingsDidChange(self)
    }

    @objc private func stopPressed(_ sender: Any?) {
        delegate?.facetPanelDidRequestCancel(self)
    }

    @objc private func closePressed(_ sender: Any?) {
        delegate?.facetPanelDidRequestClose(self)
    }

    @objc private func clearHistoryPressed(_ sender: Any?) {
        delegate?.facetPanelDidRequestClearHistory(self)
    }

    private func submitPrompt() {
        guard isRunning == false else {
            return
        }

        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.isEmpty == false else {
            return
        }

        let apiKey: String
        do {
            if !apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try saveEnteredAPIKey()
            }
            guard let savedKey = try resolvedAPIKey() else {
                appendSystemMessage("Add an OpenRouter API key above before sending a message.")
                window?.makeFirstResponder(apiKeyField)
                return
            }
            apiKey = savedKey
        } catch {
            appendSystemMessage(error.localizedDescription)
            return
        }

        promptField.stringValue = ""
        delegate?.facetPanel(
            self,
            didSubmit: prompt,
            includePageContext: includePageCheckbox.state == .on,
            configuration: currentConfiguration(),
            apiKey: apiKey
        )
    }

    @objc private func saveKeyPressed(_ sender: Any?) {
        do {
            try saveEnteredAPIKey()
        } catch {
            appendSystemMessage(error.localizedDescription)
        }
    }

    private func saveEnteredAPIKey() throws {
        try apiKeyStore.save(apiKeyField.stringValue)
        apiKeyField.stringValue = ""
        updateAPIKeyStatus()
        delegate?.facetPanelSettingsDidChange(self)
    }

    @objc private func removeKeyPressed(_ sender: Any?) {
        do {
            try apiKeyStore.delete()
            apiKeyField.stringValue = ""
            updateAPIKeyStatus()
            delegate?.facetPanelSettingsDidChange(self)
        } catch {
            appendSystemMessage(error.localizedDescription)
        }
    }

    @objc private func getKeyPressed(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://openrouter.ai/settings/keys")!)
    }

    @objc private func refreshModelsPressed(_ sender: Any?) {
        delegate?.facetPanelDidRequestModelRefresh(self)
    }

    private var environmentAPIKey: String? {
        let value = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    func resolvedAPIKey() throws -> String? {
        try apiKeyStore.load() ?? environmentAPIKey
    }

    private func updateAPIKeyStatus() {
        do {
            if try apiKeyStore.load() != nil {
                apiKeyStatusLabel.stringValue = "API key saved in Keychain"
                apiKeyField.placeholderString = "Replace OpenRouter API key"
            } else if environmentAPIKey != nil {
                apiKeyStatusLabel.stringValue = "Using OPENROUTER_API_KEY"
                apiKeyField.placeholderString = "OpenRouter API key"
            } else {
                apiKeyStatusLabel.stringValue = "Add an OpenRouter API key"
                apiKeyField.placeholderString = "OpenRouter API key"
            }
        } catch {
            apiKeyStatusLabel.stringValue = error.localizedDescription
        }
        apiKeyStatusLabel.toolTip = apiKeyStatusLabel.stringValue
    }

    private func configurePopup(_ popup: NSPopUpButton, description: String) {
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        popup.target = self
        popup.action = #selector(settingChanged(_:))
        popup.toolTip = description
    }

    static func savedConfiguration(defaults: UserDefaults = .standard) -> FacetConfiguration {
        FacetConfiguration(
            model: defaults.string(forKey: PreferenceKeys.model),
            reasoningEffort: defaults.string(forKey: PreferenceKeys.reasoningEffort)
        )
    }

    func currentConfiguration() -> FacetConfiguration {
        FacetConfiguration(
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

    private static func uniqueModelOptions(_ options: [FacetModelOption]) -> [FacetModelOption] {
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
