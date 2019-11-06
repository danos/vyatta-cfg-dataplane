#! /usr/bin/perl

# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
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
use Vyatta::Interface;

sub show_nd {
    my ( $data, $intf ) = @_;
    my $format = "%-39s %-17s %-9s %-10s %s\n";

    printf $format, "IPv6 Address", "HW address", "Flags", "State", "Device";

    my @entries = @{ $data->{nd6} };
    foreach my $entry (@entries) {
        next if ( defined($intf) && $entry->{ifname} ne $intf );
        printf $format, $entry->{ip}, $entry->{mac}, $entry->{flags},
          $entry->{state}, $entry->{ifname};
    }
}

sub show_nd_all {
    my ( $data, $intf ) = @_;
    my %kernel_nd    = ();
    my $format       = "%-39s %-17s %-18s %-18s %s\n";
    my %kernel_flags = (
        'REACHABLE' => 'VALID',
        'STALE'     => 'VALID',
        'DELAY'     => 'VALID',
        'PROBE'     => 'VALID',
        'PERMANENT' => 'STATIC',
        'NOARP'     => 'STATIC'
    );
    my $kernel_flags_re = '(' . join( '|', keys %kernel_flags ) . ')';

    open( my $nd_output, '-|', "ip -6 -o neigh " ) or die "show nd failed ";
    while (<$nd_output>) {
        chomp;

        # fe80::b203:f4ff:fe03:100 dev dp0s4 lladdr b0:03:f4:03:01:00 STALE
        my ($addr)    = (/([^ ]+)/)          or next;
        my ($dev)     = (/dev ([^ ]+)/)      or next;
        my ($lladdr)  = (/lladdr ([^ ]+)/)   or next;
        my ($kldflag) = (/$kernel_flags_re/) or next;

        $kernel_nd{$dev}{$addr} =
          [ $lladdr, $kernel_flags{$kldflag} || "", $kldflag, 1 ];
    }
    close($nd_output);

    printf $format,
      "IPv6 Address", "HW address", "Dataplane", "Controller", "Device";

    my @entries = @{ $data->{nd6} };
    foreach my $entry (@entries) {
        next if ( defined($intf) && $entry->{ifname} ne $intf );

        my $kernel_flag = "";
        if ( exists $kernel_nd{ $entry->{ifname} }{ $entry->{ip} } ) {
            my $kernel_entry = $kernel_nd{ $entry->{ifname} }{ $entry->{ip} };
            my $flags        = $kernel_entry->[1];
            $kernel_flag =
              $flags eq "VALID"
              ? "$flags [$kernel_entry->[2]]"
              : $flags;
            $kernel_entry->[3] = 0;
        }
        printf $format, $entry->{ip}, $entry->{mac},
          $entry->{flags} eq "VALID"
          ? "$entry->{flags} [$entry->{state}]"
          : $entry->{flags},
          $kernel_flag,
          $entry->{ifname};
    }

    for my $kintf ( keys %kernel_nd ) {
        next if ( defined($intf) && $kintf ne $intf );
        for my $ip ( keys %{ $kernel_nd{$kintf} } ) {
            my $kernel_entry = $kernel_nd{$kintf}{$ip};
            next unless $kernel_entry->[3];

            my $mac   = "0:0:0:0:0:0";
            my $flags = "PENDING";

            if ( $kernel_entry->[0] =~ m{:} ) {
                $mac   = $kernel_entry->[0];
                $flags = $kernel_entry->[1];
            }

            printf $format, $ip, $mac, "",
              $flags eq "VALID" ? "$flags [$kernel_entry->[2]]" : $flags,
              $kintf;
        }
    }
}

sub usage {
    print "Usage: $0 [--fabric=N] <CMD>
$0 [--show-intf=s] <CMD>\n";
    exit 1;
}

my $fabric;
my $intf;
my %show_func = (
    'nd'     => \&show_nd,
    'nd-all' => \&show_nd_all,
);

GetOptions(
    'fabric=s'    => \$fabric,
    'show-intf=s' => \$intf
) or usage();

if ( defined($intf) ) {
    my $ifn = new Vyatta::Interface($intf);
    $ifn or die "$intf is not a valid dataplane interface\n";
    $fabric = $ifn->dpid();
    die "$intf is on a dataplane that is not connected or does not exist\n"
      unless defined($fabric);
}

my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns($fabric);

if ( defined($fabric) ) {
    die "Dataplane $fabric is not connected or does not exist\n"
      unless ( scalar(@$dpids) > 0 );
} else {
    exit 1
      unless ( scalar(@$dpids) > 0 );
}

for my $fid (@$dpids) {
    my $sock = ${$dpsocks}[$fid];
    die "Can not connect to dataplane $fid\n"
      unless defined($sock);

    my $response = $sock->execute('nd6');
    die "No response from dataplane $fid\n"
      unless defined($response);
    my $decoded = decode_json($response);

    foreach my $arg (@ARGV) {
        my $func = $show_func{$arg};
        die "Invalid argument\n"
          unless defined($func);

        print "vplane $fid -\n"
          unless $fid == 0;

        &$func( $decoded, $intf );
    }
}
Vyatta::Dataplane::close_fabric_conns( $dpids, $dpsocks );
