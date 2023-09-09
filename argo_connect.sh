#!/bin/sh


jumphost=argo@argo
device=$1
service=$2
network_prefix="192.168.0."
isIDRAC=false
identity_file=./argo.private
SSH_USER=service
IDRAC_USER=root
IDRAC_PASSWORD=calvin

## Get IP
if [ -z $device ]; then
    echo "Options:"
    echo -e "1-16) \t\t Connect to blades iDRAC {ssh, web, kvm} \t $0 [1-16] {ssh, web, kvm}"
    echo -e "chassis) \t Connect to CMC {ssh, web} \t\t\t $0 chassis {ssh, web}"
    echo -e "network) \t Connect to network switch {ssh, web} \t\t $0 network {ssh, web-insecure}"
    echo -e "q) \t\t Quit"
    read -p "Selection: " device
fi

case $device in
        "chassis") 
            ip=$network_prefix"100" 
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
    ssh -i $identity_file -N -L 8443:$ip:443 -L 8022:$ip:22 -L 8080:$ip:80 -L 5900:$ip:5900 -L 5901:$ip:5901 -L 3668:$ip:3668 -L 3669:$ip:3669 $jumphost &
    ssh_process=$!
    sleep 1
    echo $ssh_process
else   
    echo "SSH identity not found, cannot open Proxy. Exiting..."
    exit
fi

## Run Service
if [ -z $service ]; then
    echo Options: 
    echo -e "kvm) \t\t Open JavaKVM"
    echo -e "ssh) \t\t Open SSH connection"
    echo -e "web) \t\t Open https://localhost:8443"
    echo -e "web-insecure) \t Open http://localhost:8080"
    echo -e "proxy) \t\t Just proxy, don't open anything"
    echo -e "q) \t\t Quit"
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
            echo "Unsupported option"
        fi
    ;;
    "ssh")
        echo Starting SSH
        ssh -i $identity_file -J $jumphost $IDRAC_USER@$ip
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
        echo "Unsupported option"
    ;;
esac


kill -9 $ssh_process
echo Killed proxy \($ssh_process\) 
ps aux | grep $jumphost | awk 'NR==1{print $2}' | xargs kill -9