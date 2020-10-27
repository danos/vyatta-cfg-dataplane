#
# Module: Vyatta::EthernetInfo.pm
#
# Copyright (c) 2019-2020, AT&T Intellectual Property.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#

package Vyatta::EthernetInfo;

use strict;
use warnings;
use JSON;
use Vyatta::Dataplane qw(vplane_exec_cmd);

sub get_ether_info {

    my ( $port_name, $objref ) = @_;
    my %params = %{$objref};

    my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns();

    my $resp = vplane_exec_cmd( "ifconfig $port_name", $dpids, $dpsocks, 1 );

    # Decode the response from each vplane
    for my $dpid ( @{$dpids} ) {
        next unless defined( $resp->[$dpid] );
        my $decoded = decode_json( $resp->[$dpid] );
        next unless defined( $decoded->{'interfaces'} );
        my $interface = $decoded->{'interfaces'}[0];
        my $eth_info  = $interface->{'eth-info'};
        next unless defined($eth_info);
        my $pause = $eth_info->{'pause-mode'};
        $params{'pause-frame'} = $pause;
    }
    Vyatta::Dataplane::close_fabric_conns( $dpids, $dpsocks );
    my $output = { 'ethernet-info' => \%params, };

    return $output;
}

#
# $port = Vyatta::EthernetInfo->new($port_name);
#
sub new {

    my ( $class, $port_name, $debug ) = @_;
    my $objref = {};

    $objref = get_ether_info( $port_name, $objref );

    bless $objref, $class;
    return $objref;
}

1;
