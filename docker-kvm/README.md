# docker-kvm — containerised iDRAC6 KVM console

Runs the Argo blades' Java KVM applet inside a container and serves it as a browser console
(HTML5/noVNC) on **http://localhost:5800**. Also supports pulling **screenshots
programmatically**, which makes the console usable for automation and debugging, not just
eyeballing.

This exists because the host-side KVM (`../argo_connect.sh <n> kvm`) needs Java + an X display on
the host, and doesn't work under WSL — it comes up black and non-interactive.

## Why not `domistyle/idrac6`?

[That project](https://github.com/DomiStyle/docker-idrac6) solves the same problem but targets
**Avocent**-based iDRAC6, which serves the applet at `/software/avctKVM.jar`. The Argo chassis runs
the **AMI** variant (reportedly a patched iDRAC5), where that path 404s and the applet instead
lives at `/Applications/dellUI/Java/release/JViewer.jar`. Verified against blade13:

```
404  /software/avctKVM.jar
200  /Applications/dellUI/Java/release/JViewer.jar
```

`../bootleg-idrac6-client/kvm.sh` already speaks the AMI protocol correctly, so this image
containerises that logic (see `startapp.sh`) rather than using the upstream image.

## Two ways to run it

The image is **blade-agnostic** — the target is just `IDRAC_HOST` at runtime, so one image serves
every blade. What differs is how the container reaches the CMC management network.

### From outside the network — `../argo_kvm.sh` (single SOCKS proxy)

```bash
docker build -t argo-kvm .
cd .. && export JUMPHOST=yasiupl@153.19.211.3 IDENTITY_FILE=~/.ssh/argo_ed25519

./argo_kvm.sh 14 start                 # -> http://localhost:5814
./argo_kvm.sh 14 screenshot shot.png
./argo_kvm.sh 14 keys F1
./argo_kvm.sh 14 type "root"
./argo_kvm.sh list
./argo_kvm.sh stop-all
```

**One `ssh -D` SOCKS5 proxy serves every blade.** Because SOCKS proxies arbitrary host:port pairs,
there are no per-blade local forwards and no port collisions — all 16 consoles can share a single
SSH connection, each on its own web port (`5800 + blade`).

This replaced an earlier design that used five `-L` forwards per blade. Those pinned the iDRAC's
*fixed* KVM ports (5900/5901/3668/3669) onto the same local ports, so only one blade could be
connected at a time. If you ever need to go back to `-L` for some reason, that limitation is why.

The container gets `SOCKS_PROXY=host.docker.internal:1080`; `startapp.sh` passes it to curl
(`--socks5-hostname`) and to the JVM (`socksProxyHost`/`socksProxyPort`, which covers JViewer's
video/media sockets too).

On WSL, Docker Desktop runs containers in its own VM, so `--network host` does **not** reach WSL's
`127.0.0.1` — hence `--add-host=host.docker.internal:host-gateway`. If your user isn't in the
`docker` group yet, run with `DOCKER='sg docker -c'`.

### From inside the network — `docker-compose.yml.example` (the management-host deployment)

On a host that already sits on `192.168.0.0/24` (Pi, mini-PC, or a management blade) no proxy is
needed at all — containers dial the iDRACs directly:

```bash
cp docker-compose.yml.example docker-compose.yml   # then edit hostnames/network to taste
echo "IDRAC_PASSWORD=..." > .env                   # .env is gitignored
docker compose up -d                               # all 15 present blades
docker compose up -d kvm14                         # or just one
```

This gives **one URL per blade** via Traefik labels (`blade14.kvm.argo.y4s.io`), matching the
Traefik setup already used elsewhere in this repo. Point the wildcard DNS at the management host.

Two deliberate choices there:
- **One container per blade, not one container serving all.** The base image is one-app-one-X-
  display; multiplexing internally would mean hand-rolling 16× Xvfb/VNC/noVNC and losing failure
  isolation. Containers are cheap.
- **Host-based URLs, not path-based.** noVNC loads its assets and opens its websocket from the
  root path, so `…/blade14` prefix routing needs `stripPrefix` plus websocket rewriting and breaks
  easily. Subdomains sidestep it.

Ad-hoc single container, no wrapper:
```bash
docker run -d --name argo-kvm14 -p 5814:5800 \
  -e IDRAC_HOST=192.168.0.114:443 -e IDRAC_USER=root -e IDRAC_PASSWORD=calvin \
  argo-kvm
```

## Screenshots and keystrokes

`x11-apps`, `netpbm` and `xdotool` are baked into the image, and two helpers are included:

```bash
docker exec argo-kvm14 /screenshot.sh -  > shot.png   # PNG to stdout
docker exec argo-kvm14 /screenshot.sh                 # -> /screenshots/console.png
docker exec argo-kvm14 /sendkeys.sh F1
docker exec argo-kvm14 /sendkeys.sh ctrl+alt+Delete
docker exec argo-kvm14 /sendkeys.sh --type "root"
```

`sendkeys.sh` **clicks into the video area before typing** — this is essential and non-obvious.
Merely activating the JViewer window is not enough; without the click the applet silently drops
synthetic key events and the screen just doesn't change. Override the click point with
`CLICK_X`/`CLICK_Y` if the window layout differs.

Screenshots are what actually cracked the blade13/14 investigation: both were sitting at BIOS
prompts waiting for a keypress, which is completely invisible from racadm.

If keys arrive as the *wrong* characters, upstream's `IDRAC_KEYCODE_HACK` addresses that class of
problem; not needed here so far.

## Gotchas baked into the build

Each of these silently breaks the container in a different place — all are commented in the
`Dockerfile`/`startapp.sh`:

| Symptom | Cause / fix |
|---|---|
| `chown: invalid user: 'root:staff'` during build | baseimage-gui ships with **no `/etc/passwd` or `/etc/group`**; every JRE pulls in fontconfig-config whose postinst chowns. Fixed by creating minimal ones. |
| `UnsatisfiedLinkError: Can't load library: …/libawt_xawt.so` | `openjdk-*-jre-headless` has no AWT. Needs the **full** JRE. |
| `SSLHandshakeException: Received fatal alert: handshake_failure` right after login | The KVM video channel speaks TLSv1 + legacy ciphers that modern JREs refuse. Fixed by clearing `jdk.tls.disabledAlgorithms` / `jdk.certpath.disabledAlgorithms` in `java.security`, plus `-Djdk.tls.client.protocols`. Deliberately weak crypto — acceptable only because it's a container talking to a 2009 BMC over an SSH tunnel on an isolated network. |
| `Session cookie: Failure_No_Free_Slot` | **iDRAC session slots exhausted.** It has only a handful and scripted logins don't release them; eventually SSH to that iDRAC wedges too. Recover from the CMC with `racadm racreset -m server-<n>` (resets only that blade's management controller — the host keeps running). `startapp.sh` detects this and prints the fix. |
| Keystrokes do nothing | Click into the video area first — `sendkeys.sh` handles it. |
| `argo_kvm.sh … \| tail` hangs forever, even though the console came up | A backgrounded `ssh` inherits the script's stdout, so the long-lived SOCKS proxy holds the pipe open and the *reader* never sees EOF. Fixed by detaching the proxy's stdio (`</dev/null >/dev/null 2>&1 &` + `disown`) — worth remembering if you add any other long-running background process to these scripts. |
| Console dies with "Virtual Console is restarted. Closing the remote console" | Another KVM session took over, or a stale one from a killed container. Restart the container. |
| Tunnel/proxy vanishes mid-session | `argo_connect.sh` kills *every* ssh matching `$JUMPHOST` on startup. Don't interleave the two; `../argo_console_probe.sh` shows how to sequence around it. |

See also [../../racadm-reference.md](../../racadm-reference.md) and
[../../web-api-reference.md](../../web-api-reference.md).
