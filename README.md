# Argo Connect

Utility to connect to my Dell m1000e "home" lab. Don't ask me why. 
Very specific to the way I have the server set up. Everything is routed through a Raspberry Pi connected to the OOB management ports.

## Example Usage:

`./argo_connect.sh` - Walks you through all the available options


`./argo_Connect.sh 1 kvm` - run KVM connection to blade number 1 (see "KVM prerequisites" below)


`./argo_connect.sh 1 ssh` - open iDRAC SSH connection


`./argo_connect.sh 1 web` - open web iDRAC GUI


`./argo_connect.sh chassis web` - open web CMC GUI


`./argo_connect.sh chassis ssh` - jump into SSH connection to the Chassis Management Controller


`./argo_connect.sh chassis ssh "racadm getconfig -g cfgChassisPower -o cfgChassisInPower"` - run racadm command on the CMC via SSH.


`./argo_connect.sh network web` - open web GUI of the network switch

## Fallback jumphost (when the OOB Pi is down)

If `argo@argo` (the Raspberry Pi) is unreachable, everything can be routed through any other host
that's wired into the CMC's `192.168.0.0/24` management network — e.g. a Windows box with a NIC
on that segment. Override the jumphost and identity files via env vars:

```
JUMPHOST=<user>@<host> IDENTITY_FILE=~/.ssh/argo_ed25519 IDRAC_IDENTITY_FILE=~/.ssh/argo_rsa1024 \
  ./argo_connect.sh chassis ssh
```

- `IDENTITY_FILE` authenticates to the jumphost itself.
- `IDRAC_IDENTITY_FILE` authenticates to the CMC/iDRAC once tunneled through (defaults to
  `IDENTITY_FILE` if unset, matching the original single-key Pi setup). This **must** be an
  `ssh-rsa` key — the CMC's firmware (CMC 6.21, circa 2019) doesn't understand `ed25519`, and its
  own docs recommend 1024-bit RSA specifically (it silently accepts other sizes up to 4096 but can
  fail to actually log in with them).
- Confirm any candidate jumphost actually reaches the CMC first: `arping -I <iface> 192.168.0.100`
  (needs root) is the reliable check — a plain `ping` can pass through a router while `arping`
  proves real L2 adjacency. The blade servers' own NICs (`eno1`/`eno2`) are **not** on this
  network, confirmed via `arping` returning zero replies on both.

### Adding an SSH key to the CMC's `service` account (`svcacct`)

The CMC only accepts SSH keys for a fixed pseudo-user called `svcacct` (not a numeric user index
like other accounts), addressed via `racadm sshpkauth`, and actually logged into over SSH as
`service`. From an existing authenticated session (`argo_connect.sh chassis ssh`, or manually):

```bash
racadm sshpkauth -i svcacct -k <1-6> -v                     # view a key slot
racadm sshpkauth -i svcacct -k <1-6> -p 0xfff -t "<pubkey>"  # add/replace a key slot
racadm sshpkauth -i svcacct -k <1-6> -d                      # delete a key slot
```

Gotchas that cost real time figuring out:
- `-p 0xfff` (privilege mask) is **required** on write, even though it's undocumented in the
  in-CLI help — omitting it fails with `ERROR: Failed to save key file.`, which looks identical to
  a genuine storage fault and has nothing to do with slot occupancy or key format.
- The key must be `ssh-rsa`; anything else (e.g. `ed25519`) fails with
  `ERROR: Key text appears to be corrupt.`
- **Check `-v` on a slot before deleting it.** A working key can sit in slot 1 indefinitely; on
  this chassis slot 1 held the original `argo@argo` (Pi) key. Prefer writing to an empty slot
  (`-k` up to 6 are available) over clearing one you haven't verified is unused.

### KVM prerequisites

`bootleg-idrac6-client/kvm.sh` (the `kvm` service) needs the `bootleg-idrac6-client` submodule
checked out (`git submodule update --init bootleg-idrac6-client` — it's not pulled in by a plain
clone) and a working `java` on `PATH`.

Despite fetching a `.jnlp` file, it does **not** need Java Web Start — the script just `curl`s the
`.jnlp` to scrape launch arguments via `awk`, then runs a plain `java -jar JViewer.jar $args`
against a downloaded native library (`Linux_x86_64.jar`, unpacked `.so` files for video/USB
redirection JNI). A regular JRE is all that's required.

Use **Java 8** specifically, not a newer LTS — this is circa-2010 Dell code with old JNI bindings
that can hit `IllegalAccessError`/native-lib-loading failures on Java 11+'s module system. On
Debian/Ubuntu (including WSL):

```bash
sudo apt update && sudo apt install openjdk-8-jre
```

It's a Swing GUI app, so it needs a display. On WSL2 with WSLg (Windows 11, or updated Windows 10)
this works out of the box; otherwise run an X server (e.g. VcXsrv) on the Windows side and set
`DISPLAY` accordingly.

### Hardware inventory

`argo_inventory.sh` pulls a full chassis inventory non-interactively (chassis/CMC info, per-module
presence & health, firmware versions for every blade/switch/CMC) — same env var overrides as
above:

```
JUMPHOST=<user>@<host> IDENTITY_FILE=~/.ssh/argo_ed25519 IDRAC_IDENTITY_FILE=~/.ssh/argo_rsa1024 \
  ./argo_inventory.sh
```