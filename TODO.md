# TODO

## Pending

| Feature slug | Feature description |
| --- | --- |
| ci-tests-fail-on-runner | **Today:** the first CI run on GitHub (commit c9080a5, run 43411912030 of `.github/workflows/ci.yml`) failed in the `make test` step on the `xcode-27` runner (macOS 27.0.1, Xcode 27.1) with exit code 2, so the build step was skipped and the README's CI badge reads "failing". The same 430 tests pass locally (macOS 26.6, Command Line Tools 27.0). The Release workflow runs `make test` too, so a tag (v0.2.0) likely publishes no release until this is fixed. The log showed two failing tests, both with causes found and fixed locally (all tests pass on this Mac); whether CI is green is not yet known. (1) `ShellTests.interruptStopsWholePipeline` took 5.86 s against a 5 s limit: its Ctrl-C timer ran on `DispatchQueue.global()`, which runs nothing while CPU-bound work fills its threads (one per CPU), so on the 3-core runner the Ctrl-C came ~5.5 s late; the timer now has a queue of its own, like `ShellCommand`'s. (2) `ShellSetupUITests.firstCommandLoadsTheSetupLaterOnesReuseIt` read the transcript before the command's output arrived: `ShellSession.isRunning` went false as soon as the process ended on its own thread, before the console caught up on the main run loop. That was also an app bug (a next command could start in between, and the first one's late cleanup cleared the new command); `isRunning` now holds until `running` is cleared, with `ShellUITests.runsUntilTheConsoleShowsTheEnd` as the regression test. The many `sandbox_extension_consume failed` lines in the CI log don't appear locally and fail nothing; not investigated. **Wanted:** `make test` passes on the runner, CI is green, and pushing a version tag publishes a release with the DMG. **Decided:** nothing yet. |
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
