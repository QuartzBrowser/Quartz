import AppKit

/// Extension popovers have their own key panel while their browser remains the
/// main window. Report that browser as focused until focus actually leaves it.
@MainActor
enum QuartzBrowserFocus {
    static func window(
        applicationIsActive: Bool,
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        browserWindows: [NSWindow],
        popupWindow: NSWindow?,
        popupOwner: NSWindow?
    ) -> NSWindow? {
        guard applicationIsActive else { return nil }
        if let keyWindow {
            if browserWindows.contains(where: { $0 === keyWindow }) { return keyWindow }
            if keyWindow === popupWindow,
               let popupOwner,
               browserWindows.contains(where: { $0 === popupOwner }),
               mainWindow === popupOwner {
                return popupOwner
            }
            // A manager or another unrelated window is not browser focus, even
            // if AppKit still reports the previous browser as the main window.
            return nil
        }
        // Key-window transfers briefly clear the key window before assigning its
        // replacement. The main browser remains authoritative during this gap.
        return browserWindows.first { $0 === mainWindow }
    }
}

@MainActor
struct QuartzBrowserFocusChange {
    private var hasReported = false
    private var reportedWindow: ObjectIdentifier?

    mutating func update(window: NSWindow?) -> Bool {
        let identifier = window.map(ObjectIdentifier.init)
        guard !hasReported || identifier != reportedWindow else { return false }
        hasReported = true
        reportedWindow = identifier
        return true
    }
}
