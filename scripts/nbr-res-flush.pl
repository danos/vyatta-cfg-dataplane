#! /usr/bin/perl
#
# Script to flush entries in the caches in the dataplane and kernel that are
# used for neighbor resolution with ARP for IPv4 or with ND for IPv6

# Copyright (c) 2017, AT&T Intellectual Property.  All rights reserved.
# Copyright (c) 2013-2015 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

use Getopt::Long;

use lib "/opt/vyatta/share/perl5/";
use Data::Validate::IP qw(is_ipv4 is_ipv6);
use Vyatta::Dataplane;

# Flush cache entries for kernel and all dataplanes
sub flush_neighbor {
    my ( $arg, $cmd_opt, $ipv6, $dpids, $dpconns ) = @_;

    my $kern_opt = $ipv6 ? "-6" : "-4";
    system("ip $kern_opt neigh flush $cmd_opt $arg") == 0
      or exit 1;

    my $dp_cmd = $ipv6 ? "nd6" : "arp";
    my $dprsp =
      vplane_exec_cmd( "$dp_cmd flush $cmd_opt $arg", $dpids, $dpconns, 1 );
    foreach my $dpid ( @{$dpids} ) {
        my $rsp = ${$dprsp}[$dpid];
        if ( defined($rsp) && ( $rsp !~ /^\s*$/ ) ) {
            warn "Can't flush $arg on $dpid\n";
        }
    }
}

sub usage {
    print <<EOF;
Flush entries for neighbor resolution learnt by ARP for IPv4 or ND for IPv6
Usage:	$0 --interface <ifname> [--ipv6]
	$0 --interface <address> [--ipv6]
EOF
    exit 1;
}

my ( $address, $interface, $ipv6 );

GetOptions(
    "interface=s" => \$interface,
    "address=s"   => \$address,
    "ipv6"        => \$ipv6,
) or usage();

my ( $dpids, $dpconns ) = Vyatta::Dataplane::setup_fabric_conns();

if ($interface) {
    flush_neighbor( $interface, "dev", $ipv6, $dpids, $dpconns );
} elsif ($address) {
    is_ipv4($address) && !$ipv6 || is_ipv6($address) && $ipv6
      or die("Error: invalid address\n");
    flush_neighbor( $address, "to", $ipv6, $dpids, $dpconns );
}

Vyatta::Dataplane::close_fabric_conns( $dpids, $dpconns );
