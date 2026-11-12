# TODO

## Pending

| Feature slug | Feature description |
| --- | --- |
| path-bar-drop | **Today:** the breadcrumb path bar (`PathBarView` in `Sources/FmanUI/PaneChrome.swift`) only navigates on click; dropping files on a segment does nothing, although the design doc promised it. **Wanted:** dragging files onto a segment copies/moves them into that ancestor folder with the same Finder rules as table drops (`FileDragDrop.kind`), with a hover highlight on the segment. **Decided:** reuse `OperationsCenter.transfer`; no spring-loading. |
| tabs-per-pane | **Today:** each pane shows exactly one folder; there are no tabs (window tabbing is disabled in `MainWindowController`). **Wanted:** ⌘T opens a tab in the active pane at the same folder, ⌘W closes the tab (the window only when it's the last), ⌃⇥/⌃⇧⇥ switch tabs, tabs persist in `WindowState`. **Decided:** tabs belong to a pane (ForkLift style), not to the window; ⌃⇥ is free of system shortcuts. |
| recursive-search | **Today:** ⌘F only filters the current folder by name (`PaneViewController.setFilter`, decision D22). **Wanted:** a separate Search command that finds files below the current folder (Spotlight `NSMetadataQuery`, with a plain recursive name match as fallback) and lists results in the pane with their locations; results support every file command. **Decided:** keep ⌘F as the quick filter; search gets its own shortcut (⌥⌘F is free). |
| column-width-resize | **Today:** Miller columns are a fixed 230 pt (`ColumnBrowserViewController.columnWidth`). **Wanted:** drag a column's right edge to resize it, ⌥-drag resizes all, and the width is remembered. **Decided:** nothing yet. |
| sort-persistence | **Today:** the List view's sort (header clicks) lives only in memory; `WindowState` saves folder and view mode but not sort, so every launch sorts by name. **Wanted:** each pane's sort key/direction is saved and restored. **Decided:** store it in `WindowState.Pane`. |
| divider-equalize | **Today:** panes get equal widths only at window creation and when a pane is added or removed (`PaneGroupViewController.equalizeWidths`). **Wanted:** double-clicking a divider between panes (or a View menu command) makes all panes equal again. **Decided:** nothing yet. |
| stable-signing | **Today:** `make app` ad-hoc signs (`SIGN_ID ?= -`), so macOS may ask again for Desktop/Documents/Downloads access after every rebuild, because ad-hoc signatures change with each build. **Wanted:** a documented one-time setup that keeps privacy grants across rebuilds. **Decided:** the Makefile already accepts `SIGN_ID="Apple Development: …"`; README explains it and the Full Disk Access alternative. Remaining work: a helper to create a local self-signed code-signing identity. |
| console-colors-and-tty | **Today:** the console (`ConsoleViewController` in `Sources/FmanUI/ShellUI.swift`) strips ANSI colours and gives commands no TTY (stdin is /dev/null), so interactive tools must go through ⌘↩ (run in terminal app). **Wanted:** colour output rendered (SGR → attributes) and, optionally, a pseudo-terminal so simple interactive prompts work in the console. **Decided:** full-screen TUIs (vim, top) keep going to the terminal app; an embedded terminal emulator would be a separate decision. |
| global-hotkey | **Today:** there's no system-wide shortcut to bring fman to the front. **Wanted:** an optional, user-chosen global hotkey in Settings ▸ General that shows/focuses fman (and opens a window if none). **Decided:** off by default; must be checked against `SystemShortcuts.reserved`. |
| folder-sizes | **Today:** folders show "--" in the List view's Size column. **Wanted:** an optional "Calculate folder sizes" setting that fills them in the background (like Finder's view option), cancelled when leaving the folder. **Decided:** reuse `CopyEngine.measure` off the main thread. |

## Done

| Feature slug | Feature short description | Commit |
| --- | --- | --- |
