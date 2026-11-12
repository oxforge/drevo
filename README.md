# fman

A native dual-pane file manager for macOS, built to replace Finder for everyday use.
Miller columns like Finder's Column view, two (up to four) panes like Midnight Commander,
Finder's shortcuts plus the commander keys (Tab, F5 copy, F6 move, …), a built-in command
line that runs in the current folder, and a Settings window for the rest.

- **Two panes, two views.** Each pane shows Columns (Miller columns with a file preview)
  or List (sortable Name/Date/Size/Kind). ⌘3 / ⌘2 switch the active pane.
- **Copy between panes in one key.** F5 copies and F6 moves the selection to the other
  pane, or ⇧⌘C / ⇧⌘M on a laptop keyboard. Drag & drop works between panes and with other
  apps, using Finder's rules: the same volume moves, another volume copies, ⌥ forces a
  copy, ⌘ forces a move.
- **Safe file operations.** Copies and moves run in the background with a progress bar
  and Stop. Name clashes ask Replace / Keep Both / Skip / Stop, and Replace moves the old
  item to the Trash. ⌘Z undoes copy, move, rename, trash, new folder and duplicate.
- **Shell built in.** ⌥⌘T opens your terminal app in the current folder. Press `!` to type
  a command into the command line under the panes. It runs in the active pane's folder
  with your login shell and streams its output into a console.
- **Learnable.** A key-hint bar at the bottom shows the main keys. ⇧⌘P opens a command
  palette that searches every command and shows its shortcut, and Help ▸ Keyboard
  Shortcuts lists them all.
- **Configurable.** Hidden files (⇧⌘.), Return opens or renames, row size, which bars
  show, terminal and editor apps, and remappable keys (`keybindings.json`).

## Requirements

- macOS 14 Sonoma or later (developed on macOS 26).
- Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode isn't needed.

## Build and run

```bash
make app
```

```bash
make run
```

| Command | What it does |
| --- | --- |
| `make app` | Release build, assembles and ad-hoc signs `build/fman.app` |
| `make run` | `make app`, then opens it |
| `make test` | Unit and UI-controller tests (swift-testing) |
| `make snapshot` | Renders the window to `build/snapshots/{light,dark}.png` (add `SNAP_ARGS="--open ~/some/folder"`) |
| `make clean` | Removes `.build` and `build` |

The Makefile works around two Command-Line-Tools quirks: it passes `--build-system native`
(the default swift-build backend fails without Xcode), and it adds the CLT's
`Testing.framework` path so `swift test` can find swift-testing.

## Install

```bash
cp -R build/fman.app /Applications/
```

Use `~/Applications` if you prefer. Install before switching on any of the Finder
integration below, so macOS registers the copy that stays put.

**Privacy prompts.** macOS asks once per protected folder (Desktop, Documents, Downloads,
removable volumes). For a file manager it's simpler to grant **Full Disk Access** in System
Settings ▸ Privacy & Security ▸ Full Disk Access. `make app` signs ad hoc, so macOS can
ask again after a rebuild. To keep the grants, sign with a stable identity:
`make app SIGN_ID="Apple Development: Your Name (TEAMID)"`.

## Using fman instead of Finder

Everything is opt-in, under **Settings ▸ Finder**:

| Setting | Effect | Undo |
| --- | --- | --- |
| Use fman for Folders | Folders opened from other apps, the Dock, or `open ~/x` in Terminal open in fman | Restore Finder (same place) |
| Use fman for "Show in Finder" | Sets the system `NSFileViewer` default, so apps that honour it reveal files in fman. Apps pick it up after a restart | Same toggle |
| Open fman at login | Registers fman as a login item | Same toggle |

Finder keeps running, because it draws the Desktop and owns the Trash. fman also adds
**Services ▸ Open in fman** to Finder's context menu, and folders dropped on fman's Dock
icon open in the active pane.

## Keyboard

fman keeps Finder's shortcuts and adds the commander ones. Nothing uses a macOS
system-wide shortcut; a unit test checks the defaults against that list.

| Action | Keys |
| --- | --- |
| Move / extend selection, jump by typing | ↑ ↓, ⇧↑ ⇧↓, type a name |
| Up a level / into folder (both views) | ← / → |
| Open (enter folder or open file) | Return, ⌘↓, double-click |
| Enclosing folder, Back, Forward | ⌘↑, ⌘[, ⌘] |
| Switch pane | Tab / ⇧Tab |
| Copy / Move to other pane | F5 / F6, or ⇧⌘C / ⇧⌘M |
| Rename | F2, ⌘R (or Return, if Settings says Return renames) |
| New folder / new file | F7 or ⇧⌘N / ⌥⌘N |
| Move to Trash / delete immediately | F8 or ⌘⌫ / ⌥⌘⌫ (asks first) |
| Quick Look | Space, F3, ⌘Y |
| Edit in your editor | F4 |
| Copy, Cut, Paste, Move here | ⌘C, ⌘X, ⌘V, ⌥⌘V |
| Duplicate, Make alias, Copy path, Get Info | ⌘D, ⌃⌘A, ⌥⌘C, ⌘I |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Go to folder (Tab completes) | ⌘L, ⇧⌘G, or just type `/` or `~` |
| Filter this folder (Esc clears) | ⌘F |
| Show hidden files | ⇧⌘. |
| List / Columns | ⌘2 / ⌘3 |
| Open in other pane, Swap panes | ⌥⌘O, ⌘U |
| Home, Desktop, Documents, Downloads, Applications, Utilities | ⇧⌘H, ⇧⌘D, ⇧⌘O, ⌥⌘L, ⇧⌘A, ⇧⌘U |
| Open in Terminal | ⌥⌘T |
| Run shell command / Stop it / Console | `!` or ⌥⌘R / ⌘. / ⌥⌘J |
| Command palette | ⇧⌘P |

On a MacBook, F-keys need Fn unless "Use F1, F2, etc. keys as standard function keys" is
on. Every frequent F-key action also has a key that needs no Fn.

### Remapping keys

Help ▸ **Edit keybindings.json** creates `~/Library/Application Support/fman/keybindings.json`
and a `keybindings.defaults.json` reference beside it. Map command ids to keys:

```json
{
  "file.rename": ["f2", "return"],
  "nav.levelUp": ["left", "h"],
  "nav.levelDown": ["right", "l"],
  "pane.swap": null
}
```

Keys are written like `cmd+shift+n`, `opt+cmd+backspace`, `f5`, `tab` or `!`; `null`
unbinds a command. Changes apply when you switch back to fman, and unknown commands, bad
keys or clashes are reported.

## The command line

The bar under the panes runs commands in the active pane's folder:

- **Return** runs the command with your login shell, the one set in your user account
  (the same one Terminal uses), as `shell -l -i -c "…"`. PATH, aliases and functions match Terminal.
  Output streams into the console (⌥⌘J), with stderr in red, then the exit status and
  timing. ⌘. stops it (Ctrl-C to the whole process group).
- **⌘Return** runs it in your terminal app instead, for interactive tools like vim, top
  or ssh, and leaves a shell open there.
- **⌥Return** inserts the selected names, shell-quoted (⇧⌥Return inserts full paths).
- **↑ / ↓** walk the history. **Esc** returns to the pane.

Commands get stdin from `/dev/null` and `TERM=dumb`. If your shell config is slow or
prints prompts, turn off "Load interactive config" in Settings ▸ Shell.

## Project layout

```
Sources/FmanCore   Foundation-only model: listing, sorting, history, names, keymap and
                   command registry, file operations + copy engine + undo records,
                   FSEvents watcher, shell runner. Fully unit-tested.
Sources/FmanUI     AppKit app: window, panes, List and Column browsers, sidebar, path bar,
                   operations UI, shell UI, palette, settings (SwiftUI).
Sources/fman       Executable entry point.
Tests/             FmanCoreTests (engine) and FmanUITests (real windows driven with
                   synthetic key events, fake drags, scripted prompts).
scripts/           make-icon.swift draws the app icon.
Resources/         Info.plist template.
```

Deferred work is tracked in [TODO.md](TODO.md).
