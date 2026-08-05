#!/usr/bin/env bash
# Pulls a full hardware inventory from the CMC (chassis, fans, PSUs, IOMs, blades, firmware
# versions) over an SSH tunnel, non-interactively. See README.md for setup/usage.
set -euo pipefail

jumphost=${JUMPHOST:-argo@argo}
identity_file=${IDENTITY_FILE:-./argo.private}
idrac_identity_file=${IDRAC_IDENTITY_FILE:-$identity_file}
CMC_USER=${CMC_USER:-service}
IDRAC_PASSWORD=${IDRAC_PASSWORD:-calvin}
network_prefix="192.168.0."
cmc_ip="${network_prefix}100"
local_port=${LOCAL_PORT:-8022}

SSH_WRAPPER=()
if [ -n "$IDRAC_PASSWORD" ] && command -v sshpass &> /dev/null; then
    SSH_WRAPPER=(sshpass -p "$IDRAC_PASSWORD")
fi

echo "Opening tunnel to $cmc_ip via $jumphost..." >&2
ssh -i "$identity_file" -N -L "${local_port}:${cmc_ip}:22" "$jumphost" &
tunnel_pid=$!
trap 'kill "$tunnel_pid" 2>/dev/null' EXIT
sleep 3

racadm() {
    # group1-sha1 before group14-sha1, and known_hosts skipped entirely: see argo_connect.sh for why.
    "${SSH_WRAPPER[@]}" ssh "${CMC_USER}@localhost" -i "$idrac_identity_file" -p "$local_port" \
        -o "IdentitiesOnly=yes" -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" \
        -o "KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1" \
        -o "Ciphers=+3des-cbc" -o "PubkeyAcceptedAlgorithms=+ssh-rsa" -o "HostkeyAlgorithms=+ssh-rsa" \
        "racadm $*"
}

echo "=== Chassis / CMC info (racadm getsysinfo) ==="
racadm getsysinfo
echo
echo "=== Module presence & health (racadm getmodinfo) ==="
racadm getmodinfo
echo
echo "=== Firmware versions (racadm getversion) ==="
racadm getversion
