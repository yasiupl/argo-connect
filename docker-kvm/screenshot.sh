#!/bin/sh
# Capture the console to PNG. Writes to $1 (default /screenshots/console.png) and also streams the
# PNG to stdout when given "-", so both of these work:
#
#   docker exec <container> /screenshot.sh                 # -> /screenshots/console.png in container
#   docker exec <container> /screenshot.sh - > shot.png    # -> straight to a file on the host
set -e

OUT=${1:-/screenshots/console.png}
TMP=$(mktemp /tmp/shot-XXXXXX.png)

DISPLAY=:0 xwd -root -silent | xwdtopnm 2>/dev/null | pnmtopng > "$TMP"

if [ "$OUT" = "-" ]; then
    cat "$TMP"
    rm -f "$TMP"
else
    mkdir -p "$(dirname "$OUT")"
    mv "$TMP" "$OUT"
    echo "$OUT" >&2
fi
