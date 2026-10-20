# Claude and Codex Agent Pokédex

A pixel Pokemon for every Claude or Codex session you have running on a Mac.
Claude Code is also supported on Windows. They float at the edge of your screen
and act out what their agent is doing, so you can tell at a glance which one is
working, which one is waiting on you, and which one just finished.

![Four pets in the corner of the screen while Claude Code works](docs/desktop.jpg)

| Agent | Pet |
| --- | --- |
| Working | Paces back and forth over a row of dots |
| Needs you (a permission prompt or a question) | Hops and flashes red, like it's taking hits |
| Finished | Jumps for joy over "*Pikachu* is done" until you look at it |
| Idle | Steps in place, then falls asleep with z's drifting up |
| Untouched for 12 hours | Glows red and shrinks away into its Poke Ball, out of sight. When its session gets busy again, the ball is thrown in from the edge of the screen and it pops back out |

Each session gets its own Pokemon and keeps it. All 649 Pokemon from Generations
I through V are available in the Kanto, Johto, Hoenn, Sinnoh, and Unova pickers.

## Download

| | |
| --- | --- |
| **Mac** (macOS 14 or later) | [claude-agent-pokedex-mac.zip](https://github.com/alfonsokkim/claude-agent-pokedex/releases/latest/download/claude-agent-pokedex-mac.zip) |
| **Windows** (Windows 10 or 11, 64-bit) | [claude-agent-pokedex-windows.zip](https://github.com/alfonsokkim/claude-agent-pokedex/releases/latest/download/claude-agent-pokedex-windows.zip) |

The Mac app supports [Claude Code](https://claude.com/claude-code), the Codex
CLI, Codex in the ChatGPT app, Conductor, and Orca. The Windows build currently
supports Claude Code.

## Install on a Mac

The Mac app is built on your machine, so you need Xcode's command-line tools:
`xcode-select --install`.

Unzip the download, then in Terminal:

```bash
cd ~/Downloads/claude-agent-pokedex-mac
zsh install.sh
```

Or with git:

```bash
git clone https://github.com/alfonsokkim/claude-agent-pokedex.git
cd claude-agent-pokedex
./install.sh
```

The installer:

1. downloads all 649 Gen I to V sprites (they aren't shipped here, see [Sprites](#sprites))
2. builds `Claude Pet.app` into `~/Applications`
3. adds a `claude-pet` command and a `/pet` command for Claude Code
4. adds a set of hooks to `~/.claude/settings.json` so each session can report
   its status, leaving your other settings exactly as they were
5. starts the app. Codex sessions are discovered automatically and need no hooks

Run it again any time, for example after a `git pull`. To start the pets when
you log in, add **Claude Pet** under System Settings → General → Login Items.

## Install on Windows

Heads up: I lowkey haven't tested the Windows version yet, so if it's cooked,
just let me know by [opening an issue](https://github.com/alfonsokkim/claude-agent-pokedex/issues) :)

1. Unzip the download.
2. Double-click **install.cmd**.
3. Windows may warn that it "protected your PC", because the app isn't signed.
   Click **More info**, then **Run anyway**.

The installer copies the app to `%LOCALAPPDATA%\ClaudePet`, downloads the
sprites, adds the hooks to `%USERPROFILE%\.claude\settings.json` (leaving your
other settings as they were), adds `/pet` to Claude Code and starts the pets.
Nothing else needs installing.

To start the pets when you sign in, press Win+R, type `shell:startup`, and put
a shortcut to `%LOCALAPPDATA%\ClaudePet\ClaudePet.exe` in that folder.

## Using it

A pet appears for each Claude Code session as soon as it does something. Live
Codex chats are found automatically through their local thread state.

- **Summon or dismiss** the pets with `/pet` in Claude Code, or `claude-pet` in
  a Mac terminal.
- **Click** a pet to jump to its session: it brings that terminal forward, and
  clears the "is done".
- **Drag** a pet anywhere, including onto another display. It stays where you
  leave it.
- **Shift-drag** any pet to move them all together, onto another display too.
  The line-up keeps its new spot, so pets that come and go still line up there.
- **Hover** over a pet to see which project it belongs to, and a CTX bar in
  the style of FireRed's HP bar showing how much of its session's context
  window is left. It drains from green to yellow to red, and once a session
  is over 80% full the bar stays up without hovering.
- **Right-click** a pet for:
  - **Go to Agent**
  - **Pokemon**: open a generation and region submenu, then pick from its sprite
    grid. The ones other sessions have are greyed out, and picking one swaps
    the two.
  - **Return to Poke Ball**: put a pet away by hand. It's out of sight until
    its session gets busy, then its ball is thrown back in.
  - **Let Out**: call back any pet that's away.
  - **Line Up Pets**: a column or a row, in any corner of the display that pet
    is on. Pets are
    spaced by their real size, so a Snorlax gets more room than a Pikachu, and
    ones that are away take no room at all. In a horizontal row, adjacent
    completion captions alternate below and above the pets so they do not overlap.
  - **Size**: a slider from small to large, for when the pets are in the
    way. It holds for a moment at Small, Medium and Large as you drag it.

- **The Poke Ball in the menu bar** (Mac) works on every pet at once:
  - **Hide Pets** / **Show Pets**: get them all off the screen, say for a
    screen share, and back again. They stay hidden until you show them.
  - **Return Idle Pets**: put away every pet that isn't working or waiting
    on you.
  - **Let Out All Pets**: call back every pet that's away.

![Picking a Pokemon from the right-click menu](docs/picker.png)

## Claude app chats

Chats in the Claude desktop app get pets too. A chat's pet shows up when it
starts replying, paces while it does, then jumps for joy over "*Pikachu* is
done" until you open that chat. Clicking the pet opens the chat. A chat keeps
its pet for a day after it last replied.

The pets read the Claude app's sidebar (never your conversations) through the
system's accessibility features. On Windows that needs nothing from you. On a
Mac, Claude Pet needs to be turned on under System Settings → Privacy &
Security → Accessibility. It asks the first time it starts; if you skipped that,
right-click a pet and choose **Show Claude App Chats…**. Because the app is
built on your Mac, macOS may need you to switch it off and on again there after
you reinstall or update.

## Conductor

Every chat in [Conductor](https://conductor.build) gets a pet too, Claude Code
and Codex alike, for as long as its workspace isn't archived. The pet paces
while the chat works, is alarmed when it asks you a question, wants a plan
approved or hits an error, and says it's done until you look at that chat.
Clicking the pet brings Conductor forward on that workspace.

Conductor ordering follows its root section, project display order, and
workspace activity. Projects with one active workspace use only the project
name. Projects with multiple workspaces use `[project] [workspace]: chat title`.
Generated city folder names are not shown when the real workspace name is
available. A small orange spark marks Claude sessions and the blue Codex logo
marks Codex sessions without adding another word to the label.

The pets read Conductor's own list of chats on your Mac, nothing you have to set
up. Jumping to the workspace uses the same Accessibility permission as the
Claude app's chats; without it, clicking just brings Conductor forward. Mac only.

## Codex

Every live Codex thread gets a persistent Pokemon, whether it was opened with
the `codex` command, in the ChatGPT app's Codex tab, in Conductor, or in Orca.
The app reads Codex's local thread index and the writer lock held by each open
chat. Closed historical chats are ignored, and Conductor threads are
deduplicated against Conductor's richer status data.

The pet follows turn starts and completions, user-input waits, the percentage
of context remaining, and the host app. Clicking it clears the completion
state and brings its terminal or desktop app forward.

## How it works

Claude Code runs the app's own binary (`ClaudePet --hook`) in the background on
each hook event: when a session starts, when you send a message, when a tool
runs, when it asks for permission, when it finishes and when it ends. Each run
writes one small file per session, which the app reads once a second:
`~/.local/share/claude-pet/sessions` on a Mac, `%LOCALAPPDATA%\ClaudePet\sessions`
on Windows.

Pressing Esc to deny a prompt or interrupt a turn doesn't fire a hook, so the
app also checks the end of the session's transcript for the interrupt. A
session that crashes is cleaned up by watching its Claude process.

Codex uses its local state database and one live writer lock per open thread.
Orca account-specific Codex homes are discovered alongside `~/.codex`.

If you run your agents in [herdr](https://herdr.dev), the pets follow herdr's
sidebar instead: they line up in the same order, and clicking one switches
herdr to that pane.

`ClaudePet --status` lists every session the pets can see. On a Mac that's
`~/Applications/Claude Pet.app/Contents/MacOS/ClaudePet --status`; on Windows,
`%LOCALAPPDATA%\ClaudePet\ClaudePet.exe --status`.

## Uninstall

- **Mac:** `zsh install.sh --uninstall` from the download (or the cloned repo).
  To keep the app but stop the hooks, use `zsh install.sh --remove-hooks`.
- **Windows:** double-click **uninstall.cmd** from the download.

Either way this removes the app, the commands, the hooks, the downloaded
sprites and the pets' saved settings.

## Troubleshooting

- **No pets:** make sure the app is running (`/pet`), then send a message in a
  Claude Code session so it reports in.
- **A pet is stuck working or flashing:** send that session a message, or
  click the pet; its next hook event puts it right.
- **No pets for Claude app chats:** check Claude Pet is on under System
  Settings → Privacy & Security → Accessibility (switch it off and on after
  an update), and that the Claude app's sidebar is open on Chats, not Code.
- **The Mac build fails:** install or update Xcode's command-line tools with
  `xcode-select --install`, then run the installer again.
- **Windows sprites are missing:** run install.cmd again; it retries any that
  didn't download.

## Project layout

| File | What it is |
| --- | --- |
| `ClaudePet.swift` | The Mac app: a single Swift file on AppKit, no dependencies |
| `install.sh`, `build.sh`, `fetch-sprites.sh`, `hooks.js` | The Mac installer and its parts |
| `claude-pet`, `pet.md` | The Mac toggle command and `/pet` |
| `Info.plist` | The Mac app bundle's metadata |
| `windows/Program.cs` | The Windows app: a single C# file on WPF, which also installs itself |
| `windows/install.cmd`, `windows/uninstall.cmd` | Double-click launchers for the Windows setup |
| `.github/workflows/build.yml` | Builds both apps, and publishes the downloads on each release |

## Sprites

The Pokemon are Gen 3-style walking sprites from the
[pokeemerald-expansion](https://github.com/rh-hideout/pokeemerald-expansion)
project, and the Poke Ball is FireRed's item ball from
[pret/pokefirered](https://github.com/pret/pokefirered). They're Nintendo and
Game Freak's art, so they aren't included in this repo: the installers
download them, for personal use.

Pokemon is a trademark of Nintendo, Game Freak and Creatures. Claude is a
trademark of Anthropic. This is a fan project, not affiliated with or endorsed
by any of them.
