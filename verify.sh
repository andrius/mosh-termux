#!/usr/bin/env bash
# Prove what mosh-client emits to the local terminal when a crossterm-style
# application asks for mouse reporting. Run this ON the device, from a real
# Termux session (script(1) needs a pty with a nonzero size).
#
#   bash verify.sh                    # test the installed mosh-client
#   bash verify.sh /path/to/binary    # test a freshly built one
#
set -euo pipefail
export TERM=${TERM:-xterm-256color}
CLIENT=${1:-mosh-client}

# Exactly what crossterm EnableMouseCapture writes (zellij, gitui, bottom, ...).
burst="\033[?1000h\033[?1002h\033[?1003h\033[?1015h\033[?1006h"

info=$(mosh-server new -i 127.0.0.1 -c 200 -- sh -c "printf '${burst}'; sleep 4" 2>&1)
port=$(awk "/MOSH CONNECT/{print \$3}" <<<"$info")
key=$(awk  "/MOSH CONNECT/{print \$4}" <<<"$info")
# Redact the session key: this output is what people paste into bug reports,
# and the key is live for as long as the server waits for a connection.
[ -n "$port" ] || {
    echo "mosh-server did not start:"
    sed "s/\(MOSH CONNECT [0-9]*\).*/\1 <key redacted>/" <<<"$info"
    exit 1
}

cap=$(mktemp)
MOSH_KEY="$key" script -q -c "$CLIENT 127.0.0.1 $port" "$cap" >/dev/null 2>&1
emitted=$(cat -v "$cap" | grep -o "\^\[\[?\(9\|100[0-9]\|101[0-5]\)h" | tr "\n" " ")
rm -f "$cap"

echo "client       : $CLIENT"
echo "app asked for: 1000h 1002h 1003h 1015h 1006h"
echo "client emits : ${emitted:-<nothing>}"
echo

# Termux implements 1000, 1002 and 1006; it silently drops 9, 1001, 1003, 1005
# and 1015. So a mode Termux understands has to be in there.
if grep -q "1002h" <<<"$emitted" || grep -q "1000h" <<<"$emitted"; then
    echo "PASS - a mode Termux implements is enabled, mouse reporting works"
else
    echo "FAIL - only modes Termux ignores were sent, mouse stays dead"
    exit 1
fi
