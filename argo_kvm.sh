#!/usr/bin/env bash
# Manage containerised iDRAC6 KVM consoles (see docker-kvm/).
#
#   ./argo_kvm.sh proxy start|stop|status       the shared SOCKS proxy (tunnel mode only)
#   ./argo_kvm.sh <blade> start                 bring up a console, print its URL
#   ./argo_kvm.sh <blade> stop                  tear down that console
#   ./argo_kvm.sh <blade> url|logs              URL / container logs
#   ./argo_kvm.sh <blade> screenshot [out.png]  capture console to a PNG on this host
#   ./argo_kvm.sh <blade> keys <key>...         send keystrokes (xdotool names, e.g. F1)
#   ./argo_kvm.sh <blade> type <text>           type literal text
#   ./argo_kvm.sh list                          show running consoles
#   ./argo_kvm.sh stop-all                      tear down every console + the proxy
#
# ── Connection modes ────────────────────────────────────────────────────────────────────────────
#
# TUNNEL (default) — ONE `ssh -D` SOCKS5 proxy to $JUMPHOST serves every blade. Because SOCKS
#   proxies arbitrary host:port pairs, there are no per-blade local port forwards and therefore no
#   collisions: run all 16 consoles over a single SSH connection. Start it once with
#   `./argo_kvm.sh proxy start` (or let `<blade> start` bring it up on demand).
#
#   This replaces an earlier design using five `-L` forwards per blade, which pinned the iDRAC's
#   fixed KVM ports (5900/5901/3668/3669) to the same local ports and so allowed only one blade at
#   a time.
#
# DIRECT (ARGO_DIRECT=1) — no proxy at all; containers dial 192.168.0.10<N> straight. Use when
#   running on a host *inside* the CMC management network (Pi, mini-PC, or a management blade).
#
# ⚠️ argo_connect.sh kills every ssh matching $JUMPHOST when it starts, which will kill the SOCKS
#    proxy. Don't interleave them (argo_console_probe.sh shows how to sequence around it).
#
# Env: JUMPHOST, IDENTITY_FILE, IDRAC_USER, IDRAC_PASSWORD, ARGO_DIRECT, SOCKS_PORT (default 1080),
#      DOCKER (set to 'sg docker -c' if your user isn't in the docker group yet).
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
IMAGE=${ARGO_KVM_IMAGE:-argo-kvm}

jumphost=${JUMPHOST:-argo@argo}
identity_file=${IDENTITY_FILE:-$SCRIPT_DIR/argo.private}
IDRAC_USER=${IDRAC_USER:-root}
IDRAC_PASSWORD=${IDRAC_PASSWORD:-calvin}
DIRECT=${ARGO_DIRECT:-0}
SOCKS_PORT=${SOCKS_PORT:-1080}
PROXY_PID=/tmp/argo-kvm-socks.pid

# `sg docker -c` needs the whole command as one string, so build it that way when DOCKER is set.
d() {
    if [ -n "${DOCKER:-}" ]; then
        $DOCKER "docker $(printf '%q ' "$@")"
    else
        docker "$@"
    fi
}

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

proxy_running() { [ -f "$PROXY_PID" ] && kill -0 "$(cat "$PROXY_PID")" 2>/dev/null; }

proxy_start() {
    proxy_running && { echo "SOCKS proxy already up on :$SOCKS_PORT (pid $(cat "$PROXY_PID"))"; return 0; }
    echo "starting SOCKS proxy on :$SOCKS_PORT via $jumphost"
    # Bound to 0.0.0.0 so containers can reach it via host.docker.internal.
    # stdio MUST be detached: a backgrounded ssh inherits this script's stdout, so if the caller
    # pipes us (`argo_kvm.sh 14 start | tail`), the long-lived proxy holds the pipe open and the
    # reader hangs forever even though the script finished. Also disown so it survives us.
    ssh -i "$identity_file" -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -N \
        -D "0.0.0.0:$SOCKS_PORT" "$jumphost" </dev/null >/dev/null 2>&1 &
    echo $! > "$PROXY_PID"
    disown %% 2>/dev/null || true
    sleep 5
    proxy_running || { echo "ERROR: proxy died — port $SOCKS_PORT in use, or jumphost unreachable" >&2; rm -f "$PROXY_PID"; exit 1; }
    echo "proxy up (pid $(cat "$PROXY_PID"))"
}

proxy_stop() {
    proxy_running && kill "$(cat "$PROXY_PID")" 2>/dev/null || true
    rm -f "$PROXY_PID"
    echo "SOCKS proxy stopped"
}

[ $# -ge 1 ] || usage

case "$1" in
    list)
        d ps --filter "name=argo-kvm" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
        exit 0 ;;
    stop-all)
        for c in $(d ps -aq --filter "name=argo-kvm"); do d rm -f "$c" >/dev/null; done
        proxy_stop
        echo "all consoles stopped"
        exit 0 ;;
    proxy)
        case "${2:-status}" in
            start)  proxy_start ;;
            stop)   proxy_stop ;;
            status) proxy_running && echo "up on :$SOCKS_PORT (pid $(cat "$PROXY_PID"))" || echo "down" ;;
            *)      usage ;;
        esac
        exit 0 ;;
esac

BLADE=$1; shift
ACTION=${1:-start}; shift || true

case "$BLADE" in ''|*[!0-9]*) echo "ERROR: blade must be 1-16" >&2; exit 1 ;; esac
[ "$BLADE" -ge 1 ] && [ "$BLADE" -le 16 ] || { echo "ERROR: blade must be 1-16" >&2; exit 1; }

IDRAC_IP="192.168.0.$((100 + BLADE))"
NAME="argo-kvm$BLADE"
WEB_PORT=$((5800 + BLADE))   # one web port per blade so all 16 can coexist

case "$ACTION" in
start)
    d rm -f "$NAME" >/dev/null 2>&1 || true

    run_args=( -d --name "$NAME" -p "$WEB_PORT:5800"
               -e IDRAC_HOST="$IDRAC_IP:443"
               -e IDRAC_USER="$IDRAC_USER"
               -e IDRAC_PASSWORD="$IDRAC_PASSWORD" )

    if [ "$DIRECT" = "1" ]; then
        echo "direct mode -> $IDRAC_IP"
    else
        proxy_start
        run_args+=( --add-host=host.docker.internal:host-gateway
                    -e SOCKS_PROXY="host.docker.internal:$SOCKS_PORT" )
    fi

    d run "${run_args[@]}" "$IMAGE" >/dev/null

    echo -n "waiting for console"
    for _ in $(seq 40); do
        sleep 3; echo -n "."
        if d logs "$NAME" 2>&1 | grep -q "Starting JViewer"; then
            echo " ok"
            echo "console: http://localhost:$WEB_PORT"
            exit 0
        fi
        if ! d ps --filter "name=$NAME" --format '{{.Names}}' | grep -q "$NAME"; then
            echo " FAILED"
            d logs "$NAME" 2>&1 | grep -E "^\[app" | tail -10
            exit 1
        fi
    done
    echo " timed out (container still up — check '$0 $BLADE logs')"
    ;;

stop)
    d rm -f "$NAME" >/dev/null 2>&1 || true
    echo "stopped blade$BLADE console (proxy left up; './argo_kvm.sh proxy stop' to close)"
    ;;

url)  echo "http://localhost:$WEB_PORT" ;;
logs) d logs "$NAME" 2>&1 | grep -E "^\[app" || d logs "$NAME" ;;

screenshot)
    OUT=${1:-console-blade$BLADE.png}
    d exec "$NAME" /screenshot.sh - > "$OUT"
    echo "$OUT" ;;

keys)
    [ $# -ge 1 ] || { echo "ERROR: give at least one key, e.g. F1" >&2; exit 1; }
    d exec "$NAME" /sendkeys.sh "$@" ;;

type)
    [ $# -ge 1 ] || { echo "ERROR: give text to type" >&2; exit 1; }
    d exec "$NAME" /sendkeys.sh --type "$*" ;;

*) usage ;;
esac
