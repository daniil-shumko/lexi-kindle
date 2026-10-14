#!/bin/sh
# Name: Lexi dev: Wi-Fi SSH
# Author: Lexi
#
# Developer tool, not part of the Lexi release: scripts/deploy.sh puts it in documents/ with
# WITH_DEV_SSH=1. Tap it in the library to start KOReader's own SSH server without opening KOReader,
# e.g. to watch Ask AI in the Kindle's own reader. Same server, port, keys and firewall rules as
# KOReader → Network → SSH server, so `ssh -p 2222 root@<kindle>` works either way. Key-only:
# koreader/settings/SSH/authorized_keys. It runs until the Kindle restarts (or stop it from KOReader).
# Its output shows on screen through the scriptlet launcher's FBInk.

PORT=2222
# KOReader's SSH plugin uses this file too, so it sees this server as running.
PIDFILE=/tmp/dropbear_koreader.pid

# The library may run scriptlets as the framework user: dropbear needs root.
if [ "$(id -u)" != 0 ]; then
    exec /var/local/mkk/su -c "sh \"$0\""
fi

ip=$(ip -4 addr show wlan0 2> /dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n 1)

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2> /dev/null; then
    echo "Lexi dev: SSH already running on ${ip:-?}:$PORT"
    exit 0
fi

# Its patched dropbear reads settings/SSH/ relative to the KOReader folder.
cd /mnt/us/koreader || exit 1
if ! ./dropbear -E -R -s -p "$PORT" -P "$PIDFILE" 2> /dev/null; then
    echo "Lexi dev: SSH failed to start"
    exit 1
fi
iptables -C INPUT -p tcp --dport "$PORT" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2> /dev/null \
    || iptables -A INPUT -p tcp --dport "$PORT" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
iptables -C OUTPUT -p tcp --sport "$PORT" -m conntrack --ctstate ESTABLISHED -j ACCEPT 2> /dev/null \
    || iptables -A OUTPUT -p tcp --sport "$PORT" -m conntrack --ctstate ESTABLISHED -j ACCEPT
echo "Lexi dev: SSH on ${ip:-?}:$PORT"
