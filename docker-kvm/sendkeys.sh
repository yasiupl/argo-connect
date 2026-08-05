#!/bin/sh
# Send keystrokes to the remote console.
#
#   /sendkeys.sh F1                  # one key
#   /sendkeys.sh ctrl+alt+Delete     # chord
#   /sendkeys.sh Return space        # several, in order
#   /sendkeys.sh --type "root"       # literal text instead of key names
#
# Key names are xdotool's (F1, Return, space, Escape, ctrl+r, …).
#
# The click is the important part: activating the JViewer window is NOT enough — without a click
# inside the video area the applet never receives synthetic key events, and it fails *silently*
# (screen simply doesn't change). This cost real debugging time, so it's baked in here.
set -e

export DISPLAY=:0

WID=$(xdotool search --name JViewer 2>/dev/null | head -1)
if [ -z "$WID" ]; then
    echo "ERROR: no JViewer window found — is the console still connected?" >&2
    exit 1
fi

# Click into the video area. Coordinates are inside the console region at the default window size;
# override with CLICK_X/CLICK_Y if the layout differs.
xdotool windowactivate --sync "$WID" 2>/dev/null || true
xdotool mousemove "${CLICK_X:-375}" "${CLICK_Y:-230}" click 1
sleep "${CLICK_SETTLE:-3}"

if [ "$1" = "--type" ]; then
    shift
    xdotool type --clearmodifiers -- "$*"
else
    for k in "$@"; do
        xdotool key --clearmodifiers "$k"
        sleep 0.3
    done
fi

echo "sent: $*" >&2
