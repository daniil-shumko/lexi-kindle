#!/bin/sh
# Lexi's actions on the Kindle, used by the library scriptlets (documents/lexi-*.sh).
#
# "Ask AI" in the Kindle's own reader runs native/lexid.lua with KOReader's LuaJIT, fed through a
# FIFO with the reader's window events from the system log and the events of Lexi's window
# (native/ui.lua, which lexid starts). Settings and phone setup go through native/cli.lua.
# Nothing here survives a reboot.
#
# Usage: lexi.sh start | stop | toggle | status | setup
# With LEXI_UI=dialog (scriptlets) results show in Lexi's window, otherwise on the bottom line.

RUN=/var/run/lexi
KOREADER=/mnt/us/koreader
PLUGIN=plugins/lexi.koplugin
LOG=/var/tmp/lexi.log

# Last line of native/cli.lua's output (KOReader's loader may log before it).
cli() {
    (cd "$KOREADER" && ./luajit "$PLUGIN/native/cli.lua" "$@" 2> /dev/null | tail -n 1)
}

# Shows a one-line result and logs it. From a scriptlet: in Lexi's window, which closes itself. From
# a shell: near the bottom of the screen with firmware eips (ASCII only).
say() {
    msg=$(printf '%s' "$1" | sed 's/·/-/g; s/…/.../g; s/✓/OK/g' | cut -c 1-60)
    logger -t lexi "$msg"
    echo "$msg"
    if [ "$LEXI_UI" = dialog ]; then
        (cd "$KOREADER" && setsid ./luajit "$PLUGIN/native/ui.lua" notice "$1" > /dev/null 2>> "$LOG" &)
        return
    fi
    info=$(eips -i 2> /dev/null)
    xres=$(printf '%s\n' "$info" | sed -n 's/.*xres: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
    yres=$(printf '%s\n' "$info" | sed -n 's/.*yres: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
    xres=${xres:-1272}
    yres=${yres:-1696}
    if command -v eips_v2 > /dev/null 2>&1; then
        # eips only draws glyphs: blank the band first so a shorter message doesn't keep the old tail.
        y=$((yres - 112))
        eips_v2 rect "#FF" -x 0 -y "$y" -w "$xres" -h 72 -n > /dev/null 2>&1
        eips_v2 text -n -x 36 -y $((y + 12)) "$msg" > /dev/null 2>&1
        eips_v2 update -x 0 -y "$y" -w "$xres" -h 72 > /dev/null 2>&1
    else
        eips 2 $((yres / 24 - 4)) "$(printf '%-60s' "$msg")" > /dev/null 2>&1
    fi
}

running() {
    [ -f "$RUN/pids" ] && kill -0 "$(head -n 1 "$RUN/pids")" 2> /dev/null
}

# Stops a process from one of our PID files, with its process group (it was started with setsid:
# lexid takes its window along, the syslog reader its tail), but only if it still runs one of our
# programs: after a crash, the number may belong to something else by now.
kill_ours() {
    tr '\0' ' ' < "/proc/$1/cmdline" 2> /dev/null | grep -q -E 'lexid\.lua|cli\.lua setup|tail -n 0 -F' \
        && { kill -TERM "-$1" 2> /dev/null || kill "$1" 2> /dev/null; }
}

start() {
    if running; then
        say "Ask AI in Kindle reader is already on"
        return 0
    fi
    rm -rf "$RUN"
    mkdir -p "$RUN" && mkfifo "$RUN/events" || return 1
    # setsid: the scriptlet launcher must not take these down when the action ends. lexid's PID goes
    # first ("running" checks it).
    (
        cd "$KOREADER" || exit 1
        # lexid writes to its window through a pipe: if the window dies, the failed write tells
        # lexid to start a new one instead of SIGPIPE killing it.
        (trap '' PIPE && LEXI_EVENTS="$RUN/events" exec setsid ./luajit "$PLUGIN/native/lexid.lua") \
            < "$RUN/events" > "$LOG" 2>&1 &
        echo $! > "$RUN/pids"
        # Only the readers' popup lines go through (see Native.parseSyslog): the FIFO stays quiet while
        # lexid waits for the AI.
        setsid sh -c 'tail -n 0 -F /var/log/messages 2> /dev/null | awk "/KindleFrameFactory:Window|selectionStabilized, selectionMode|selectionFinalized called/ { print; fflush() }"' \
            > "$RUN/events" &
        echo $! >> "$RUN/pids"
    )
    say "Ask AI in Kindle reader: ON"
}

stop() {
    if [ -f "$RUN/pids" ]; then
        for pid in $(cat "$RUN/pids"); do kill_ours "$pid"; done
    fi
    rm -rf "$RUN"
    say "Ask AI in Kindle reader: OFF"
}

if [ ! -f "$KOREADER/$PLUGIN/native/lexid.lua" ]; then
    say "Lexi: install KOReader and the Lexi plugin first"
    exit 1
fi

case "$1" in
start) start ;;
stop) stop ;;
toggle) if running; then stop; else start; fi ;;
status)
    if running; then state=ON; else state=OFF; fi
    say "Ask AI $state · $(cli status)"
    ;;
setup)
    # An older setup that is still waiting would hold the port: replace it, and close the firewall
    # rule it can't remove itself once killed.
    if [ -f /var/run/lexi-setup.pid ]; then
        kill_ours "$(cat /var/run/lexi-setup.pid)"
        for port in 8642 8643 8644 8645 8646 8647 8648 8649 8650 8651; do
            iptables -D INPUT -i wlan0 -p tcp --dport "$port" -j ACCEPT 2> /dev/null
        done
    fi
    # Runs for up to 10 minutes while the phone page is open: don't keep the caller waiting. Its
    # window is the feedback. It writes to that window through a pipe: see start.
    (cd "$KOREADER" && trap '' PIPE && setsid ./luajit "$PLUGIN/native/cli.lua" setup > /dev/null 2>> "$LOG" &)
    [ "$LEXI_UI" = dialog ] || say "Opening phone setup..."
    ;;
*)
    echo "Usage: $0 start | stop | toggle | status | setup" >&2
    exit 1
    ;;
esac
