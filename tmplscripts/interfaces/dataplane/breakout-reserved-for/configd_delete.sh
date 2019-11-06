#!/opt/vyatta/bin/cliexec
! cli-shell-api exists interfaces dataplane $VAR(../@) disable || ip link set up $VAR(../@)
