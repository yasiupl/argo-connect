#!/usr/bin/env bash
# Read-only survey of a blade: power it on, watch the console, capture screenshots, power it back
# off. Answers "what is actually on this blade?" — which racadm alone CANNOT tell you (a blank
# iDRAC Host Name does not mean an empty disk; see ../CLAUDE.md).
#
# NEVER writes to the blade's disks. It only changes power state, and restores it at the end.
#
#   ./argo_console_probe.sh <blade-number> [seconds-to-watch]
#
# Env: same overrides as argo_connect.sh (JUMPHOST, IDENTITY_FILE, IDRAC_USER, IDRAC_PASSWORD),
#      plus OUTDIR (default ./probe-blade<N>).
#
# Requires the argo-kvm image: (cd docker-kvm && docker build -t argo-kvm .)
#
# IMPORTANT ORDERING CONSTRAINT: argo_connect.sh kills every ssh process matching $JUMPHOST when
# it starts (it doesn't support parallel iDRAC proxies). That would tear down our KVM tunnel. So
# this script does ALL racadm work either strictly before the tunnel opens or strictly after it
# closes — never while the console session is live.
set -euo pipefail

BLADE=${1:?usage: argo_console_probe.sh <blade-number> [watch-seconds]}
WATCH=${2:-240}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

jumphost=${JUMPHOST:-argo@argo}
identity_file=${IDENTITY_FILE:-$SCRIPT_DIR/argo.private}
IDRAC_USER=${IDRAC_USER:-root}
IDRAC_PASSWORD=${IDRAC_PASSWORD:-calvin}
IDRAC_IP="192.168.0.$((100 + BLADE))"
OUTDIR=${OUTDIR:-./probe-blade$BLADE}
CONTAINER="argo-kvm-probe$BLADE"

mkdir -p "$OUTDIR"
echo "== probing blade$BLADE ($IDRAC_IP), watching ${WATCH}s, output -> $OUTDIR"

# Strips argo_connect.sh's own chatter so callers get just the racadm output.
racadm() {
    "$SCRIPT_DIR/argo_connect.sh" "$BLADE" ssh "racadm $*" 2>&1 \
        | grep -vaE "^(Connecting to|Started proxy|Starting SSH|Killed proxy|Warning: Permanently|.?DS 2 PG)" \
        | sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/^.*Welcome to the iDRAC firmware version [0-9.]*//' \
        || true
}

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    [ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null || true
}
trap cleanup EXIT

########## phase 1: racadm only (no tunnel yet) ##########
echo "== pre-flight"
racadm getsysinfo > "$OUTDIR/sysinfo-before.txt"
grep -E "System Model|Service Tag|Host Name|OS Name|Power Status" "$OUTDIR/sysinfo-before.txt" || true
racadm getsel > "$OUTDIR/sel-before.txt"
echo "SEL records: $(grep -cE '^Record' "$OUTDIR/sel-before.txt" || echo 0)"

WAS_ON=no
grep -qE "Power Status *= *ON" "$OUTDIR/sysinfo-before.txt" && WAS_ON=yes
echo "was powered on: $WAS_ON"

if [ "$WAS_ON" = no ]; then
    echo "== powering on"
    racadm serveraction powerup | grep -E "successful|ERROR" || true
else
    echo "== already ON — leaving power alone, will not power it down either"
fi

########## phase 2: console only (no racadm from here) ##########
echo "== opening KVM tunnel"
ssh -i "$identity_file" -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -N \
    -L "0.0.0.0:8443:$IDRAC_IP:443" \
    -L "0.0.0.0:5900:$IDRAC_IP:5900" \
    -L "0.0.0.0:5901:$IDRAC_IP:5901" \
    -L "0.0.0.0:3668:$IDRAC_IP:3668" \
    -L "0.0.0.0:3669:$IDRAC_IP:3669" \
    "$jumphost" &
TUNNEL_PID=$!
sleep 6

echo "== starting KVM container"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
    --add-host=host.docker.internal:host-gateway \
    -e IDRAC_HOST=host.docker.internal:8443 \
    -e IDRAC_USER="$IDRAC_USER" \
    -e IDRAC_PASSWORD="$IDRAC_PASSWORD" \
    argo-kvm >/dev/null
sleep 25
docker logs "$CONTAINER" 2>&1 | grep -E "Session cookie|ERROR" | head -3 || true
docker exec "$CONTAINER" /opt/base/bin/add-pkg x11-apps netpbm >/dev/null 2>&1 || true

echo "== capturing console every 30s for ${WATCH}s"
n=0
end=$((SECONDS + WATCH))
while [ $SECONDS -lt $end ]; do
    n=$((n + 1))
    sleep 30
    if docker exec "$CONTAINER" sh -c \
        'DISPLAY=:0 xwd -root -silent 2>/dev/null | xwdtopnm 2>/dev/null | pnmtopng > /tmp/shot.png 2>/dev/null'; then
        docker cp "$CONTAINER:/tmp/shot.png" "$OUTDIR/console-$(printf %02d "$n").png" 2>/dev/null \
            && echo "   console-$(printf %02d "$n").png"
    fi
done

echo "== closing console session"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
kill "$TUNNEL_PID" 2>/dev/null || true
TUNNEL_PID=""
sleep 3

########## phase 3: racadm again (tunnel is down) ##########
echo "== post-flight"
racadm getsel > "$OUTDIR/sel-after.txt"
BEFORE=$(grep -cE '^Record' "$OUTDIR/sel-before.txt" || echo 0)
AFTER=$(grep -cE '^Record' "$OUTDIR/sel-after.txt" || echo 0)
echo "SEL records: $BEFORE -> $AFTER"
[ "$BEFORE" = "$AFTER" ] \
    || echo "!! SEL GREW during probe — new hardware faults, see $OUTDIR/sel-after.txt"

if [ "$WAS_ON" = no ]; then
    echo "== restoring power state (off)"
    racadm serveraction powerdown | grep -E "successful|ERROR" || true
fi

echo "== done. Review $OUTDIR/console-*.png"
