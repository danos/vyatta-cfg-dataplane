# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2014-2016 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2008 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#
# Module: Dataplane-Stats.pm
# Vyatta dataplane interface stats functions

package Vyatta::DataplaneStats;

use strict;
use warnings;

use File::Slurp;
use JSON qw( decode_json );

use lib "/opt/vyatta/share/perl5/";
use Time::Duration;
use Time::HiRes qw( clock_gettime CLOCK_REALTIME );
use Vyatta::Misc;
use Vyatta::Dataplane;
use Vyatta::PCIid;
use Vyatta::Interface;
use Vyatta::InterfaceStats;
use base 'Exporter';

our @EXPORT =
  qw(clear_dataplane_interfaces show_dataplane_interfaces_slowpath show_dataplane_interfaces show_dataplane_interfaces_per_vplane get_dataplane_clear_stats clear_interface_for_vplane);

my @statistics = (
    { tag => 'rx_bytes',          display => 'Input   bytes' },
    { tag => 'tx_bytes',          display => 'Output  bytes' },
    { tag => 'rx_packets',        display => 'Input   packets' },
    { tag => 'tx_packets',        display => 'Output  packets' },
    { tag => 'rx_dropped',        display => 'Input   discarded' },
    { tag => 'tx_dropped',        display => 'Output  dropped total' },
    { tag => 'tx_dropped_txring', display => '   Dropped ring' },
    { tag => 'tx_dropped_hwq',    display => '   Dropped h/w queue' },
    { tag => 'tx_dropped_proto',  display => '   Dropped protocol' },
    { tag => 'rx_missed',         display => 'Input   missed' },
    { tag => 'rx_non_ip',         display => 'Input   non-dataplane' },
    { tag => 'rx_bridge',         display => 'Bridged packets', hide => 1 },
    { tag => 'rx_errors',         display => 'Receive  errors', hide => 1 },
    { tag => 'tx_errors',         display => 'Transmit errors', hide => 1 },
    { tag => 'rx_nobuffer',       display => 'Buffers exhausted', hide => 1 },
    { tag => 'rx_multicast',      display => 'Input   multicast' },
    { tag => 'tx_multicast',      display => 'Output  multicast' },
    { tag => 'rx_vlan',           display => 'Input Tagged', hide => 1 },
    { tag => 'rx_bad_vid',        display => 'Incorrect tag', hide => 1 },
    { tag => 'rx_bad_address',    display => 'Incorrect address', hide => 1 },
);

my @perf_counters = (
    { tag => 'rx_pps', display => 'Receive  pkts/sec' },
    { tag => 'rx_bps', display => '         bits/sec' },
    { tag => 'tx_pps', display => 'Transmit pkts/sec' },
    { tag => 'tx_bps', display => '         bits/sec' },
);

my $clear_stats_dir  = '/var/run/vyatta';
my $clear_file_magic = 'XYZZYX';

my $dp_ids;
my $dp_conns;

sub get_intf_statsfile {
    my $intf  = shift;
    my $dp_id = shift;
    my $which = shift;

    $which = "stats" if !defined($which);
    return "$clear_stats_dir/$intf.dp$dp_id.$which";
}

sub get_dataplane_clear_stats {
    my $intf   = shift;
    my $dp_id  = shift;
    my $ifstat = shift;
    my $which  = shift;

    my %stats = ();
    my $filename = get_intf_statsfile( $intf, $dp_id, $which );

    open( my $f, '<', $filename )
      or return %stats;

    my $magic = <$f>;
    chomp $magic;
    if ( $magic ne $clear_file_magic ) {
        print "bad magic [$intf]\n";
        close($f);
        unlink $filename;
        return %stats;
    }

    while (<$f>) {
        chop;
        my ( $var, $val ) = split(/,/);

        # sanity check: if unknown stats field is in the clear file,
        # or clear value is greater than current one then don't trust the file,
        # shouldn't need to worry about wrap with 64bit counters
        if ( !defined( $ifstat->{$var} ) || $val > $ifstat->{$var} ) {
            print "bad stat [$var, $intf]\n";
            close($f);
            unlink $filename;
            return ();
        }

        $stats{$var} = $val;
    }
    close($f);
    return %stats;
}

sub clear_interface {
    my $results = shift;

    for my $dp_id ( @{$dp_ids} ) {
        my $ifinfo = $results->[$dp_id];
        next unless defined($ifinfo);

        my $statistics  = $ifinfo->{statistics};
        my $xstatistics = $ifinfo->{xstatistics};

        # Merge the Stats
        foreach my $key (keys %$xstatistics){
                $statistics->{$key} = $xstatistics->{$key};
        }

        clear_interface_for_vplane( $ifinfo->{name}, $statistics,
            $dp_id );
    }
}

sub clear_interface_for_vplane {
    my $ifname     = shift;
    my $ifstat     = shift;
    my $dp_id      = shift;
    my $statistics = shift;
    my $which      = shift;

    my $filename = get_intf_statsfile( $ifname, $dp_id, $which );

    mkdir $clear_stats_dir unless ( -d $clear_stats_dir );

    open( my $f, '>', $filename )
      or die "Couldn't open $filename [$!]\n";

    print "Clearing $ifname (dataplane)\n";
    print $f $clear_file_magic, "\n";

    if (defined $statistics){
        # Clear only stats defined in $statistics
        foreach my $st ( @{$statistics} ) {
            my $var = $st->{tag};
            my $val = $ifstat->{ $st->{tag} };
            next unless defined($val);
            next if ( $val eq 0 && $st->{hide} );

            print $f $var, ",", $val, "\n";
        }
    } else {
        # Clear all stats
        foreach my $key (keys %$ifstat){
            my $val = $ifstat->{ $key };
            next unless defined($val);
            next if ( ($key =~ '^[tr]x_[pb]ps') || ($key =~ '^qstats'));

            print $f $key, ",", $val, "\n";
        }

        # Clear qstats
        my $qid = 0;
        foreach my $qstat (@{ $ifstat->{ 'qstats' } }) {
            foreach my $key (keys %$qstat){
                my $val = $qstat->{ $key };
                next unless defined($val);
                next if ($val eq 0);
                print $f "q", $qid, "_", $key, ",", $val, "\n";
            }
            $qid++;
        }
    }

    close($f);
}

# Dataplane interface: fabric 0 pci-slot 0 port 0
#   Interface port: 1 ifIndex: 3
#   Mac: 01:02:03:04:05
#   Link: up, full duplex, speed 100000
#   Flags: present, running
#   Config         : proxy_arp, multicast forward
#   Addresses      :
#   Statistics:
#    Input  bytes  :        3668993407828
#    Output bytes  : 18446744073709551616
#    Input  packets:
#    Output packets:

sub show_interface {
    my $results = shift;
    my $intf    = shift;

    my $dp_id  = $intf->dpid();
    my $ifinfo = $results->[$dp_id];
    return unless defined($ifinfo);

    show_interface_non_stats( $ifinfo, $intf );

    adjust_stats($results);

    aggregate_stats( $results, $dp_id );

    show_interface_stats($ifinfo);
}

sub show_interface_slowpath {
    my $results = shift;
    my $intf    = shift;

    my $dp_id  = $intf->dpid();
    my $ifinfo = $results->[$dp_id];
    return unless defined($ifinfo);

    print "Dataplane interface: $ifinfo->{name}\n";
    foreach my $key ( sort keys(%$ifinfo) ) {
        my $val = $ifinfo->{$key};
        next if $key eq "name";
        printf "   %-18s : ", $key;
        if ( ref($val) ) {
            print "\n";
            printf "      %-15s : %s\n", $_, $val->{$_}
              foreach ( sort keys(%$val) );
        } else {
            printf "%s\n", $val;
        }
    }
}

# similar to the above, but show stats per-vplane
sub show_interface_per_vplane {
    my $results = shift;
    my $intf    = shift;

    my $dp_id  = $intf->dpid();
    my $ifinfo = $results->[$dp_id];
    return unless defined($ifinfo);

    show_interface_non_stats( $ifinfo, $intf );

    adjust_stats($results);

    for my $dp_id ( @{$dp_ids} ) {
        $ifinfo = $results->[$dp_id];
        next unless defined($ifinfo);

        print "  vplane $dp_id -\n" if ( $dp_id ne 0 );
        show_interface_stats($ifinfo);
    }
}

# Make sure address is in canonical Ethernet format with zero padding
sub eth_fmt {
    my $addr = shift;

    return sprintf "%02s:%02s:%02s:%02s:%02s:%02s", split /\:/, $addr;
}

sub show_interface_uptime {
    my $intf      = shift;
    my %clear     = get_clear_stats( $intf->{name}, () );
    my $timestamp = $clear{'timestamp'};
    my $transns   = $intf->opstate_changes();

    if ($transns) {
        my $opstate = $intf->operstate();
        my $age     = $intf->opstate_age();
        my $ts      = sprintf( "%.0f", clock_gettime(CLOCK_REALTIME) - $age );

        print "   Uptime: ", duration_exact($age), "\n" if ( $opstate eq 'up' );
        print "   Up transitions: ", $transns, "\n";
        print "   Last up: ", get_timestr($ts), "\n";
    }

    print "   Last clear: ", get_timestr($timestamp), "\n" if $timestamp;
}

sub show_interface_non_stats {
    my $ifinfo  = shift;
    my $intf    = shift;
    my $type    = $intf->type();
    my $ifname  = $ifinfo->{name};
    my $ifalias = read_file("/sys/class/net/$ifname/ifalias");
    chomp($ifalias);

    if ( $type eq 'dataplane' ) {
        print "Dataplane interface: $ifname\n";
    } elsif ( $type eq 'bonding' ) {
        print "Bonding interface: $ifname\n";
    }
    print "   Description: $ifalias\n"
      if length($ifalias);

    my $dev = $ifinfo->{dev};
    if ($dev) {
        print "   Driver: ", $dev->{driver}, "\n"
          if $dev->{driver};
        print "   Node: ", $dev->{node}, "\n"
          if $dev->{node};
        print " Parent: ", $dev->{parent}, "\n"
          if $dev->{parent};

        my $pci = $dev->{pci};
        if ($pci) {
            my $vendor_id = sprintf( "%.4x", $pci->{id}->{vendor} );
            my $device_id = sprintf( "%.4x", $pci->{id}->{device} );

            my $vendor = pci_vendor($vendor_id);
            $vendor = $vendor_id unless defined($vendor);

            my $device = pci_device( $vendor_id, $device_id );
            $device = $device_id unless defined($device);

            my $addr = $pci->{address};
            print "   Pci: ";
            printf "%.4x:", $addr->{domain}
              if ( $addr->{domain} != 0 );
            printf "%.2x:%.2x.%x %s:%s\n",
              $addr->{bus}, $addr->{devid}, $addr->{function},
              $vendor, $device;
        }
    }

    printf "   Port: %u, ifIndex: %d\n", $ifinfo->{port}, $ifinfo->{ifindex};
    printf "   Mac: %s", eth_fmt( $ifinfo->{ether} );
    printf "  HWid: %s", eth_fmt( $ifinfo->{perm_addr} )
      if ( $ifinfo->{perm_addr} );

    printf ", VLAN: %s", $ifinfo->{tag} if defined( $ifinfo->{tag} );
    print "\n";

    my $link = $ifinfo->{link};
    if ( defined($link) ) {
        printf "   Link: %s", $link->{up} ? "up" : "down";

        if ( defined( $link->{duplex} ) ) {
            printf ", duplex %s", $link->{duplex};
        }

        if ( defined( $ifinfo->{mtu} ) ) {
            printf ", mtu %u", $ifinfo->{mtu};
        }

        if ( defined( $link->{speed} ) ) {
            my $speed = $link->{speed};
            if ( $speed >= 1000 ) {
                $speed = ( $speed / 1000 ) . 'G';
            } else {
                $speed = $speed . 'M';
            }

            printf ", speed %s", $speed;
        }

        printf "\n";
    }

    show_interface_uptime($intf);

    print "   Addresses:\n";
    foreach my $addr ( @{ $ifinfo->{addresses} } ) {
        my $ip = $addr->{inet};
        if ($ip) {
            print "        inet $ip, broadcast ", $addr->{broadcast}, "\n";
        } elsif ( $ip = $addr->{inet6} ) {
            print "        inet6 $ip, scope ", $addr->{scope}, "\n";
        }
    }
}

# adjust stats, taking note of the clear file's values
sub adjust_stats {
    my $results = shift;

    for my $dp_id ( @{$dp_ids} ) {
        my $ifinfo = $results->[$dp_id];
        next unless defined($ifinfo);

        my $ifstat = $ifinfo->{statistics};
        my %clear =
          get_dataplane_clear_stats( $ifinfo->{name}, $dp_id, $ifstat );

        foreach my $st (@statistics) {
            my $stat_tag = $st->{tag};
            my $count    = $ifstat->{$stat_tag};
            next unless defined($count);

            $ifstat->{$stat_tag} = get_counter_val( $clear{$stat_tag}, $count );
        }
    }
}

sub show_priority_q_stats {
    my $ifstat = $_[0];

    if ( !defined( $ifstat->{qstats} ) ) {
        return;
    }

    printf "   Priority Queue Statistics:\n";

    my $lindex   = 0;
    my $hindex   = 0;
    my @qstats   = @{ $ifstat->{qstats} };
    my $nentries = @qstats;

    foreach my $qstat (@qstats) {
        $hindex++;
        my $not_all_0 = grep { $_ != 0 } values %$qstat;
        next unless $not_all_0 || $hindex == $nentries;
        if ( $lindex == $hindex - 1 ) {
            printf "      [%d]\n", $hindex - 1;
        } else {
            printf "      [%d-%d]\n", $lindex, $hindex - 1;
        }
        foreach my $key ( sort keys(%$qstat) ) {
            printf "          %-18s: %20s\n", $key, $qstat->{$key};
        }
        $lindex = $hindex;
    }

}

# sum counts etc. across vplanes
sub aggregate_stats {
    my $results      = shift;
    my $result_dp_id = shift;

    my $ifinfo = $results->[$result_dp_id];
    return unless defined($ifinfo);

    my $result_ifstat = $ifinfo->{statistics};

    for my $dp_id ( @{$dp_ids} ) {
        next if ( $dp_id eq $result_dp_id );

        $ifinfo = $results->[$dp_id];
        next unless defined($ifinfo);

        my $ifstat = $ifinfo->{statistics};

        foreach my $st (@statistics) {
            my $stat_tag = $st->{tag};
            my $count    = $ifstat->{$stat_tag};
            next unless defined($count);

            $result_ifstat->{$stat_tag} += $count;
        }

        foreach my $st (@perf_counters) {
            my $tag   = $st->{tag};
            my $count = $ifstat->{$tag};
            next unless defined($count);

            $result_ifstat->{$tag} += $count;

            my $avg        = $ifstat->{ $tag . "_avg" };
            my $result_avg = $result_ifstat->{ $tag . "_avg" };

            # one, five and ten minute averages
            $result_avg->[0] += $avg->[0];
            $result_avg->[1] += $avg->[1];
            $result_avg->[2] += $avg->[2];
        }
    }
}

sub show_interface_stats {
    my $ifinfo = shift;

    my $ifstat = $ifinfo->{statistics};

    print "   Statistics:\n";

    foreach my $st (@statistics) {
        my $stat_tag = $st->{tag};
        my $count    = $ifstat->{$stat_tag};
        next unless defined($count);
        next if ( $count eq 0 && $st->{hide} );

        printf "      %-22s: %20s\n", $st->{display}, $count;
    }

    show_priority_q_stats($ifstat);

    printf "   %-22s %10s %10s %10s %10s\n",
      "Performance:", "Current", "1 min", "5 min", "15 min";
    foreach my $st (@perf_counters) {
        my $tag   = $st->{tag};
        my $count = $ifstat->{$tag};
        next unless defined($count);

        my @avg = @{ $ifstat->{ $tag . "_avg" } };
        unshift @avg, $count;

        # convert bytes to bits
        @avg = map { $_ * 8 } @avg if ( $tag =~ /bps$/ );

        printf "      %-18s: %10s %10s %10s %10s\n", $st->{display}, @avg;
    }
}

sub iterate_dataplanes {
    my ( $intf_list_ref, $func, $vplane_cmd ) = @_;

    my @intf_list = @{$intf_list_ref};

    ( $dp_ids, $dp_conns ) = Vyatta::Dataplane::setup_fabric_conns();

    foreach my $ifname (@intf_list) {
        my $intf = new Vyatta::Interface($ifname);
        die "$ifname is not a known interface\n"
          unless defined($intf);

        die "$ifname is not a valid dataplane interface\n"
          unless defined( $intf->dpid() );

        my $response =
          vplane_exec_cmd( "$vplane_cmd $ifname", $dp_ids, $dp_conns, 1 );
        my @results;

        for my $dp_id ( @{$dp_ids} ) {
            next unless defined( $response->[$dp_id] );

            my $decoded = decode_json( $response->[$dp_id] );
            my $ifinfo  = $decoded->{interfaces}->[0];
            next unless defined($ifinfo);

            $results[$dp_id] = $ifinfo;
        }

        die "interface $ifname does not exist on system\n"
          if ( $#results < 0 );

        &$func( \@results, $intf );
    }

    Vyatta::Dataplane::close_fabric_conns( $dp_ids, $dp_conns );

}

sub clear_dataplane_interfaces {
    my $intf_list_ref = shift;

    &iterate_dataplanes( $intf_list_ref, \&clear_interface, "ifconfig" );
}

sub show_dataplane_interfaces {
    my $intf_list_ref = shift;

    &iterate_dataplanes( $intf_list_ref, \&show_interface, "ifconfig" );
}

sub show_dataplane_interfaces_slowpath {
    my $intf_list_ref = shift;

    &iterate_dataplanes( $intf_list_ref, \&show_interface_slowpath,
        "slowpath" );
}

sub show_dataplane_interfaces_per_vplane {
    my $intf_list_ref = shift;

    &iterate_dataplanes( $intf_list_ref, \&show_interface_per_vplane,
        "ifconfig" );
}

1;
