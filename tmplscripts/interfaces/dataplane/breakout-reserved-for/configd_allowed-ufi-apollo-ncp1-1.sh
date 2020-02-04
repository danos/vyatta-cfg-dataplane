#!/bin/sh

source /opt/vyatta/share/vyatta-cfg-dataplane/ufi-apollo-ncp1-1.functions

# For unexpected interface, just return
if ! echo $1 | grep -q dp0ce; then
    exit 0
fi

# The function is an involution, so this also works for getting the
# breakout port for a reserved port
reserved_port_for_breakout_port "$1"
