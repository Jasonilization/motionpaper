import AppKit
import MotionpaperKit
import UniformTypeIdentifiers

// MARK: - Sidebar sections

enum SidebarSection: String, CaseIterable {
    case home
    case library
    case favorites
    case playlists
    case gallery
    case displays
}

// MARK: - Sorting

enum SortOption: String, CaseIterable {
    case dateAddedDesc
    case dateAddedAsc
    case nameAsc
    case durationDesc
    case resolutionDesc

    var label: String {
        switch self {
        case .dateAddedDesc: "Newest First"
        case .dateAddedAsc: "Oldest First"
        case .nameAsc: "Name A–Z"
        case .durationDesc: "Longest Video"
        case .resolutionDesc: "Highest Resolution"
        }
    }
}

// MARK: - Filter titles (kept in one place so the toolbar popup and the grid agree)

enum FilterTitles {
    static let all = "All"
    static let best1080 = "1080p+"
    static let fourK = "4K"
    static let portrait = "Portrait"
    static let landscape = "Landscape"
}

// MARK: - Cross-controller notifications

extension Notification.Name {
    /// Posted when the library contents changed (import finished, etc.).
    static let libraryDidChange = Notification.Name("motionpaper.libraryDidChange")
    /// Posted when some UI element wants the main window to switch to the Library section.
    static let openLibrary = Notification.Name("motionpaper.openLibrary")
    /// Posted when some UI element wants the Settings window shown.
    static let openSettings = Notification.Name("motionpaper.openSettings")
}

// MARK: - Small UI helpers

enum MPUI {
    static func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 26, weight: .bold)
        return label
    }

    static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    static func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return label
    }

    /// A scroll view hosting an autolayout content view with no background.
    /// The content stretches to at least the visible width and scrolls vertically.
    static func scrollContainer(content: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content
        content.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor).isActive = true
        return scrollView
    }

    /// A rounded, bordered card container.
    static func cardBox() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.title = ""
        box.borderType = .lineBorder
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// Presents the video import panel, copies the chosen files into the
    /// library, and posts `.libraryDidChange` when done.
    static func presentVideoImportPanel(store: AppStore) {
        let panel = NSOpenPanel()
        panel.title = "Import Videos"
        panel.message = "Videos are copied into your Motionpaper library — the originals are never modified."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.movie, .video]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { @MainActor in
            await store.importer.importFiles(urls, into: store.library, mode: .copy)
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        }
    }

    /// A modal alert with a single-line text input. Returns the entered text,
    /// or nil when cancelled / left empty.
    static func presentTextAlert(title: String, message: String, placeholder initialText: String,
                                 confirmTitle: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initialText
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
