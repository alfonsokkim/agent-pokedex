#!/bin/zsh
# Downloads Gen 3-style walking sheets for National Pokédex numbers 1 through
# 649 from pokeemerald-expansion's follower sprites. Personal use only.
# Each sheet is one row of square frames: down ×2, up ×2, side ×2 (facing left).
# They go where the app looks for them, wherever this repo is cloned.
set -e
dir="$HOME/.local/share/claude-pet/sprites"
catalog="$HOME/.local/share/claude-pet/pokemon.json"
base=https://raw.githubusercontent.com/rh-hideout/pokeemerald-expansion/master/graphics/pokemon
front_base=https://raw.githubusercontent.com/PMDCollab/SpriteCollab/e56caec3fda47cbd4b9d2177b3d1bc05f0ff7dc7/sprite
mkdir -p "$dir"
mkdir -p "$dir/palettes" "$dir/front"

catalog_tmp=$(mktemp)
names_tmp=$(mktemp)
jobs_tmp=$(mktemp)
trap 'rm -f "$catalog_tmp" "$names_tmp" "$jobs_tmp"' EXIT
curl -fsSL 'https://pokeapi.co/api/v2/pokemon-species?limit=649&offset=0' -o "$catalog_tmp"
mv "$catalog_tmp" "$catalog"

/usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation");
function run(args) {
  var text = $.NSString.stringWithContentsOfFileEncodingError(args[0], $.NSUTF8StringEncoding, null);
  if (!text) throw new Error("Cannot read Pokémon catalog");
  var catalog = JSON.parse(ObjC.unwrap(text));
  if (!Array.isArray(catalog.results) || catalog.results.length < 649) {
    throw new Error("Pokémon catalog must contain all 649 species");
  }
  return catalog.results.slice(0, 649).map(function (entry) {
    if (typeof entry.name !== "string" || !/^[a-z0-9-]+$/.test(entry.name)) {
      throw new Error("Invalid Pokémon name in catalog");
    }
    return entry.name;
  }).join("\n");
}
' "$catalog" > "$names_tmp"

while IFS= read -r name; do
  asset=${name//-/_}
  if [[ ! -s "$dir/$asset.png" ]]; then
    printf '%s\n%s\n' "$base/$asset/overworld.png" "$dir/$asset.png" >> "$jobs_tmp"
  fi
  for variant in normal shiny; do
    if [[ ! -s "$dir/palettes/${asset}_${variant}.pal" ]]; then
      printf '%s\n%s\n' "$base/$asset/overworld_${variant}.pal" "$dir/palettes/${asset}_${variant}.pal" >> "$jobs_tmp"
    fi
  done
done < "$names_tmp"

for pair in charmander:0004 squirtle:0007; do
  name=${pair%%:*}
  number=${pair#*:}
  for variant in normal shiny; do
    source="$front_base/$number"
    [[ "$variant" == shiny ]] && source="$source/0000/0001"
    if [[ ! -s "$dir/front/${name}_${variant}.png" ]]; then
      printf '%s\n%s\n' "$source/Walk-Anim.png" "$dir/front/${name}_${variant}.png" >> "$jobs_tmp"
    fi
  done
done

if [[ -s "$jobs_tmp" ]]; then
  echo "Downloading $(($(wc -l < "$jobs_tmp") / 2)) Pokémon sheets and palettes..."
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
  for variant in normal shiny; do
    if [[ ! -s "$dir/palettes/${asset}_${variant}.pal" ]]; then
      echo "missing: $name $variant palette" >&2
      ((missing += 1))
    fi
  done
done < "$names_tmp"
for name in charmander squirtle; do
  for variant in normal shiny; do
    if [[ ! -s "$dir/front/${name}_${variant}.png" ]]; then
      echo "missing: $name $variant front sprite" >&2
      ((missing += 1))
    fi
  done
done
[[ "$missing" -eq 0 ]] || { echo "$missing Pokémon sprites could not be downloaded." >&2; exit 1; }
echo "649 Gen I to V sprite sheets with normal and shiny palettes ready in $dir"
