# Desktop helper (macOS)

`chi desktop` installs **Chi Helper**, a small native app. It sends text you selected in any app (or a screenshot,
an image: see [Images](#images)) to a chi session,
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
- **⌥⏎** pastes into an agent in a kitty window without pressing Enter (see [Agents in kitty](#agents-in-kitty));
  it is not a newline.
- **⇧⏎** is a newline, in either field. Esc closes.

The list shows the sessions a worker runs now, then, under a "recent" divider, up to 3 stopped ones (dimmed, with
their age: "2h ago", "yesterday"). Click a session or press ⌘1…⌘9 to tick it. The last choice is preselected while
it's still live; if there's only one live session, that one is (a recent one never is). A message to a recent
session starts its worker; a note to one waits for its next start, and the panel shows chi's line saying so. After a
send the panel shows chi's line and closes. On an error it stays open and shows the error.

The first row, **New session in <folder>** (⌘0), starts a session with the message instead: `chi send --new --dir
<folder>`, so it shows in `chi web` at once (see [Starting a session](sessions.md#starting-a-session)). The folder is
that of the most recently updated live session, else of the newest recent one, else your home folder. It is ticked
alone (ticking it clears the sessions and the reverse) and is preselected when no session is live. ⌘⏎ on it beeps: a
note needs a session. After the send the panel shows `started <id>…` for 3 s. On its right, in grey, the row names
the model the new session starts on (`chi self --model`: `default.model` from config.yml, or its env override; an
alias as the model it names).

### Everyone it concerns

The second row, **Everyone it concerns** (⌘B), shares a note with every session it may concern instead of the ones
you pick: ⌘⏎ (the **Broadcast** button) runs [`chi broadcast`](broadcast.md) with the line, then the text, on stdin.
chi picks the sessions (a shared ticket, PR or link, else a small triage model), so the preselected session doesn't
count: the row is ticked alone, like the new row. Write it the way you'd tell a colleague: a first line such as
`shopfront/checkout` keeps the note to that project's sessions, and the rest is the selection.

- The panel shows "broadcasting…", then the broadcast's id and chi's summary line (`b-7f3a1c9e: delivered 4 ·
  skipped 2 · 1 unchecked: triage deadline`), and **stays open**: Esc closes. Which sessions got it and why:
  `chi broadcast log` in a terminal.
- A broadcast is a text note: ⏎ and images beep. The source field and Send are hidden (its source is `broadcast`).
- It may take `broadcast.triage_deadline` (20 s) and 10 s more before the helper stops it ("the note may be partly
  delivered"). The helper reads that from its launch file: after changing the deadline, run `chi update` (or
  `chi desktop upgrade`).

### Choosing the model

Click the model on the new row, or press **⌘M**, to choose another one for the new session. The chooser takes the
place of the session list: a search field (focused), then **Default (<model>)** (`Default (small → box:gemma-small)`
for an alias), your recent picks and every host's
models and aliases (from [`chi models`](cli.md#listing-the-models)), at most nine at a time.

- Type to search: every word must match the host or the id; names starting with what you typed rank first. A name
  no host lists is offered at the bottom as "not listed" and sent as typed (a host that is down, a model just added).
- ↑/↓ and ⏎, a click, or ⌘1…⌘9 pick; Esc (or ⌘M) closes the chooser only, a second Esc the panel. While an input
  method is composing, ⏎, the arrows and Esc are its own.
- The row then shows the pick in the accent colour, and ⏎ sends `chi send --new --model <name>`, the name exactly as
  the chooser shows it; Default sends no `--model`. An existing session keeps its model (switch it there with `/model`).
- The pick is remembered for the next open (and the last five in the recent list), for every folder. A remembered
  model no host lists any more falls back to the default, with a note in the panel.
- The list is fetched again at each open; the previous one shows meanwhile ("Loading models…" the first time after
  the helper starts). Hosts that failed or took over 4 s are named under the list; the default and the recent picks
  still work.

The chooser needs a chi with `chi models`: an older helper works with a newer chi, not the reverse
(`chi desktop upgrade` after updating chi).

A session open in a `chi --no-shared` REPL isn't listed: it takes no notes or messages.

## Images

The panel also sends images, as attachments of the message (`chi send --image`, see
[Sending a message](sessions.md#sending-a-message)):

- **A screenshot:** ⌃⇧⌘4 (a region to the clipboard), then ⌃⌥⌘N. The panel shows it as a thumbnail, named
  `clipboard.png`; the context box stays empty.
- **Finder:** right-click image files → Services → **Send to chi** (the same Service as for text, so its shortcut
  works here too), or ⌘C on them and ⌃⌥⌘N. Up to 20 at once.
- **Other apps:** a picture selected in Preview, Safari's Copy Image, anything that puts image data on the clipboard.
- **Drop** image files or the floating screenshot thumbnail (⇧⌘4 to a file) anywhere on the open panel: they are
  added to the ones there.

When the clipboard holds both text and a picture (cells copied in Numbers or Excel), the text wins, as before. The
thumbnails sit under the message line, 48 px high, the file name as a tooltip; hover one for its ✕.

- A message is required with images: the line says "Say something about the image…", and ⏎ does nothing until
  there is text (the context box counts).
- Notes are text only: ⌘⏎ with images beeps and says "Notes are text only: ⏎ sends the image as a message".
- The session's model must see images. A text-only one fails the turn in the session (the attached terminal or the
  web shows why); the panel has already said it was sent.
- A session busy with a turn runs the image message as its next turn: the line says `(runs after the current turn)`.
- Clipboard and dropped image data goes to temp files under `$TMPDIR/chi-helper`, deleted after the send or when
  the panel closes; files from Finder are sent as they are, never touched. A send with images may take up to 30 s
  (converting, a worker starting) before the panel gives up.

## Agents in kitty

The panel can also send to agent CLIs (claude, codex, gemini, aider, …) running in
[kitty](https://sw.kovidgoyal.net/kitty/) windows, next to chi sessions. kitty only, through its remote control;
off until you set it up:

1. In `kitty.conf`, remote control on and a socket: `allow_remote_control yes` and a `listen_on unix:…` line.
2. Copy that `listen_on` value as it is into chi's config.yml:

   ```yaml
   kitty:
     listen_on: unix:/tmp/kitty.${KITTY_PID}
   ```

   `kitty.agents` picks the programs listed (default `claude|codex|gemini|aider|opencode|cursor-agent|amp|goose`, a
   YAML list works too; `"*"` lists every window, shells too), `kitty.binary` the kitty to run (default
   `/Applications/kitty.app/Contents/MacOS/kitty`). See [Configuration](configuration.md#desktop-helper-agents-in-kitty).
3. Run `chi update` (or `chi desktop upgrade`): the helper reads these from its launch file, so **after every edit of
   `kitty:`** run it again. `chi update` only rewrites the launch file when only the settings changed (no rebuild);
   `chi desktop upgrade` always rebuilds.

The helper finds the sockets itself: kitty adds `-<pid>` to a `listen_on` path from kitty.conf (and fills in
`{kitty_pid}`), `~` and variables the helper knows are expanded, others (`${KITTY_PID}`) stay as written, as kitty
keeps them. Several kitty instances all count. Only `unix:` sockets work.

The panel lists the windows whose foreground program is one of the agents under a **kitty** divider, between live
and recent sessions: "claude · <its title>", the folder below, a terminal icon, and a ⌘ number like the sessions.
With the settings on but no agent running, one dim line says "no agents in kitty". A window counts when a foreground
process's program is an agent, also as the script of `node …/codex` (that match is untested for codex and gemini).

- **⏎** pastes into every chosen window and presses Enter: the text as a `> ` quote, a blank line, your message, then
  one image path per line. Chosen together with chi sessions, each gets the message and the panel shows one line
  ("Sent. · sent to claude · samagotchi").
- **⌥⏎** only pastes (no Enter), and only when every chosen target is a kitty window: build up several screenshots,
  each with its own line, then press Enter in kitty. The footer shows **Paste ⌥⏎** instead of Note then.
- **⌘⏎** with a kitty window chosen beeps: "Notes are for chi sessions". ⌥⏎ with a chi session: "Paste only is
  for kitty windows".
- **Images:** a screenshot or other image data is copied to `$TMPDIR/chi-helper-sent/<uuid>.png` (or `.tiff`) and
  its path pasted; the agent reads it from there (claude attaches it as `[Image #1]`). These files are deleted a week
  later, at the helper's next start. Finder files are pasted with their own path, `'…'`-quoted when they hold spaces.
- The paste arrives as one bracketed paste, so the agent takes newlines as text (claude shows long ones as
  `[Pasted text]`). With `agents: "*"` beware of a program that doesn't turn bracketed paste on: the newlines would
  act as Enter.
- No delivery confirmation: before pasting, the helper checks the window is still there ("window closed" if not);
  it can't know whether the agent read it. The 16 KB cap is chi's; a kitty window takes more.
- Focus goes back to the app you came from, as for sessions. The last choice (kitty windows too) is preselected
  while listed; ⌘ numbers shift as windows come and go.

## Install

```sh
chi desktop install            # build it into ~/Applications and start it
chi desktop install --login    # … and start it at login (macOS shows a "Login Item Added" notice)
```

It needs the Command Line Tools (`xcode-select --install`): the app is compiled on your Mac with `swiftc` and
signed ad hoc, with no notarization and no Xcode project. A build takes a few seconds warm, but can take a few
minutes cold. The app has no Dock icon and keeps running once started. Without `--login` it runs until you log out,
and opening it from `~/Applications` starts it again.

Install from the checkout or gem you keep. From a gem install the helper runs the gem's `chi` wrapper (the one on
your PATH, e.g. `$GEM_HOME/bin/chi`), which picks the newest installed version, so gem upgrades and `gem cleanup`
don't break it. From a checkout it runs **that** checkout's `bin/chi`; installing from a linked git worktree prints a
warning, because the helper stops working once that worktree is removed. After switching between a checkout and a
gem install, run `chi desktop upgrade` from the one you now use.

`chi update` keeps it current: it rebuilds and restarts the helper only when its Swift sources changed since the
build (`launch.json` records their digest) or the Ruby it runs moved. A new chi that left the sources alone only
rewrites `launch.json`, which the app reads at each send, so the app keeps its older version number and that's fine.

## Commands

| Command | Does |
|---|---|
| `chi desktop install [--force] [--login]` | builds, installs and starts it; `--force` replaces an existing copy |
| `chi desktop upgrade` | rebuilds it for this chi and restarts it, keeping the login setting (always; `chi update` does it only when needed) |
| `chi desktop uninstall` | quits it and removes the app, its login item, launch file and settings |
| `chi desktop status` | version against chi's, how it runs chi, state dirs, Service, hotkey, process, login item |

`chi self` has a `desktop` line: `0.1.x (matches)`, `0.1.w (up to date for chi 0.1.x)` (an older build whose sources
haven't changed), `0.1.w (chi is 0.1.x: chi update)` (a rebuild is due) or `not installed`. `chi desktop status`
says the same.

## How it runs chi

Apps started by macOS get a bare environment: no shell rc files, so no rbenv/chruby/mise/asdf and none of your
exports. So `install` writes `~/Library/Application Support/Chi Helper/launch.json` with:

- the absolute path of the Ruby running chi and of chi itself (the gem's wrapper, or a checkout's `bin/chi`);
- `LANG=en_US.UTF-8`;
- only these variables, and only when they are set: `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `GEM_HOME`, `GEM_PATH`,
  `RUBYLIB`. No tokens and no `SAMAGOTCHI_*` settings go in;
- the settings the panel needs from config.yml, as chi read them then: the `kitty:` section (when
  `kitty.listen_on` is set) and `broadcast_timeout` (`broadcast.triage_deadline` + 10 s).

The file freezes the install shell's values. If you install with a temporary `XDG_STATE_HOME`, the helper keeps
using it. `status` prints the baked dirs.

### The contract with chi

The helper uses only these commands, so it could ship on its own later:

- `chi sessions list --live --scope=all --format json` and `chi sessions list --limit 20 --scope=all --format json` →
  `[{id, short_id, desc, cwd, project, updated_at, live, busy, owner, recap, parent_id, archived, scratch, ctx_pct}]` (it uses `id`, `desc`, `cwd`, `busy`, `updated_at`;
  "recent" = rows of the second call that aren't live and have `owner: null`; only UUID-shaped ids go on to chi).
- `chi send [-m LINE] [--image PATH]... ID...` and `chi send --new --dir DIR [--model NAME] [-m LINE] [--image PATH]...`
  with the text on stdin (or none), and `chi note [--source NAME] ID...` with the text on stdin → one line per session
  on stdout; exit 0 means all sent or queued, 1 means some were refused or failed.
- `chi broadcast` with the text on stdin → its id first (`broadcast b-…`), a line per recipient, then the summary line
  (`delivered N · skipped M…`); exit 0 when it ran, 1 when refused or a delivery failed.
- `chi self --model` → the model a new session starts on (the panel's hint).
- `chi models --format json` → the models the hosts offer (the new-session model picker).

Each call is stopped after 10 s, a send with images after 30 s, a broadcast after the launch file's
`broadcast_timeout` (`broadcast.triage_deadline` + 10 s; 30 s when it has none). A stopped `chi note` or `chi
broadcast` says the note may be partly delivered.

## Troubleshooting

- **"chi not found at …, run `chi desktop upgrade`"**: the Ruby or checkout in `launch.json` moved (a Ruby upgrade,
  a removed worktree). Run `chi desktop upgrade` (or `chi update`) from the chi you use now.
- **No "Send to chi" in the Services menu:** check `chi desktop status` (service). Try
  `/System/Library/CoreServices/pbs -update`, start the app again, or log out and back in. It must be ticked in
  System Settings → Keyboard → Keyboard Shortcuts… → Services → Text.
- **A keyboard shortcut for the Service** (in the same settings pane) may keep firing the old one until the app
  restarts or you log out: macOS caches Services.
- **⌃⌥⌘N does nothing:** `status` says whether another app holds it. macOS doesn't report clashes with its own
  shortcuts.
- **"Send to chi" missing on images in Finder or Preview** after an upgrade: the Services cache still has the old
  (text-only) entry; `/System/Library/CoreServices/pbs -update`, restart the helper, or log out and back in.
- **"No live sessions":** start one with `chi` in a terminal; `chi sessions list --live --scope=all` shows the same list.
