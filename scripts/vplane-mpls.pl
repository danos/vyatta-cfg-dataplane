#! /usr/bin/perl

# Copyright (c) 2015-2016 Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

use Getopt::Long;
use JSON qw( decode_json );

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Dataplane;
use Vyatta::DataplaneStats
  qw( get_dataplane_clear_stats clear_interface_for_vplane);

my @statistics = (
    { tag => 'in_octets',           display => 'in bytes' },
    { tag => 'in_ucastpkts',        display => 'in unicast packets' },
    { tag => 'in_errors',           display => 'in errors' },
    { tag => 'lbl_lookup_failures', display => 'label lookup failures' },
    { tag => 'out_octets',          display => 'out bytes' },
    { tag => 'out_ucastpkts',       display => 'out unicast packets' },
    { tag => 'out_errors',          display => 'out errors' },
    { tag => 'out_fragment_pkts',   display => 'out fragmented packets' },
);

sub clear_mpls_interfaces {
    my ( $interfaces, $dp_id, $dev ) = @_;

    foreach my $interface (@$interfaces) {
        next if ( defined($dev) && $dev ne $interface->{name} );
        clear_interface_for_vplane( $interface->{name},
            $interface->{'mpls statistics'},
            $dp_id, \@statistics, "mpls_stats" );
    }
}

# adjust stats, taking note of the clear file's values
sub adjust_mpls_stats {
    my ( $intf, $dp_id, $ifstats ) = @_;

    my %clear =
      get_dataplane_clear_stats( $intf, $dp_id, $ifstats, "mpls_stats" );

    foreach my $var ( keys %{$ifstats} ) {
        my $count = $ifstats->{$var};
        next unless defined($count);
        next unless defined( $clear{$var} );

        $ifstats->{$var} = $count - $clear{$var};
    }
}

sub show_mpls_global {
    my ($config) = @_;

    printf "MPLS Configuration\n";
    printf "\tIP TTL Propagate: %s, ", $config->{ipttlpropagate} ? "yes" : "no";
    printf "IP Ingress TTL: %d\n", $config->{defaultttl};
}

sub show_mpls_interfaces {
    my ( $interfaces, $dp_id, $show_stats, $dev ) = @_;

    print "MPLS Interfaces\n";
    foreach my $interface (@$interfaces) {
        next if ( defined($dev) && $dev ne $interface->{name} );
        my $addresses = $interface->{addresses};
        continue unless $interface->{mpls} eq 'on';
        printf "%s, ifindex: %d", $interface->{name}, $interface->{ifindex};
        if ( !$show_stats ) {
            printf ", mtu: %d\n", $interface->{mtu};
            print "\taddress:" if $addresses;
            foreach my $addr (@$addresses) {
                printf " %s", $addr->{inet}  if $addr->{inet};
                printf " %s", $addr->{inet6} if $addr->{inet6};
            }
        }
        my $mpls_stats = $interface->{'mpls statistics'};
        if ( $mpls_stats && $show_stats ) {
            adjust_mpls_stats( $interface->{name}, $dp_id, $mpls_stats );
            foreach my $st (@statistics) {
                my $stat_tag = $st->{tag};
                my $count    = $mpls_stats->{$stat_tag};
                next unless defined($count);

                printf "\n\t%s: %d", $st->{display}, $count;
            }
        }
        print "\n";
    }
}

my ( $cmd, $fabric, $show_interfaces, $show_stats, $clear, $dev );

sub usage {
    print
"Usage: $0 [--fabric=N] [--interfaces] [--statistics] [--clear] [--dev=if]\n";
    exit 1;
}

GetOptions(
    "fabric=s"   => \$fabric,
    "interfaces" => \$show_interfaces,
    "statistics" => \$show_stats,
    "clear"      => \$clear,
    "dev=s"      => \$dev,
) or usage();

my ( $dp_ids, $dp_conns ) = Vyatta::Dataplane::setup_fabric_conns($fabric);
die "Dataplane $fabric is not connected or does not exist\n"
  unless ( !defined($fabric) || scalar(@$dp_ids) > 0 );

$cmd =
  ( $show_interfaces || $clear ) ? 'mpls show ifconfig' : 'mpls show config';

for my $dp_id (@$dp_ids) {
    my $sock = ${$dp_conns}[$dp_id];
    die "Can not connect to dataplane\n"
      unless $sock;

    my $response = $sock->execute($cmd);
    die "No response from dataplane\n"
      unless defined($response);

    my $decoded = decode_json($response);

    print "\nvplane $dp_id:\n\n"
      unless ( $dp_id == 0 );

    if ($clear) {
        clear_mpls_interfaces( $decoded->{interfaces}, $dp_id, $dev );
    } elsif ($show_interfaces) {
        show_mpls_interfaces( $decoded->{interfaces},
            $dp_id, $show_stats, $dev );
    } else {
        show_mpls_global( $decoded->{config} );
    }
}
Vyatta::Dataplane::close_fabric_conns( $dp_ids, $dp_conns );
