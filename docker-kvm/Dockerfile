# Containerised iDRAC6 Java KVM, served over HTML5/noVNC.
#
# Why not domistyle/idrac6? That image targets *Avocent*-based iDRAC6, which serves the applet at
# /software/avctKVM.jar. The Argo chassis runs the *AMI* variant (reportedly a patched iDRAC5),
# which 404s that path and instead serves /Applications/dellUI/Java/release/JViewer.jar — the
# stack that ../bootleg-idrac6-client already handles. So we containerise that client instead.
#
# The point is to get the KVM off the host: the applet needs Java + an X display, which doesn't
# work under WSL (black, non-interactive screen). Here Java and X live in the container and you
# get a browser-based console on :5800.
#
# baseimage-gui supplies Xvfb + x11vnc + noVNC + supervisor and launches /startapp.sh.
FROM jlesage/baseimage-gui:debian-11-v4

# baseimage-gui ships with NO /etc/passwd or /etc/group (it generates them at runtime), so any
# package whose postinst chowns — e.g. fontconfig-config, pulled in by every JRE — dies with
# "chown: invalid user: 'root:staff'". Provide the minimum needed at build time.
RUN printf 'root:x:0:0:root:/root:/bin/sh\n' > /etc/passwd && \
    printf 'root:x:0:\nstaff:x:50:\n' > /etc/group

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openjdk-11-jre \
        curl \
        wget \
        unzip \
        ca-certificates \
        procps \
        `# automation tooling — baked in rather than add-pkg'd at runtime so screenshot/sendkeys` \
        `# work offline, instantly, and reproducibly` \
        x11-apps \
        netpbm \
        xdotool && \
    rm -rf /var/lib/apt/lists/*

# The iDRAC's KVM video channel speaks ancient TLS (TLSv1 + 3DES-class ciphers). Modern JREs
# refuse it outright — the applet authenticates fine over HTTPS, then dies with
# "SSLHandshakeException: Received fatal alert: handshake_failure" the moment it opens the video
# stream. Clear the disabled-algorithm blocklists so the old protocols are allowed again.
# This is deliberately insecure crypto, acceptable only because it's confined to this container
# talking to a 2009 BMC over an SSH tunnel on an isolated management network.
RUN JS=$(find /usr/lib/jvm -name java.security -path '*/conf/security/*' | head -1) && \
    echo "patching $JS" && \
    sed -i 's/^jdk.tls.disabledAlgorithms=.*/jdk.tls.disabledAlgorithms=/' "$JS" && \
    sed -i 's/^jdk.certpath.disabledAlgorithms=.*/jdk.certpath.disabledAlgorithms=/' "$JS" && \
    sed -i '/^ *\(SSLv3\|TLSv1\|TLSv1\.1\|RC4\|DES\|MD5withRSA\|DH keySize\|3DES\|EC keySize\|anon\|NULL\|include\)/d' "$JS"

COPY startapp.sh /startapp.sh
COPY screenshot.sh /screenshot.sh
COPY sendkeys.sh /sendkeys.sh
RUN chmod +x /startapp.sh /screenshot.sh /sendkeys.sh

ENV APP_NAME="iDRAC6 KVM"
# Where downloaded jars are cached; mount a volume here to skip re-downloading on restart.
ENV KVM_WORKDIR=/app
# baseimage-gui runs the app as an unprivileged user (USER_ID, default 1000), so these must be
# writable by it — otherwise the jar download fails with "mkdir: cannot create directory
# '/app/lib': Permission denied" unless the caller happens to bind-mount a host dir over /app.
RUN mkdir -p /app /screenshots && chmod 777 /app /screenshots

EXPOSE 5800 5900
VOLUME ["/app", "/screenshots"]
