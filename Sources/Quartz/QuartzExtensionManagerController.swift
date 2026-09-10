import AppKit

@available(macOS 15.4, *)
@MainActor
final class QuartzExtensionManagerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var support: QuartzWebExtensionSupport?
    private var extensions: [QuartzInstalledWebExtension] = []
    private let table = NSTableView()
    private let toggleButton = NSButton(title: "Disable", target: nil, action: nil)
    private let removeButton = NSButton(title: "Uninstall…", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var isBusy = false

    init(support: QuartzWebExtensionSupport) {
        self.support = support
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Extensions"
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        configureContent()
    }

    required init?(coder: NSCoder) { nil }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.rowHeight = 36
        table.usesAlternatingRowBackgroundColors = true
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Extension"
        nameColumn.width = 355
        let stateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        stateColumn.title = "Status"
        stateColumn.width = 180
        table.addTableColumn(nameColumn)
        table.addTableColumn(stateColumn)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        toggleButton.target = self
        toggleButton.action = #selector(toggleSelected)
        toggleButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded
        let controls = NSStackView(views: [toggleButton, removeButton])
        controls.spacing = 8
        statusLabel.textColor = .secondaryLabelColor
        for view in [scroll, controls, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            controls.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    func reload() {
        let selectedID = selectedExtension?.identifier
        extensions = support?.installedExtensions ?? []
        table.reloadData()
        if let index = extensions.firstIndex(where: { $0.identifier == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateControls()
    }

    private var selectedExtension: QuartzInstalledWebExtension? {
        extensions.indices.contains(table.selectedRow) ? extensions[table.selectedRow] : nil
    }

    private func updateControls() {
        toggleButton.title = selectedExtension?.isEnabled == true ? "Disable" : "Enable"
        toggleButton.isEnabled = selectedExtension != nil && !isBusy
        removeButton.isEnabled = selectedExtension != nil && !isBusy
        if isBusy {
            statusLabel.stringValue = "Updating extension…"
        } else if extensions.isEmpty {
            statusLabel.stringValue = "No extensions are installed. Use the Extensions menu to install one."
        } else if let item = selectedExtension, item.status != "Enabled", item.status != "Disabled" {
            statusLabel.stringValue = item.status
        } else {
            statusLabel.stringValue = "Disabled extensions stay installed and can be enabled again."
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { extensions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard extensions.indices.contains(row) else { return nil }
        let item = extensions[row]
        let label = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "name" ? item.displayName : item.status)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = tableColumn?.identifier.rawValue == "name" ? item.identifier : item.status
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

    @objc private func toggleSelected() {
        guard let item = selectedExtension else { return }
        isBusy = true
        updateControls()
        support?.setEnabled(!item.isEnabled, identifier: item.identifier) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            self.reload()
            if case .failure(let error) = result { self.show(error) }
        }
    }

    @objc private func removeSelected() {
        guard let item = selectedExtension else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall \(item.displayName)?"
        alert.informativeText = "This removes the installed copy from Quartz. Your original extension file or folder will be kept."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try support?.uninstall(identifier: item.identifier)
            reload()
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Extension Could Not Be Updated"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
