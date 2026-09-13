import AppKit

enum QuartzExtensionPermissionDescription {
    static func permission(_ name: String) -> String {
        switch name {
        case "activeTab": "Read and change the current page when you use the extension"
        case "tabs": "See the titles and addresses of your open tabs"
        case "storage", "unlimitedStorage": "Store extension settings and data on this Mac"
        case "scripting": "Run scripts to read and change pages you allow it to access"
        case "cookies": "Read and change cookies, including sign-in data, on allowed websites"
        case "webRequest", "webRequestBlocking": "Observe or modify network requests on allowed websites"
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess": "Block or redirect network requests"
        case "declarativeNetRequestFeedback": "See which network requests its filtering rules match"
        case "downloads": "Start and manage downloads"
        case "history": "Read and change your browsing history"
        case "bookmarks": "Read and change your bookmarks"
        case "clipboardRead": "Read text and other content from your clipboard"
        case "clipboardWrite": "Change your clipboard contents"
        case "notifications": "Show notifications"
        case "nativeMessaging": "Exchange messages with supporting apps on this Mac"
        case "geolocation": "Request your location"
        case "webNavigation": "Observe when you navigate between pages"
        case "alarms": "Schedule extension tasks"
        case "contextMenus", "menus": "Add commands to contextual menus"
        default: "Use the browser capability “\(name)”"
        }
    }

    static func website(_ pattern: String) -> String {
        if ["<all_urls>", "*://*/*", "https://*/*", "http://*/*"].contains(pattern) {
            return "Read and change data on \(pattern == "https://*/*" ? "all HTTPS websites" : pattern == "http://*/*" ? "all HTTP websites" : "all websites")"
        }
        if pattern.hasPrefix("file:") { return "Read and change data on local files you open" }
        guard let schemeEnd = pattern.range(of: "://") else { return "Read and change website data matching \(pattern)" }
        let host = pattern[schemeEnd.upperBound...].split(separator: "/", maxSplits: 1).first.map(String.init) ?? pattern
        if host.hasPrefix("*.") { return "Read and change data on \(host.dropFirst(2)) and its subdomains" }
        return "Read and change data on \(host)"
    }
}

@MainActor
enum QuartzExtensionPermissionPrompt {
    static func request(extensionName: String, permissions: Set<String>, matchPatterns: Set<String>, installing: Bool) -> Bool {
        guard !permissions.isEmpty || !matchPatterns.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = installing ? "Allow access for \(extensionName)?" : "\(extensionName) requests more access"
        alert.informativeText = "Only allow this access if you trust the extension. It will be able to:"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        // Return/Escape must not accidentally approve a permission request.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let descriptions = permissions.sorted().map(QuartzExtensionPermissionDescription.permission)
            + matchPatterns.sorted().map(QuartzExtensionPermissionDescription.website)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 0))
        QuartzWebKitRuntime.configureWritingTools(for: textView)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.string = descriptions.map { "• \($0)" }.joined(separator: "\n\n")
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 460, height: 80)
        textView.maxSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            textView.setFrameSize(NSSize(width: 460, height: max(80, layout.usedRect(for: container).height + 16)))
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: CGFloat(min(300, max(80, descriptions.count * 48)))))
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        alert.accessoryView = scroll
        return alert.runModal() == .alertFirstButtonReturn
    }
}
