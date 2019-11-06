#!/bin/sh

# For unexpected interface, just return
if ! echo $1 | grep -q dp0ce; then
    exit 0
fi

port=$(echo $1 | sed s/dp0ce//)
if [ $port -ge 20 ]; then
    if [ $(( $port % 2 )) = 1 ]; then
	target_port=$(( $port - 21 ))
    else
	target_port=$(( $port - 19 ))
    fi
else
    if [ $(( $port % 2 )) = 1 ]; then
	target_port=$(( $port + 19 ))
    else
	target_port=$(( $port + 21 ))
    fi
fi
echo dp0ce$target_port
