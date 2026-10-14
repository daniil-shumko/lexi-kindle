#!/usr/bin/env bash
# Builds dist/lexi-<version>.zip, laid out like the Kindle's USB drive so users can unzip it there:
#   koreader/plugins/lexi.koplugin/   the KOReader plugin, which also runs Ask AI in the Kindle reader
#   documents/lexi-*.sh               the library items (scriptlets)
# Never includes config.lua (API keys).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/.*version = "\(.*\)".*/\1/p' "$root/lexi.koplugin/_meta.lua")"
out="$root/dist/lexi-$version.zip"

luajit "$root/tests/run.lua"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/koreader/plugins"
# Only files git tracks or would track: ignored files (config.lua with API keys, backups of it,
# .DS_Store) never ship.
copy_tracked() { # <dir to list from> <path> <destination>
    (cd "$1" && git ls-files -z --cached --others --exclude-standard -- "$2" | xargs -0 tar -cf -) | tar -C "$3" -xf -
}
copy_tracked "$root" lexi.koplugin "$stage/koreader/plugins"
mkdir -p "$stage/documents"
copy_tracked "$root/scriptlets" . "$stage/documents"
cp "$root/LICENSE" "$stage/koreader/plugins/lexi.koplugin/LICENSE"
find "$stage" \( -name 'config.lua*' -o -name .DS_Store \) -delete
chmod +x "$stage/koreader/plugins/lexi.koplugin/native/lexi.sh" "$stage"/documents/*.sh

mkdir -p "$root/dist"
rm -f "$out"
(cd "$stage" && zip -qrX "$out" koreader documents)
echo "Built $out"
unzip -l "$out" | tail -n 1
