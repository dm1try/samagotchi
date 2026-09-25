# Desktop helper (macOS)

`chi desktop` installs **Chi Helper**, a small native app. It sends text you selected in any app to a chi session,
either with a question as [your message](sessions.md#sending-a-message) (a turn runs, and the answer shows in the
attached terminal or web page), or as a [context note](sessions.md#context-notes) (the model sees it on its next
turn, and no turn starts).

- **Services menu:** select text → right-click → Services → **Send to chi**.
- **Hotkey ⌃⌥⌘N:** opens the panel with the **clipboard** (not the selection), for apps whose Services menu lacks
  the item.
- **A shortcut for the selection:** give "Send to chi" its own shortcut in System Settings → Keyboard → Keyboard
  Shortcuts… → Services → Text (pick one other than ⌃⌥⌘N). It goes through the Services menu route, so the panel
  opens with the selected text. If it doesn't fire at once, see Troubleshooting below.

The panel has a one-line message field on top ("Ask chi…", focused), the text below it (editable, shown as the
quote it becomes), where it came from (the app's name, editable; notes only), the size against the 16 KB cap, and the
sessions. Keys:

- **⏎** sends a message: `chi send -m <the line>` with the text as quoted context above it. With the line empty,
  the text is the message.
- **⌘⏎** sends a note: `chi note`, the line (if any) then the text.
- **⇧⏎** is a newline, in either field. Esc closes.

The list shows the sessions a worker runs now, then, under a "recent" divider, up to 3 stopped ones (dimmed, with
their age: "2h ago", "yesterday"). Click a session or press ⌘1…⌘9 to tick it. The last choice is preselected while
it's still live; if there's only one live session, that one is (a recent one never is). A message to a recent
session starts its worker; a note to one waits for its next start, and the panel shows chi's line saying so. After a
send the panel shows chi's line and closes. On an error it stays open and shows the error.

A session open in a `chi --no-shared` REPL isn't listed: it takes no notes or messages.

## Install

```sh
chi desktop install            # build it into ~/Applications and start it
chi desktop install --login    # … and start it at login (macOS shows a "Login Item Added" notice)
```

It needs the Command Line Tools (`xcode-select --install`): the app is compiled on your Mac with `swiftc` and
signed ad hoc, with no notarization and no Xcode project. A build takes a few seconds warm, but can take a few
minutes cold. The app has no Dock icon and keeps running once started. Without `--login` it runs until you log out,
and opening it from `~/Applications` starts it again.

Install from the checkout or gem you keep: the helper runs **that** chi's `bin/chi`. Installing from a linked git
worktree prints a warning, because the helper stops working once that worktree is removed.

## Commands

| Command | Does |
|---|---|
| `chi desktop install [--force] [--login]` | builds, installs and starts it; `--force` replaces an existing copy |
| `chi desktop upgrade` | rebuilds it for this chi and restarts it, keeping the login setting |
| `chi desktop uninstall` | quits it and removes the app, its login item, launch file and settings |
| `chi desktop status` | version against chi's, how it runs chi, state dirs, Service, hotkey, process, login item |

`chi self` has a `desktop` line: `0.1.x (matches)`, `0.1.w (chi is 0.1.x: chi desktop upgrade)` or `not installed`.

## How it runs chi

Apps started by macOS get a bare environment: no shell rc files, so no rbenv/chruby/mise/asdf and none of your
exports. So `install` writes `~/Library/Application Support/Chi Helper/launch.json` with:

- the absolute path of the Ruby running chi and of its `bin/chi`;
- `LANG=en_US.UTF-8`;
- only these variables, and only when they are set: `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `GEM_HOME`, `GEM_PATH`,
  `RUBYLIB`. No tokens and no `SAMAGOTCHI_*` settings go in.

The file freezes the install shell's values. If you install with a temporary `XDG_STATE_HOME`, the helper keeps
using it. `status` prints the baked dirs.

### The contract with chi

The helper uses only these commands, so it could ship on its own later:

- `chi sessions list --live --scope=all --format json` and `chi sessions list --limit 20 --scope=all --format json` →
  `[{id, short_id, desc, cwd, project, updated_at, live, busy, owner, recap}]` (it uses `id`, `desc`, `cwd`, `busy`, `updated_at`;
  "recent" = rows of the second call that aren't live and have `owner: null`; only UUID-shaped ids go on to chi).
- `chi send [-m LINE] ID...` with the text on stdin (or none) and `chi note --source NAME ID...` with the text on
  stdin → one line per session on stdout; exit 0 means all sent or queued, 1 means some were refused or failed.

Each call is stopped after 10 s. A stopped `chi note` says the note may be partly delivered.

## Troubleshooting

- **"chi not found at …, run `chi desktop upgrade`"**: the Ruby or checkout in `launch.json` moved (a Ruby upgrade,
  a removed worktree). Run `chi desktop upgrade` from the chi you use now.
- **No "Send to chi" in the Services menu:** check `chi desktop status` (service). Try
  `/System/Library/CoreServices/pbs -update`, start the app again, or log out and back in. It must be ticked in
  System Settings → Keyboard → Keyboard Shortcuts… → Services → Text.
- **A keyboard shortcut for the Service** (in the same settings pane) may keep firing the old one until the app
  restarts or you log out: macOS caches Services.
- **⌃⌥⌘N does nothing:** `status` says whether another app holds it. macOS doesn't report clashes with its own
  shortcuts.
- **"No live sessions":** start one with `chi` in a terminal; `chi sessions list --live --scope=all` shows the same list.
