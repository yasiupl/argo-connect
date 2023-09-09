#!/bin/sh


jumphost=argo@argo
device=$1
service=$2
command=$3
network_prefix="192.168.0."
isIDRAC=false
identity_file=./argo.private
SSH_USER=service
IDRAC_USER=root
IDRAC_PASSWORD=calvin

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
            # SSH key already uploaded to CMC, use service account instead of root to use it.
            IDRAC_USER=service
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
    # Kill all already running proxies
    ps aux | grep $jumphost | grep -v grep | awk '{print $2}' | xargs kill -9 &
    sleep 0.1
    # Open a new proxy
    ssh -i $identity_file -N -L 8443:$ip:443 -L 8022:$ip:22 -L 8080:$ip:80 -L 5900:$ip:5900 -L 5901:$ip:5901 -L 3668:$ip:3668 -L 3669:$ip:3669 $jumphost &
    ssh_process=$!
    sleep 0.5
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
        ssh $IDRAC_USER@localhost -i $identity_file -p 8022 -o "IdentitiesOnly=yes" -o "StrictHostKeyChecking=no" -o "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1" -o "Ciphers=+3des-cbc" -o "PubkeyAcceptedAlgorithms=+ssh-rsa" -o "HostkeyAlgorithms=+ssh-rsa" $command
        #ssh -i $identity_file -J $jumphost $IDRAC_USER@$ip
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