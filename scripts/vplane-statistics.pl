#! /usr/bin/perl

# Copyright (c) 2021, Ciena Corporation. All rights reserved.
# Copyright (c) 2018-2021, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2013-2015 Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

use Getopt::Long;
use JSON qw( decode_json );

use lib "/opt/vyatta/share/perl5/";
use Module::Load::Conditional qw(can_load);
use Vyatta::Dataplane;

my $vrf_available = can_load(
    modules  => { "Vyatta::VrfManager" => undef },
    autoload => "true"
);

# Output format to match BSD
sub show_arp {
    my $stat = shift;
    my $fmt  = "    %u %s\n";

    print "arp:\n";
    if ( defined( $stat->{total_added} ) ) {
        printf $fmt, $stat->{total_added},
          'Valid dynamic or static ARP entries added';
    }
    if ( defined( $stat->{total_deleted} ) ) {
        printf $fmt, $stat->{total_deleted},
          'Valid dynamic or static ARP entries deleted';
    }
    printf $fmt, $stat->{tx_request},   'ARP requests sent';
    printf $fmt, $stat->{tx_reply},     'ARP replies sent';
    printf $fmt, $stat->{rx_request},   'ARP requests received';
    printf $fmt, $stat->{rx_ignored},   'ARP requests ignored';
    printf $fmt, $stat->{rx_reply},     'ARP replies received';
    printf $fmt, $stat->{dropped},      'packets dropped due to no ARP entry';
    printf $fmt, $stat->{timeout},      'ARP entries timed out';
    printf $fmt, $stat->{duplicate_ip}, 'Duplicate IPs seen';

    if ( defined( $stat->{garp_reqs_dropped} ) ) {
        printf $fmt, $stat->{garp_reqs_dropped},
          'Gratuitous ARP requests dropped';
    }
    if ( defined( $stat->{garp_reps_dropped} ) ) {
        printf $fmt, $stat->{garp_reps_dropped},
          'Gratuitous ARP replies dropped';
    }
    if ( defined( $stat->{mpool_fail} ) ) {
        printf $fmt, $stat->{mpool_fail}, 'Mbuf pool limit hits';
    }
    if ( defined( $stat->{mem_fail} ) ) {
        printf $fmt, $stat->{mem_fail}, 'Out of memory hits';
    }
    if ( defined( $stat->{cache_limit} ) ) {
        printf $fmt, $stat->{cache_limit}, 'Cache limit hits';
    }
}

sub show_ip {
    my $stat = shift;
    my $fmt  = "    %u %s\n";

    print "ip:\n";
    printf $fmt, $stat->{InReceives},       'total packets received';
    printf $fmt, $stat->{InHdrErrors},      'with invalid headers';
    printf $fmt, $stat->{InAddrErrors},     'with invalid addresses';
    printf $fmt, $stat->{InUnknownProtos},  'with unknown protocol';
    printf $fmt, $stat->{InDiscards},       'incoming packets discarded';
    printf $fmt, $stat->{InDelivers},       'incoming packets delivered';
    printf $fmt, $stat->{OutForwDatagrams}, 'forwarded';
    printf $fmt, $stat->{OutRequests},      'requests sent out';
    printf $fmt, $stat->{OutDiscards},      'outgoing packets dropped';
    printf $fmt, $stat->{OutNoRoutes},      'dropped because of missing route';
    printf $fmt, $stat->{FragOKs},          'fragments received ok';
    printf $fmt, $stat->{FragFails},        'fragments failed';
    printf $fmt, $stat->{FragCreates},      'fragments created';
}

# Output the count for each message type
sub icmp_msg_types {
    my ( $stat, $dir ) = @_;
    my $msg_exists = 0;
    my %types      = (
        'DestUnreachs'  => 'destination unreachable',
        'TimeExcds'     => 'timeout in transit',
        'ParmProbs'     => 'wrong parameters',
        'SrcQuenchs'    => 'source quenches',
        'Redirects'     => 'redirects',
        'Echos'         => 'echo requests',
        'EchoReps'      => 'echo replies',
        'Timestamps'    => 'timestamp request',
        'TimestampReps' => 'timestamp reply',
        'AddrMasks'     => 'address mask request',
        'AddrMaskReps'  => 'address mask replies',
    );

    foreach my $key ( sort keys %types ) {
        my $val = $stat->{"$dir$key"};

        next if ( $val eq 0 );
        $msg_exists = 1;
        printf "        %s: %u\n", $types{$key}, $val;
    }

    if ( !$msg_exists ) {
        print "        none\n";
    }
}

sub show_icmp {
    my $stat = shift;
    my $fmt  = "    %u %s\n";

    print "icmp:\n";
    printf $fmt, $stat->{InMsgs},   "ICMP messages received";
    printf $fmt, $stat->{InErrors}, "input ICMP message failed";
    print "    ICMP received message types:\n";
    icmp_msg_types( $stat, 'In' );

    printf $fmt, $stat->{OutMsgs},   "ICMP messages sent";
    printf $fmt, $stat->{OutErrors}, "ICMP messages failed";
    print "    ICMP sent message types:\n";
    icmp_msg_types( $stat, 'Out' );
}

sub show_ip6 {
    my $stat = shift;
    my $fmt  = "    %u %s\n";

    print "ip6:\n";
    printf $fmt, $stat->{InReceives},       'total packets received';
    printf $fmt, $stat->{InHdrErrors},      'with invalid headers';
    printf $fmt, $stat->{InTooBigErrors},   'with packets too big';
    printf $fmt, $stat->{InNoRoutes},       'incoming packets with no route';
    printf $fmt, $stat->{InAddrErrors},     'with invalid addresses';
    printf $fmt, $stat->{InUnknownProtos},  'with unknown protocol';
    printf $fmt, $stat->{InTruncatedPkts},  'with truncated packets';
    printf $fmt, $stat->{InDiscards},       'incoming packets discarded';
    printf $fmt, $stat->{InDelivers},       'incoming packets delivered';
    printf $fmt, $stat->{OutForwDatagrams}, 'forwarded';
    printf $fmt, $stat->{OutRequests},      'requests sent out';
    printf $fmt, $stat->{OutDiscards},      'outgoing packets dropped';
    printf $fmt, $stat->{OutNoRoutes},      'dropped because of missing route';
    printf $fmt, $stat->{FragOKs},          'fragments received ok';
    printf $fmt, $stat->{FragFails},        'fragments failed';
    printf $fmt, $stat->{FragCreates},      'fragments created';
    printf $fmt, $stat->{InMcastPkts},      'incoming multicast packets';
    printf $fmt, $stat->{OutMcastPkts},     'outgoing multicast packets';
}

# Output the count for each message type
sub icmp6_msg_types {
    my ( $stat, $dir ) = @_;
    my $msg_exists = 0;
    my %types      = (
        'DestUnreachs'           => 'destination unreachable',
        'PktTooBigs'             => 'packets too big',
        'TimeExcds'              => 'received ICMPv6 time exceeded',
        'ParmProblems'           => 'parameter problem',
        'Echos'                  => 'echo requests',
        'EchoReplies'            => 'echo replies',
        'GroupMembQueries'       => 'group member queries',
        'GroupMembResponses'     => 'group member responses',
        'GroupMembReductions'    => 'group member reductions',
        'RouterSolicits'         => 'router solicits',
        'RouterAdvertisements'   => 'router advertisement',
        'NeighborSolicits'       => 'neighbour solicits',
        'NeighborAdvertisements' => 'neighbour advertisement',
        'Redirects'              => 'redirects',
    );

    foreach my $key ( sort keys %types ) {
        my $val = $stat->{"$dir$key"};

        next unless defined($val);
        next if ( $val eq 0 );
        $msg_exists = 1;
        printf "        %s: %u\n", $types{$key}, $val;
    }

    if ( !$msg_exists ) {
        print "        none\n";
    }
}

sub show_icmp6 {
    my $stat = shift;
    my $fmt  = "    %u %s\n";

    print "icmp6:\n";
    printf $fmt, $stat->{InMsgs},   "ICMP messages received";
    printf $fmt, $stat->{InErrors}, "input ICMP message failed";
    print "    ICMP received message types:\n";
    icmp6_msg_types( $stat, 'In' );

    printf $fmt, $stat->{OutMsgs},   "ICMP messages sent";
    printf $fmt, $stat->{OutErrors}, "ICMP messages failed";
    print "    ICMP sent message types:\n";
    icmp6_msg_types( $stat, 'Out' );
}

sub show_nd6 {
    my $stat = shift;

    my $fmt = "    %-21s:  %u\n";
    print "nd6:\n";
    printf $fmt, 'ND packets received',  $stat->{nd_received};
    printf $fmt, 'ND requests ignored',  $stat->{rx_ignored};
    printf $fmt, 'NA received',          $stat->{na_rx};
    printf $fmt, 'NA transmitted',       $stat->{na_tx};
    printf $fmt, 'NS received',          $stat->{ns_rx};
    printf $fmt, 'NS transmitted',       $stat->{ns_tx};
    printf $fmt, 'NS/NA punted',         $stat->{nd_punt};
    printf $fmt, 'Duplicate IPs seen',   $stat->{duplicate_ip};
    printf $fmt, 'Dropped packets',      $stat->{dropped};
    printf $fmt, 'Bad packets',          $stat->{bad_packet};
    printf $fmt, 'Resolution failures',  $stat->{timeouts};
    printf $fmt, 'NUD failures',         $stat->{nud_fail};
    printf $fmt, 'Resolution throttles', $stat->{res_throttle};
    printf $fmt, 'Cache limit hits',     $stat->{cache_limit};

    if ( defined( $stat->{mpool_fail} ) ) {
        printf $fmt, 'Mbuf pool limit hits', $stat->{mpool_fail};
    }
}

my %handlers = (
    'arp'   => \&show_arp,
    'ip'    => \&show_ip,
    'icmp'  => \&show_icmp,
    'ip6'   => \&show_ip6,
    'icmp6' => \&show_icmp6,
    'nd6'   => \&show_nd6,
);

sub usage {
    my $ri_opt_str = " ";

    if ($vrf_available) {
        $ri_opt_str = " [--routing-instance=<NAME>] ";
    }

    print "Usage: $0 [--fabric=N]" . $ri_opt_str . " <CMD>\n";
    print "  CMD := ", join( ' | ', keys %handlers ), "\n";
    exit 1;
}

my ( $fabric, $routing_instance_name );

if ($vrf_available) {
    GetOptions(
        'fabric=s'           => \$fabric,
        'routing-instance=s' => \$routing_instance_name,
    ) or usage();
} else {
    GetOptions( 'fabric=s' => \$fabric, ) or usage();
}

my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns($fabric);
die "Dataplane $fabric is not connected or does not exist\n"
  unless ( scalar(@$dpids) > 0 );

for my $fid (@$dpids) {

    my $response;
    my $sock = ${$dpsocks}[$fid];
    die "Can not connect to dataplane $fid\n"
      unless defined($sock);

    if ( $vrf_available and $routing_instance_name ) {

        my $routing_instance_id =
          Vyatta::VrfManager::get_vrf_id($routing_instance_name);

        # dummy assign to avoid '..VRFID_INVALID used once: ..' warning
        $Vyatta::VrfManager::VRFID_INVALID = $Vyatta::VrfManager::VRFID_INVALID;
        if ( $routing_instance_id == $Vyatta::VrfManager::VRFID_INVALID ) {
            die "$routing_instance_name is not a valid routing-instance\n";
        }
        $response = $sock->execute("netstat vrf_id $routing_instance_id");

    } else {
        $response = $sock->execute('netstat');
    }

    die "No response from dataplane $fid\n"
      unless ( defined($response) );
    my $decoded = decode_json($response);

    foreach my $arg (@ARGV) {
        my $hdl = $handlers{$arg};
        die "No handler function for $arg\n"
          unless defined($hdl);

        my $stat = $decoded->{$arg};
        die "No $arg in response\n"
          unless $stat;

        die "Unknown handler for: $arg\n"
          unless $hdl;

        print "vplane $fid - "
          unless $fid == 0;
        $hdl->($stat);
    }
}
Vyatta::Dataplane::close_fabric_conns( $dpids, $dpsocks );
