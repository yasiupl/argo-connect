# Argo Connect

Utility to connect to my Dell m1000e "home" lab. Don't ask me why. 
Very specific to the way I have the server set up. Everything is routed through a Raspberry Pi connected to the OOB management ports.

## Example Usage:

`./argo_connect.sh` - Walks you through all the available options
`./argo_Connect.sh 1 kvm` - run KVM connection to blade number 1
`./argo_connect.sh 1 ssh` - open web iDRAC GUI
`./argo_connect.sh 1 web` - open web iDRAC GUI
`./argo_connect.sh chassis web` - open web CMC GUI
`./argo_connect.sh chassis ssh` - jump into SSH connection to the Chassis Management Controller
`./argo_connect.sh chassis ssh "racadm getconfig -g cfgChassisPower -o cfgChassisInPower"` - run racadm command on the CMC via SSH.
`./argo_connect.sh network web` - open web GUI of the network switch