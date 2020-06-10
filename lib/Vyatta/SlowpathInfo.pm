#
# Module: Vyatta::SlowpathInfo.pm
#
# Copyright (c) 2020, AT&T Intellectual Property.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#

package Vyatta::SlowpathInfo;

use strict;
use warnings;
use JSON;
use POSIX qw(log10);
use Vyatta::Dataplane qw(vplane_exec_cmd);

#
# Get port Slowpath Info
#
sub get_slowpath_info {
    my ( $port_name, $objref ) = @_;
    my %params = %{$objref};

    my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns();

    my $resp = vplane_exec_cmd( "slowpath $port_name", $dpids, $dpsocks, 1 );

    # Decode the response from each vplane
    for my $dpid ( @{$dpids} ) {
        next unless defined( $resp->[$dpid] );
        my $decoded = decode_json( $resp->[$dpid] );
        next unless defined( $decoded->{'interfaces'} );
        my $interface = $decoded->{'interfaces'}[0];

        $params{'name'}         = $interface->{'name'};
        $params{'rx_packet'}    = $interface->{'rx_packet'};
        $params{'rx_dropped'}   = $interface->{'rx_dropped'};
        $params{'rx_errors'}    = $interface->{'rx_errors'};
        $params{'rx_congested'} = $interface->{'rx_congested'};
        $params{'rx_overrun'}   = $interface->{'rx_overrun'};
        $params{'tx_packet'}    = $interface->{'tx_packet'};
        $params{'tx_errors'}    = $interface->{'tx_errors'};
        $params{'tx_nobufs'}    = $interface->{'tx_nobufs'};

        my $rx_ring = $interface->{'rx_ring'};
        $params{'rx_ring'} = {
            'avail' => $rx_ring->{'avail'},
            'used'  => $rx_ring->{'used'}
        };
    }
    Vyatta::Dataplane::close_fabric_conns( $dpids, $dpsocks );

    my $output = { 'slowpath-info' => \%params, };

    return $output;
}

#
# $port = Vyatta::SlowpathInfo->new($port_name);
#
sub new {
    my ( $class, $port_name, $debug ) = @_;
    my $objref = {};

    $objref = get_slowpath_info( $port_name, $objref );
    bless $objref, $class;
    return $objref;
}

1;
