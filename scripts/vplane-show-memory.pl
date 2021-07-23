#! /usr/bin/perl

# Copyright (c) 2013-2015 Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

use Getopt::Long;
use JSON qw( decode_json );

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Dataplane;

sub show_mempool {
    my $mempool = shift;

    print "Memory pool statistics\n";
    my $fmt = "%-16s %-8s %-8s %s\n";
    printf $fmt, 'Pool', 'In Use', 'Free', 'Memory';

    foreach my $p ( @{$mempool} ) {
        my $mb = sprintf "%uM", $p->{memory} / ( 1024 * 1024 );
        printf $fmt, $p->{name}, $p->{inuse}, $p->{avail}, $mb;
    }
    print "\n";
}

sub show_memzone {
    my $memzone = shift;

    print "Memory zone statistics\n";
    my $fmt = "%-32s %-6s %s\n";
    printf $fmt, 'Zone', 'Socket', 'Size';

    foreach my $p ( @{$memzone} ) {
        printf $fmt, $p->{name}, $p->{socket}, $p->{size};
    }
    print "\n";
}

sub show_rte_malloc {
    my $arg   = shift;
    my @stats = @{$arg};
    my $fmt   = "  %10s %s\n";

    print "Rte malloc statistics\n";
    foreach my $node ( 0 .. $#stats ) {
        my $info = $stats[$node];

        printf "Socket $node\n";
        printf $fmt, $info->{heap_total_bytes}, "total bytes";
        printf $fmt, $info->{free_bytes},       "total free bytes";
        printf $fmt, $info->{greatest_free},    "largest free block";
        printf $fmt, $info->{free_count},       "free elements";
        printf $fmt, $info->{alloc_count},      "allocated elements";
        printf $fmt, $info->{heap_alloc_bytes}, "total allocated bytes";
    }
}

sub show_malloc {
    my $info = shift;
    my $fmt  = "  %10s %s\n";

    print "\nMalloc pool statistics\n";
    printf $fmt, $info->{arena},    "non-mmapped space (bytes)";
    printf $fmt, $info->{ordblks},  "free chunks";
    printf $fmt, $info->{smblks},   "free fastbin blocks";
    printf $fmt, $info->{hblks},    "mmapped regions";
    printf $fmt, $info->{hblkhd},   "mmapped space (bytes)";
    printf $fmt, $info->{fsmblks},  "freed fastbin blocks (bytes)";
    printf $fmt, $info->{uordblks}, "allocated space (bytes)";
    printf $fmt, $info->{fordblks}, "free space (bytes)";
    printf $fmt, $info->{keepcost}, "releasable space (bytes)";
}

sub usage {
    print "Usage: $0 [--fabric=N]\n";
    exit 1;
}

my $fabric;

GetOptions( 'fabric=s' => \$fabric, ) or usage();

my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns($fabric);
if ( scalar(@$dpids) < 1 ) {
    if ( defined($fabric) ) {
        die "Dataplane $fabric is not connected or does not exist\n";
    } else {
        die "No active dataplanes found\n";
    }
}

for my $fid (@$dpids) {
    my $sock = ${$dpsocks}[$fid];
    die "Can not connect to dataplane $fid\n"
      unless defined($sock);

    my $response = $sock->execute('memory');
    die "No response from dataplane $fid\n"
      unless ( defined($response) );

    my $decoded = decode_json($response);

    print "\nvplane $fid:\n\n"
      unless ( $fid == 0 );
    show_mempool( $decoded->{mempool} );
    show_memzone( $decoded->{memzone} );
    show_rte_malloc( $decoded->{rte_malloc} );
    show_malloc( $decoded->{malloc} );
}
Vyatta::Dataplane::close_fabric_conns( $dpids, $dpsocks );
