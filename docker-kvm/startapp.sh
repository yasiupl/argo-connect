#!/bin/sh
# Launch the AMI/JViewer iDRAC6 KVM applet. Logic mirrors ../bootleg-idrac6-client/kvm.sh, but
# non-interactive (all config via env) and pointed at a caching workdir.
#
# Required env: IDRAC_HOST (host:port), IDRAC_USER, IDRAC_PASSWORD
# Optional env: SOCKS_PROXY (host:port) — route everything through a SOCKS5 proxy instead of
#               reaching IDRAC_HOST directly. See below.
set -e

WORKDIR="${KVM_WORKDIR:-/app}"
URI="Applications/dellUI/Java/release"

# ── SOCKS mode ──────────────────────────────────────────────────────────────────────────────────
# A single `ssh -D <port> <jumphost>` gives one SOCKS5 proxy that can reach *every* iDRAC and
# *every* KVM port on the management network. That beats per-blade `-L` forwards, which pin the
# iDRAC's fixed KVM ports (5900/5901/3668/3669) to the same local ports and therefore allow only
# one blade at a time. With SOCKS, IDRAC_HOST is the iDRAC's real address and many containers can
# share one proxy.
#
# curl gets --socks5-hostname (proxy-side DNS); the JVM gets socksProxyHost/Port, which it applies
# to all TCP sockets — including JViewer's video/media channels.
CURL_PROXY=""
JAVA_PROXY=""
if [ -n "${SOCKS_PROXY:-}" ]; then
    echo "routing via SOCKS5 $SOCKS_PROXY"
    CURL_PROXY="--socks5-hostname $SOCKS_PROXY"
    JAVA_PROXY="-DsocksProxyHost=${SOCKS_PROXY%%:*} -DsocksProxyPort=${SOCKS_PROXY##*:}"
fi

if [ -z "$IDRAC_HOST" ] || [ -z "$IDRAC_USER" ] || [ -z "$IDRAC_PASSWORD" ]; then
    echo "ERROR: IDRAC_HOST, IDRAC_USER and IDRAC_PASSWORD must all be set" >&2
    exit 1
fi

mkdir -p "$WORKDIR/lib"
cd "$WORKDIR"

download() {
    jar=$1; path=$2
    if [ ! -f "${path}/${jar}" ]; then
        echo "Downloading https://${IDRAC_HOST}/${URI}/${jar}"
        # shellcheck disable=SC2086 # CURL_PROXY is an intentional word-split flag list
        if ! curl -sk --max-time 120 $CURL_PROXY -o "${path}/${jar}" \
                "https://${IDRAC_HOST}/${URI}/${jar}"; then
            echo "ERROR: failed to download ${jar} from ${IDRAC_HOST}" >&2
            rm -f "${path}/${jar}"
            exit 2
        fi
    fi
}

echo "Obtaining session cookie from ${IDRAC_HOST}"
# shellcheck disable=SC2086
response=$(curl -sk --max-time 30 $CURL_PROXY \
    --data "WEBVAR_USERNAME=${IDRAC_USER}&WEBVAR_PASSWORD=${IDRAC_PASSWORD}&WEBVAR_ISCMCLOGIN=0" \
    "https://${IDRAC_HOST}/Applications/dellUI/RPC/WEBSES/create.asp")

COOKIE=$(echo "$response" | sed -n "s/.*'SESSION_COOKIE' : '\([^']*\)'.*/\1/p")
if [ -z "$COOKIE" ]; then
    echo "ERROR: no session cookie returned. Response was:" >&2
    echo "$response" >&2
    exit 1
fi
# The iDRAC returns failures *in the cookie field* rather than as an HTTP error. The big one is
# Failure_No_Free_Slot: it only has a handful of session slots and scripted logins don't release
# them promptly, so repeated runs lock you out (of SSH too, eventually). Recover by resetting the
# management controller from the CMC: `racadm racreset -m server-<n>` — host keeps running.
case "$COOKIE" in
    Failure*)
        echo "ERROR: iDRAC login failed: $COOKIE" >&2
        if [ "$COOKIE" = "Failure_No_Free_Slot" ]; then
            echo "       Session slots exhausted. From the CMC, run:" >&2
            echo "         racadm racreset -m server-<n>" >&2
            echo "       (resets only that blade's iDRAC; the host is unaffected)" >&2
        fi
        exit 1
        ;;
esac
echo "Session cookie: $COOKIE"

download JViewer.jar .
download Linux_x86_64.jar lib

echo "Extracting native libs"
(cd lib && jar -xf Linux_x86_64.jar 2>/dev/null || unzip -o -q Linux_x86_64.jar)

echo "Fetching KVM launch parameters"
# shellcheck disable=SC2086
args=$(curl -sk --max-time 30 $CURL_PROXY --cookie "Cookie=SessionCookie=${COOKIE}" \
    "https://${IDRAC_HOST}/Applications/dellUI/Java/jviewer.jnlp" \
    | awk -F '[<>]' '/argument/ { print $3 }')

if [ -z "$args" ]; then
    echo "ERROR: could not obtain KVM launch parameters from jviewer.jnlp" >&2
    exit 1
fi
echo "Launch args: $args"

echo "Starting JViewer"
# The TLS opts pair with the java.security patch in the Dockerfile — both are needed to talk to
# the iDRAC's ancient KVM video channel.
# shellcheck disable=SC2086 # args/JAVA_PROXY are intentional word-split lists
exec java \
    -Djava.library.path=lib \
    -Djdk.tls.client.protocols=TLSv1,TLSv1.1,TLSv1.2 \
    -Dhttps.protocols=TLSv1,TLSv1.1,TLSv1.2 \
    $JAVA_PROXY \
    -jar JViewer.jar $args
