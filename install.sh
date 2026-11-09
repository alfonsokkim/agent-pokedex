#!/bin/zsh
# Sets up Agent Pokédex on this Mac: downloads the sprites, installs
# Claude Pet.app into ~/Applications, installs the `claude-pet` command and
# `/pet` in Claude Code, adds the Claude Code hooks that report each session's
# status, then starts it. Safe to re-run, for example after pulling changes.
#
#   ./install.sh                 install or update
#   ./install.sh --remove-hooks  take the Claude Code hooks out
#   ./install.sh --uninstall     remove everything the installer added
set -e
here=${0:A:h}
app="$HOME/Applications/Claude Pet.app"
binary="$app/Contents/MacOS/ClaudePet"
settings="$HOME/.claude/settings.json"
data="$HOME/.local/share/claude-pet"

case "$1" in
  --remove-hooks)
    /usr/bin/osascript -l JavaScript "$here/hooks.js" "$settings" "$binary" remove
    exit
    ;;
  --uninstall)
    pkill -x ClaudePet 2>/dev/null || true
    /usr/bin/osascript -l JavaScript "$here/hooks.js" "$settings" "$binary" remove
    rm -rf "$app" "$data/sprites" "$data/sessions"
    rm -f "$data/pokemon.json"
    rm -f ~/.local/bin/claude-pet ~/.claude/commands/pet.md
    defaults delete com.alfonsokim.claude-pet 2>/dev/null || true
    echo "Uninstalled. This folder is untouched; delete it yourself if you like."
    exit
    ;;
esac

prebuilt="$here/Claude Pet.app"
if [[ -d "$prebuilt" ]]; then
  codesign --verify --deep --strict \
    -R '=anchor apple generic and certificate leaf[subject.OU] = "D47CYV4C79" and identifier "com.alfonsokim.claude-pet"' "$prebuilt"
  spctl --assess --type execute "$prebuilt"
elif ! command -v swiftc >/dev/null; then
  echo "Building from source needs Xcode's command-line tools. Run: xcode-select --install"
  exit 1
fi

zsh "$here/fetch-sprites.sh"
if [[ -d "$prebuilt" ]]; then
  mkdir -p "$HOME/Applications"
  stage=$(mktemp -d "$HOME/Applications/.agent-pokedex.XXXXXX")
  cleanup_install() {
    if [[ ! -e "$app" && -e "$stage/previous.app" ]]; then
      mv "$stage/previous.app" "$app"
    fi
    rm -rf "$stage"
  }
  trap cleanup_install EXIT
  trap 'exit 1' INT TERM HUP
  ditto "$prebuilt" "$stage/Claude Pet.app"
  codesign --verify --deep --strict "$stage/Claude Pet.app"
  pkill -x ClaudePet 2>/dev/null || true
  if [[ -e "$app" ]]; then
    mv "$app" "$stage/previous.app"
  fi
  if ! mv "$stage/Claude Pet.app" "$app"; then
    [[ ! -e "$stage/previous.app" ]] || mv "$stage/previous.app" "$app"
    exit 1
  fi
else
  zsh "$here/build.sh"
fi

mkdir -p ~/.local/bin ~/.claude/commands
install -m 755 "$here/claude-pet" ~/.local/bin/claude-pet
sed "s|__HOME__|$HOME|g" "$here/pet.md" > ~/.claude/commands/pet.md

/usr/bin/osascript -l JavaScript "$here/hooks.js" "$settings" "$binary" add

pkill -x ClaudePet 2>/dev/null || true
open "$app"
echo "Done. Claude and Codex chats will each keep their own Pokémon."
echo "Toggle the pets with claude-pet in a terminal, or /pet in Claude Code."
