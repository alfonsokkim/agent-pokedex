# Windows parity checks

The Windows app reuses the Mac app's upstream sprite sheets and normal/shiny
palettes. No replacement artwork is generated. Its embedded national Dex catalog
contains the same 649 Gen I to V species in order.

Run the portable core checks on any machine with .NET 8:

```sh
dotnet run --project windows/Tests/Core/ClaudePet.CoreTests.csproj -c Release
```

Pass an existing sprite directory as the final argument after `--` to validate
all 1,298 upstream palettes too. These tests cover the real production catalog,
encounters, recall acknowledgement, palette parser, column positioning, labels, Codex log tracking,
read-only thread discovery, and asset downloads.

On Windows, run the native checks:

```sh
dotnet run --project windows/Tests/Windows/ClaudePet.WindowsTests.csproj -c Release
```

The native suite downloads the sprite sources into a temporary directory and
decodes every normal/shiny pair through WPF. It also checks placement, context
caption clearance, persisted encounters, shiny hover stars, live window sizing, packaged Codex artwork, and Windows
file-owner detection. It never installs hooks or opens an agent chat.

The GitHub Windows build runs both suites before packaging. A successful cross
build on Mac is not a substitute for running the Windows suite or inspecting
the app on a Windows desktop.

## Desktop smoke test

- Install from the Windows zip and open both a Claude Code CLI and a native
  Codex CLI. Each chat should have one pet, with the correct provider badge.
- Ask Codex a question that uses request_user_input_async. Its pet should flash
  red until the reply is sent, including if other tool calls complete first.
- Check all five generation menus and confirm normal Virizion is green.
- Recall and release pets. Each release rolls 1 in 25; hiding, sleeping, and
  restarting preserve an existing appearance. Picking a species starts normal.
- Recall a ready pet: its current completion is dismissed and it stays hidden.
  Recall a working pet: it stays hidden during work and returns on completion or
  when it needs attention. Letting out an acknowledged pet cannot replay its message.
- Hover over a shiny. Gold pixel stars should burst outward and fade without
  looping while the pointer stays still. Moving off and back replays the burst.
- Check mixed-size Pokemon in every column corner, then a horizontal row with
  adjacent completed agents. Above-head captions must clear the CTX bar.
- Check Klinklang or Bronzor turning through front/side/back frames without
  lateral pacing or changing size.
- Check the context bar is green when mostly empty and red when nearly full.
- Check clicking focuses the owning window. Exact terminal-tab selection and
  Orca chat selection are not promised. Check mixed-DPI and secondary displays
  separately; Windows positioning uses the primary work area for automatic stacks.

The native Windows app does not discover WSL or remote Codex homes. Conductor's
Mac-specific project order and accessibility navigation have no Windows port here.
Hello Kitty remains a separate Mac app and has no Windows implementation.

For isolated testing, set CLAUDE_PET_DATA_DIRECTORY to a temporary directory
before launching the app. This overrides pet data and preferences, not the
Claude Code settings or hooks. Installer commands refuse to run with that
override, so a test directory cannot become an uninstall target.
