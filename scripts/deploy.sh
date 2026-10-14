#!/usr/bin/env bash
# Developer deploy: runs the tests, then copies Lexi to a Kindle over SSH, including your
# lexi.koplugin/config.lua if you have one. Users install from the release zip instead.
#
# SSH: KOReader → Network → SSH server (port 2222). WITH_DEV_SSH=1 also installs the
# "Lexi dev: Wi-Fi SSH" library item, which starts that same server while KOReader is closed (see
# docs/development.md).
# Usage: KINDLE_HOST=192.168.1.50 [KINDLE_PORT=2222] [WITH_DEV_SSH=1] scripts/deploy.sh
set -euo pipefail

host="${KINDLE_HOST:?Set KINDLE_HOST to the Kindle IP address (shown when the SSH server starts)}"
port="${KINDLE_PORT:-2222}"
root="$(cd "$(dirname "$0")/.." && pwd)"

luajit "$root/tests/run.lua"

on_kindle() { ssh -p "$port" "root@$host" "$@"; }
# ustar, root ownership and no macOS metadata keep busybox tar on the Kindle happy.
pack() { COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --numeric-owner --exclude .DS_Store "$@"; }

pack -C "$root" -cf - lexi.koplugin \
    | on_kindle "mkdir -p /mnt/us/koreader/plugins && tar -C /mnt/us/koreader/plugins -xf -"
pack -C "$root/scriptlets" -cf - . \
    | on_kindle "tar -C /mnt/us/documents -xf -"
if [ "${WITH_DEV_SSH:-0}" = 1 ]; then
    pack -C "$root/dev" -cf - lexi-dev-ssh.sh | on_kindle "tar -C /mnt/us/documents -xf -"
fi
# Pick up new code in the Kindle-reader bridge if it is running.
lexi=/mnt/us/koreader/plugins/lexi.koplugin/native/lexi.sh
on_kindle "if [ -f /var/run/lexi/pids ]; then sh $lexi stop > /dev/null; sh $lexi start > /dev/null; fi"

echo "Deployed to $host. Restart KOReader to load plugin changes (menu → Exit → Restart KOReader)."
