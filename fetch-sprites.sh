#!/bin/zsh
# Downloads Gen 3-style walking sheets for National Pokédex numbers 1 through
# 649 from pokeemerald-expansion's follower sprites. Personal use only.
# Each sheet is one row of square frames: down ×2, up ×2, side ×2 (facing left).
# They go where the app looks for them, wherever this repo is cloned.
set -e
dir="$HOME/.local/share/claude-pet/sprites"
catalog="$HOME/.local/share/claude-pet/pokemon.json"
base=https://raw.githubusercontent.com/rh-hideout/pokeemerald-expansion/master/graphics/pokemon
mkdir -p "$dir"

catalog_tmp=$(mktemp)
names_tmp=$(mktemp)
jobs_tmp=$(mktemp)
trap 'rm -f "$catalog_tmp" "$names_tmp" "$jobs_tmp"' EXIT
curl -fsSL 'https://pokeapi.co/api/v2/pokemon-species?limit=649&offset=0' -o "$catalog_tmp"
mv "$catalog_tmp" "$catalog"

/usr/bin/swift -e '
import Foundation
struct Response: Decodable {
    struct Entry: Decodable { let name: String }
    let results: [Entry]
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let response = try JSONDecoder().decode(Response.self, from: data)
for pokemon in response.results.prefix(649) { print(pokemon.name) }
' "$catalog" > "$names_tmp"

while IFS= read -r name; do
  asset=${name//-/_}
  [[ -s "$dir/$asset.png" ]] && continue
  printf '%s\n%s\n' "$base/$asset/overworld.png" "$dir/$asset.png" >> "$jobs_tmp"
done < "$names_tmp"

if [[ -s "$jobs_tmp" ]]; then
  echo "Downloading $(($(wc -l < "$jobs_tmp") / 2)) Pokémon sprite sheets..."
  xargs -P 12 -n 2 /bin/sh -c '
    url=$1
    output=$2
    partial="${output}.part"
    if curl -fsSL "$url" -o "$partial"; then
      mv "$partial" "$output"
    else
      rm -f "$partial"
      echo "missing: $(basename "$output" .png)" >&2
    fi
  ' _ < "$jobs_tmp"
fi

# FireRed's overworld item ball, where pets rest after 12 hours unused.
[[ -s "$dir/_pokeball.png" ]] || curl -fsSL \
  https://raw.githubusercontent.com/pret/pokefirered/master/graphics/object_events/pics/misc/item_ball.png \
  -o "$dir/_pokeball.png"

missing=0
while IFS= read -r name; do
  asset=${name//-/_}
  if [[ ! -s "$dir/$asset.png" ]]; then
    echo "missing: $name" >&2
    ((missing += 1))
  fi
done < "$names_tmp"
[[ "$missing" -eq 0 ]] || { echo "$missing Pokémon sprites could not be downloaded." >&2; exit 1; }
echo "649 Gen I to V sprite sheets ready in $dir"
