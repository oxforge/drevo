import Foundation

/// Stable identifier of a user-invokable command; also the key used in keybindings.json.
public struct CommandID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { rawValue = raw }
    public var description: String { rawValue }
}

public enum CommandCategory: String, CaseIterable, Sendable {
    case navigation = "Navigation"
    case go = "Go"
    case panes = "Panes"
    case file = "File"
    case edit = "Edit"
    case view = "View"
    case shell = "Shell"
    case window = "Window"
}

public struct CommandSpec: Sendable {
    public let id: CommandID
    public let title: String
    public let category: CommandCategory
    public let defaultKeys: [KeyCombo]
    /// Implemented through a standard AppKit selector (copy:, paste:, undo:…) so text fields
    /// keep working; menus own these keys.
    public let isStandardEdit: Bool
    /// One-line help shown in the command palette.
    public let help: String

    public init(_ id: CommandID, _ title: String, _ category: CommandCategory, keys: [String] = [],
                standardEdit: Bool = false, help: String = "") {
        self.id = id
        self.title = title
        self.category = category
        // Defaults are compile-time literals; a typo is a programming error caught by tests.
        self.defaultKeys = keys.map { try! KeyCombo(parsing: $0) }
        self.isStandardEdit = standardEdit
        self.help = help
    }
}

public extension CommandID {
    // Navigation
    static let open = CommandID("nav.open")
    static let enclosingFolder = CommandID("nav.enclosing")
    static let levelUp = CommandID("nav.levelUp")
    static let levelDown = CommandID("nav.levelDown")
    static let back = CommandID("nav.back")
    static let forward = CommandID("nav.forward")
    static let goToPath = CommandID("nav.goToPath")
    static let filter = CommandID("nav.filter")
    static let search = CommandID("nav.search")
    // Go
    static let goHome = CommandID("go.home")
    static let goDesktop = CommandID("go.desktop")
    static let goDocuments = CommandID("go.documents")
    static let goDownloads = CommandID("go.downloads")
    static let goApplications = CommandID("go.applications")
    static let goUtilities = CommandID("go.utilities")
    static let goVolumes = CommandID("go.volumes")
    // Panes
    static let nextPane = CommandID("pane.next")
    static let previousPane = CommandID("pane.previous")
    static let swapPanes = CommandID("pane.swap")
    static let openInOtherPane = CommandID("pane.openInOther")
    static let addPane = CommandID("pane.add")
    static let removePane = CommandID("pane.remove")
    static let equalizePanes = CommandID("pane.equalize")
    // File
    static let rename = CommandID("file.rename")
    static let quickLook = CommandID("file.quickLook")
    static let edit = CommandID("file.edit")
    static let copyToOtherPane = CommandID("file.copyToOther")
    static let moveToOtherPane = CommandID("file.moveToOther")
    static let newFolder = CommandID("file.newFolder")
    static let newFile = CommandID("file.newFile")
    static let moveToTrash = CommandID("file.trash")
    static let deleteImmediately = CommandID("file.deleteImmediately")
    static let duplicate = CommandID("file.duplicate")
    static let makeAlias = CommandID("file.makeAlias")
    static let copyPath = CommandID("file.copyPath")
    static let getInfo = CommandID("file.getInfo")
    static let showPackageContents = CommandID("file.showPackageContents")
    static let revealInFinder = CommandID("file.revealInFinder")
    static let addToSidebar = CommandID("file.addToSidebar")
    // Edit
    static let copy = CommandID("edit.copy")
    static let cut = CommandID("edit.cut")
    static let paste = CommandID("edit.paste")
    static let pasteMove = CommandID("edit.pasteMove")
    static let selectAll = CommandID("edit.selectAll")
    static let undo = CommandID("edit.undo")
    static let redo = CommandID("edit.redo")
    // View
    static let listView = CommandID("view.list")
    static let columnsView = CommandID("view.columns")
    static let toggleHidden = CommandID("view.toggleHidden")
    static let biggerRows = CommandID("view.biggerRows")
    static let smallerRows = CommandID("view.smallerRows")
    static let toggleSidebar = CommandID("view.toggleSidebar")
    static let toggleStatusBar = CommandID("view.toggleStatusBar")
    static let toggleKeyHints = CommandID("view.toggleKeyHints")
    static let toggleCommandLine = CommandID("view.toggleCommandLine")
    static let commandPalette = CommandID("view.commandPalette")
    static let sortByName = CommandID("view.sortByName")
    static let sortByKind = CommandID("view.sortByKind")
    static let sortByModified = CommandID("view.sortByModified")
    static let sortByCreated = CommandID("view.sortByCreated")
    static let sortBySize = CommandID("view.sortBySize")
    static let reverseSort = CommandID("view.reverseSort")
    // Shell
    static let openTerminal = CommandID("shell.openTerminal")
    static let runCommand = CommandID("shell.runCommand")
    static let toggleConsole = CommandID("shell.toggleConsole")
    static let stopCommand = CommandID("shell.stop")
    static let runInTerminal = CommandID("shell.runInTerminal")
    // Window
    static let newWindow = CommandID("window.new")
    static let newTab = CommandID("tab.new")
    static let closeTab = CommandID("tab.close")
    static let nextTab = CommandID("tab.next")
    static let previousTab = CommandID("tab.previous")
}

/// Every command with its default shortcuts. Order within a category is menu order.
public enum CommandRegistry {
    public static let all: [CommandSpec] = [
        // Navigation — Finder keys plus ←/→ meaning the same in both views.
        CommandSpec(.open, "Open", .navigation, keys: ["return", "cmd+down"], help: "Enter the folder or open the file"),
        CommandSpec(.enclosingFolder, "Enclosing Folder", .navigation, keys: ["cmd+up"]),
        CommandSpec(.levelUp, "Up a Level", .navigation, keys: ["left"], help: "Column view: previous column; List view: enclosing folder"),
        CommandSpec(.levelDown, "Into Folder", .navigation, keys: ["right"]),
        CommandSpec(.back, "Back", .navigation, keys: ["cmd+["]),
        CommandSpec(.forward, "Forward", .navigation, keys: ["cmd+]"]),
        CommandSpec(.goToPath, "Go to Folder…", .navigation, keys: ["cmd+l", "shift+cmd+g"], help: "Type a path; Tab completes"),
        CommandSpec(.filter, "Filter…", .navigation, keys: ["cmd+f"], help: "Show only matching names (or just start typing; * and ? are wildcards)"),
        CommandSpec(.search, "Search…", .navigation, keys: ["opt+cmd+f"], help: "Find files by name in this folder and all folders inside it"),
        // Go — exactly Finder's.
        CommandSpec(.goHome, "Home", .go, keys: ["shift+cmd+h"]),
        CommandSpec(.goDesktop, "Desktop", .go, keys: ["shift+cmd+d"]),
        CommandSpec(.goDocuments, "Documents", .go, keys: ["shift+cmd+o"]),
        CommandSpec(.goDownloads, "Downloads", .go, keys: ["opt+cmd+l"]),
        CommandSpec(.goApplications, "Applications", .go, keys: ["shift+cmd+a"]),
        CommandSpec(.goUtilities, "Utilities", .go, keys: ["shift+cmd+u"]),
        CommandSpec(.goVolumes, "Volumes", .go),
        // Panes — commander tradition.
        CommandSpec(.nextPane, "Switch to Next Pane", .panes, keys: ["tab"]),
        CommandSpec(.previousPane, "Switch to Previous Pane", .panes, keys: ["shift+tab"]),
        CommandSpec(.swapPanes, "Swap Panes", .panes, keys: ["cmd+u"]),
        CommandSpec(.openInOtherPane, "Open in Other Pane", .panes, keys: ["opt+cmd+o"], help: "Show the selected folder (or this folder) in the other pane"),
        CommandSpec(.addPane, "Add Pane", .panes),
        CommandSpec(.removePane, "Close Pane", .panes),
        CommandSpec(.equalizePanes, "Make Panes Equal Width", .panes, help: "Or double-click the divider between two panes"),
        // File
        CommandSpec(.rename, "Rename", .file, keys: ["f2", "cmd+r"]),
        CommandSpec(.quickLook, "Quick Look", .file, keys: ["space", "f3", "cmd+y"]),
        CommandSpec(.edit, "Edit in Editor", .file, keys: ["f4"]),
        CommandSpec(.copyToOtherPane, "Copy to Other Pane", .file, keys: ["f5", "shift+cmd+c"]),
        CommandSpec(.moveToOtherPane, "Move to Other Pane", .file, keys: ["f6", "shift+cmd+m"]),
        CommandSpec(.newFolder, "New Folder", .file, keys: ["f7", "shift+cmd+n"]),
        CommandSpec(.newFile, "New File", .file, keys: ["opt+cmd+n"], help: "Create an empty file and rename it"),
        CommandSpec(.moveToTrash, "Move to Trash", .file, keys: ["f8", "cmd+backspace"]),
        CommandSpec(.deleteImmediately, "Delete Immediately…", .file, keys: ["opt+cmd+backspace"]),
        CommandSpec(.duplicate, "Duplicate", .file, keys: ["cmd+d"]),
        CommandSpec(.makeAlias, "Make Alias", .file, keys: ["ctrl+cmd+a"]),
        CommandSpec(.copyPath, "Copy Path", .file, keys: ["opt+cmd+c"]),
        CommandSpec(.getInfo, "Get Info", .file, keys: ["cmd+i"]),
        CommandSpec(.showPackageContents, "Show Package Contents", .file),
        CommandSpec(.revealInFinder, "Reveal in Finder", .file),
        CommandSpec(.addToSidebar, "Add to Sidebar", .file, keys: ["ctrl+cmd+t"]),
        // Edit — standard selectors.
        CommandSpec(.undo, "Undo", .edit, keys: ["cmd+z"], standardEdit: true),
        CommandSpec(.redo, "Redo", .edit, keys: ["shift+cmd+z"], standardEdit: true),
        CommandSpec(.cut, "Cut", .edit, keys: ["cmd+x"], standardEdit: true, help: "Paste then moves the items"),
        CommandSpec(.copy, "Copy", .edit, keys: ["cmd+c"], standardEdit: true),
        CommandSpec(.paste, "Paste", .edit, keys: ["cmd+v"], standardEdit: true),
        CommandSpec(.pasteMove, "Move Items Here", .edit, keys: ["opt+cmd+v"]),
        CommandSpec(.selectAll, "Select All", .edit, keys: ["cmd+a"], standardEdit: true),
        // View
        CommandSpec(.listView, "as List", .view, keys: ["cmd+2"]),
        CommandSpec(.columnsView, "as Columns", .view, keys: ["cmd+3"]),
        CommandSpec(.toggleHidden, "Show Hidden Files", .view, keys: ["shift+cmd+."]),
        CommandSpec(.biggerRows, "Bigger Rows", .view, keys: ["cmd+="]),
        CommandSpec(.smallerRows, "Smaller Rows", .view, keys: ["cmd+-"]),
        CommandSpec(.toggleSidebar, "Show Sidebar", .view, keys: ["ctrl+cmd+s"]),
        CommandSpec(.toggleStatusBar, "Show Status Bar", .view, keys: ["cmd+/"]),
        CommandSpec(.toggleKeyHints, "Show Key Hints", .view),
        CommandSpec(.toggleCommandLine, "Show Command Line", .view),
        CommandSpec(.commandPalette, "Command Palette…", .view, keys: ["shift+cmd+p"], help: "Search every command"),
        // Sort — Finder's ⌃⌥⌘ numbers; choosing the current one again reverses it.
        CommandSpec(.sortByName, "Sort by Name", .view, keys: ["ctrl+opt+cmd+1"]),
        CommandSpec(.sortByKind, "Sort by Kind", .view, keys: ["ctrl+opt+cmd+2"], help: "Group files by type"),
        CommandSpec(.sortByModified, "Sort by Date Modified", .view, keys: ["ctrl+opt+cmd+5"], help: "Newest first"),
        CommandSpec(.sortByCreated, "Sort by Date Created", .view, help: "Newest first"),
        CommandSpec(.sortBySize, "Sort by Size", .view, keys: ["ctrl+opt+cmd+6"], help: "Largest first"),
        CommandSpec(.reverseSort, "Reverse Sort Order", .view),
        // Shell
        CommandSpec(.openTerminal, "Open in Terminal", .shell, keys: ["opt+cmd+t"], help: "Open the terminal app in this folder"),
        CommandSpec(.runCommand, "Run Shell Command…", .shell, keys: ["!", "opt+cmd+r"], help: "Run a command in this folder with your shell"),
        CommandSpec(.toggleConsole, "Show Console", .shell, keys: ["opt+cmd+j"], help: "Output of commands run from the command line"),
        CommandSpec(.stopCommand, "Stop Running Command", .shell, keys: ["cmd+."], help: "Interrupt the command running in the console"),
        CommandSpec(.runInTerminal, "Run Command in Terminal", .shell, help: "From the command line: ⌘↩ runs it in your terminal app"),
        // Window
        CommandSpec(.newWindow, "New Window", .window, keys: ["cmd+n"]),
        // Tabs belong to a pane; they are window-category commands so they work while a
        // text field edits.
        CommandSpec(.newTab, "New Tab", .window, keys: ["cmd+t"], help: "Another tab in this pane, on the same folder"),
        CommandSpec(.closeTab, "Close Tab", .window, keys: ["cmd+w"], help: "Closes the window when the pane has one tab"),
        CommandSpec(.nextTab, "Show Next Tab", .window, keys: ["ctrl+tab"]),
        CommandSpec(.previousTab, "Show Previous Tab", .window, keys: ["ctrl+shift+tab"]),
    ]

    public static let byID: [CommandID: CommandSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func spec(_ id: CommandID) -> CommandSpec? { byID[id] }
}

/// macOS system-wide (and app-standard) shortcuts that Drevo must never bind by default.
public enum SystemShortcuts {
    public static let reserved: Set<KeyCombo> = {
        var s: [String] = [
            "cmd+space", "ctrl+space", "ctrl+opt+space", "opt+cmd+space", "ctrl+cmd+space",
            "cmd+tab", "shift+cmd+tab", "cmd+`", "shift+cmd+`",
            "shift+cmd+3", "shift+cmd+4", "shift+cmd+5", "shift+cmd+6",
            "ctrl+shift+cmd+3", "ctrl+shift+cmd+4",
            "ctrl+up", "ctrl+down", "ctrl+left", "ctrl+right",
            "f11", "cmd+f5", "opt+cmd+f5",
            "cmd+h", "opt+cmd+h", "cmd+m", "cmd+q", "shift+cmd+q", "opt+shift+cmd+q", "ctrl+cmd+q",
            "ctrl+cmd+d", "opt+cmd+d", "opt+cmd+escape", "ctrl+cmd+f", "shift+cmd+/",
            "opt+cmd+8", "opt+cmd+=", "opt+cmd+-", "ctrl+opt+cmd+8",
            "cmd+,", // ⌘W is Close Tab, which closes the window with the last tab
        ]
        s += (1...9).map { "ctrl+\($0)" }
        s += (1...8).map { "ctrl+f\($0)" }
        return Set(s.map { try! KeyCombo(parsing: $0) })
    }()
}
