# TODO

## Pending

| Feature slug | Feature description |
| --- | --- |
| console-colors | **Today:** the console (`Sources/DrevoUI/ConsoleViewController.swift`) shows plain text. Escape sequences are stripped before the text reaches the console: a command's output in `OutputBacklog.append`, off the main thread, with one `ANSIStream` per stream so a sequence split between two chunks is still removed (`Sources/DrevoCore/OutputBacklog.swift`, `ANSI.swift`); the console's own messages in `ConsoleViewController.append(_:isError:)` with `ANSI.strip`. **Wanted:** colour output rendered (SGR → attributes). **Decided:** colours only. No pseudo-terminal: commands keep running without a TTY, so tools colour their output only when asked (`--color=always`), and interactive tools and full-screen TUIs keep going to the terminal app (⌘↩). |
| background-file-ops | **Today:** Duplicate (`PaneViewController.duplicateSelection` → `FileOperations.duplicate`), Delete Immediately (`FileOperations.deleteImmediately`) and undo/redo (`OperationsCenter.applyUndo` → `FileOperations.undo`) run synchronously on the main thread with no progress and no Stop. On a volume without clones (exFAT, SMB) duplicating a large file freezes the window for the whole copy; deleting a large tree, or undoing a move between volumes (`FileManager.moveItem` copies then deletes), freezes it the same way. **Wanted:** these run as background jobs in the operations bar with progress and Stop, like F5/F6 copies and moves, and the window stays responsive. **Decided:** Duplicate goes through `OperationsCenter.transfer` (copying into the same folder already produces "x copy" names); undo becomes asynchronous, so the order of undo registrations has to be kept. The quadratic folder re-read in `duplicate` was fixed separately and is not part of this item. |
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
