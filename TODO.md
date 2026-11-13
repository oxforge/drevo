# TODO

## Pending

| Feature slug | Feature description |
| --- | --- |
| remove-inline-undo | **Today:** `FileOperations.undo` (Sources/DrevoCore/FileOperations.swift), the inline form of `Reversal`, is no longer called by the app: undo and redo run as `Reversal` jobs through `OperationsCenter`. Only tests use it, as a shortcut, in five files under Tests/DrevoCoreTests (`ops.undo(...)`). Found by the test-suite review of 2026-11-13 (finding M5). **Wanted:** those tests undo through `Reversal(...).run()` as the app does, and `FileOperations.undo` and whatever only it uses are removed. **Decided:** a separate change from the test-suite cleanup, because the tests have to move first. |
| async-folder-listing | **Today:** folders are read on the main thread (`DirectoryListing.load`, called from `FileListViewController.load` and `FolderColumn.load`) on every navigation and reload: about 110 ms per 10,000 entries in a release build, and a network share that stops answering blocks in `opendir`/`lstat` until the mount times out, which freezes the app. **Wanted:** listings load off the main thread; a slow or unreachable folder shows a loading state instead of freezing, and a result that arrives after the pane has moved on is dropped. **Decided:** a generation token per browser decides which result is current. Selection restore, in-place rename and the UI tests assume a synchronous reload today, so they need rework as part of this. Columns view already re-reads only the columns whose folder changed when the change comes from FSEvents (`MainWindowController.foldersChanged`); after an operation in the app (`OperationsCenter.postChange`) every pane re-reads everything it shows. Whether browsing unreliable network shares is a goal should be confirmed before starting. |

## Done

| Feature slug | Feature short description | Commit |
| --- | --- | --- |
| sort-persistence | Each pane's sort key and direction are saved with the window and restored at launch. | 652d1f4 |
| path-bar-drop | Files dropped on a folder of the breadcrumb path bar are copied or moved into it, with a hover highlight. | 5577bca |
| tabs-per-pane | Tabs inside a pane: ⌘T, ⌘W, ⌃⇥ / ⌃⇧⇥, saved with the window. | 8754200 |
| recursive-search | ⌥⌘F finds files by name below the current folder (Spotlight plus a walk of the tree) and lists them with their locations. | e1a2bca |
| column-width-resize | Drag a column's edge in Columns view to resize it; ⌥-drag resizes all and the width is remembered. | fba2197 |
| divider-equalize | Double-clicking the divider between panes, or Panes ▸ Make Panes Equal Width, makes all panes equal again. | f4562bd |
| stable-signing | `make signing-identity` creates a local self-signed identity that `make app` signs with, so privacy grants survive rebuilds. | 7c710ec |
| global-hotkey | Optional user-chosen global shortcut in Settings ▸ General that brings Drevo to the front. | c828b0d |
| console-colors | The console renders SGR colours and text styles in command output (no pseudo-terminal). | d8c5691 |
| background-file-ops | Duplicate, Delete Immediately, undo and redo run as background jobs with progress and Stop. | cc11c18 |
| shortcut-editor | Settings ▸ Keys edits every command's shortcuts (saved to keybindings.json); extra ⌘/⌃/F-keys work like a command's menu key. | ab1c2f7 |
| ci-tests-fail-on-runner | `make test` passes on the CI runner: the pipeline-interrupt test's timer has its own queue, and a shell command counts as running until the console shows its end. | 0a60b08 |
