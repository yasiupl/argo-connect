#!/usr/bin/env bash

device=$1
service=$2
command=$3

# Overridable via env, for when the primary OOB Pi (argo@argo) is down. Known working fallback:
# a Windows host wired directly into the CMC's 192.168.0.0/24 management network.
#   JUMPHOST=yasiupl@153.19.211.3 IDENTITY_FILE=~/.ssh/argo_ed25519 IDRAC_IDENTITY_FILE=~/.ssh/argo_rsa1024 \
#     ./argo_connect.sh chassis ssh
jumphost=${JUMPHOST:-argo@argo}
network_prefix="192.168.0."
identity_file=${IDENTITY_FILE:-./argo.private}
# Key used for the CMC/iDRAC hop itself. Defaults to the same key as the jumphost (the original
# single-key Pi setup); override separately when the jumphost and CMC/iDRAC keys differ, e.g. via
# the fallback above, since old CMC/iDRAC6 firmware only accepts ssh-rsa (no ed25519).
idrac_identity_file=${IDRAC_IDENTITY_FILE:-$identity_file}
SSH_USER=service
CMC_USER=${CMC_USER:-service}
IDRAC_USER=${IDRAC_USER:-root}
IDRAC_PASSWORD=${IDRAC_PASSWORD:-calvin}
isIDRAC=false

## Get IP
if [ -z $device ]; then
    echo "Options:"
    echo -e "1-16 \t\t -- connect to blades iDRAC {ssh, web, kvm}"
    echo -e "chassis \t -- connect to CMC {ssh, web}"
    echo -e "network \t -- connect to network switch {ssh, web}"
    echo -e "q \t\t -- quit"
    read -p "Selection: " device
fi

case $device in
        "chassis")
            ip=$network_prefix"100"
            # SSH key already uploaded to CMC's svcacct, use service account instead of root to use it.
            IDRAC_USER=$CMC_USER
        ;;
        "network") ip=$network_prefix"200" ;;
        *) 
            if [[ $device =~ ^[0-9]+$ ]] && [ $device -gt 0 ] && [ $device -lt 17 ]; then
                ip=$network_prefix$((100 + $device))
                isIDRAC=true
            else
                echo "Option not found"
                exit
            fi
        ;;
esac

## Run Proxy
if [ -f $identity_file ]; then
    echo Connecting to $ip via $jumphost
    # Kill all already running proxies - no support for parallel connections to multiple iDRACs.
    ps aux | grep $jumphost | grep -v grep | awk '{print $2}' | xargs -r kill -9 &
    sleep 0.1
    # Open a new proxy
    ssh -i $identity_file -N -L 8443:$ip:443 -L 8022:$ip:22 -L 8080:$ip:80 -L 5900:$ip:5900 -L 5901:$ip:5901 -L 3668:$ip:3668 -L 3669:$ip:3669 $jumphost &
    ssh_process=$!
    sleep 3
    echo Started proxy \($ssh_process\)
else   
    echo "SSH identity not found, cannot open Proxy. Exiting..."
    exit
fi

## Run Service
if [ -z $service ]; then
    echo Options: 
    echo -e "kvm \t\t -- open JavaKVM"
    echo -e "ssh \t\t -- open SSH connection"
    echo -e "web \t\t -- open https://localhost:8443"
    echo -e "web-insecure \t -- open http://localhost:8080"
    echo -e "proxy \t\t -- just proxy, don't open anything"
    echo -e "q \t\t -- quit"
    read -p "Selection: " service
fi

case $service in
    "kvm")
        if [ $isIDRAC = true ]; then
            echo Starting KVM
            export IDRAC_USER=$IDRAC_USER
            export IDRAC_PASSWORD=$IDRAC_PASSWORD
            export IDRAC_HOST=localhost:8443
            ./bootleg-idrac6-client/kvm.sh
        else
            echo "$service - unsupported option"
        fi
    ;;
    "ssh")
        echo Starting SSH
        # Falls back to password auth (sshpass) when the target has no key uploaded yet; pubkey
        # auth is attempted first regardless, so this is a no-op once a key is in place.
        SSH_WRAPPER=()
        if [ -n "$IDRAC_PASSWORD" ] && command -v sshpass &> /dev/null; then
            SSH_WRAPPER=(sshpass -p "$IDRAC_PASSWORD")
        fi
        # group1-sha1 must come before group14-sha1: old iDRAC6 Dropbear advertises group14 but
        # hangs mid-handshake on it (real bug, not just deprecated-algorithm rejection). Distinct
        # hosts share localhost:8022 across invocations, so skip known_hosts entirely too, else a
        # changed host key silently disables password auth as a MITM precaution.
        "${SSH_WRAPPER[@]}" ssh $IDRAC_USER@localhost -i $idrac_identity_file -p 8022 -o "IdentitiesOnly=yes" -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" -o "KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1" -o "Ciphers=+3des-cbc" -o "PubkeyAcceptedAlgorithms=+ssh-rsa" -o "HostkeyAlgorithms=+ssh-rsa" $command
        #ssh -i $idrac_identity_file -J $jumphost $IDRAC_USER@$ip
    ;;
    "web")
        url=https://localhost:8443/index.html
        echo Starting $url
        xdg-open $url
        read -p "Press any key to exit" 
    ;;
    "web-insecure") 
        url=http://localhost:8080/index.html
        echo Starting $url
        xdg-open $url
        read -p "Press any key to exit"
    ;;
    "proxy")
        read -p "Press any key to exit"
    ;;
    *)
        echo "Quitting..."
    ;;
esac


kill -9 $ssh_process
echo Killed proxy \($ssh_process\) 
