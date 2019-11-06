#! /usr/bin/perl

# Copyright (c) 2013-2017 Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

use Getopt::Long;
use JSON qw( decode_json );

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Dataplane;
use Vyatta::Misc qw(getInterfaces);

my ( $dp_ids, $dp_conns, $local_controller );

sub get_gre_used {
    my $intf = shift;
    my $peer_addr = shift;

    for my $dp_id ( @{$dp_ids} ) {
        my $sock = ${$dp_conns}[$dp_id];

        next unless $sock;

        my $response = $sock->execute("gre tun_address $peer_addr tunnel $intf");
        next unless defined($response);

        my $decoded = decode_json($response);
        my @entries = @{ $decoded->{neighbors} };
        foreach my $entry (@entries) {
            print "$entry->{used}\n";
        }
    }
}

sub usage {
    print "Usage: $0 --show-intf=s --peer-addr=s gre-used\n";
    exit 1;
}

my $intf;
my $peer_addr;
my %show_func = (
    'gre-used' => \&get_gre_used,
);

GetOptions(
    'show-intf=s' => \$intf,
    'peer-addr=s' => \$peer_addr
) or usage();

if (defined($intf)) {
   die "interface $intf does not exist on system\n"
      unless grep { $intf eq $_ } getInterfaces();
}

( $dp_ids, $dp_conns, $local_controller ) =
  Vyatta::Dataplane::setup_fabric_conns();

foreach my $arg (@ARGV) {
    my $func = $show_func{$arg};

    &$func($intf, $peer_addr);
}
Vyatta::Dataplane::close_fabric_conns( $dp_ids, $dp_conns );
