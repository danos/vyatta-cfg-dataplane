#! /usr/bin/perl

# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2013-2015 Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;
use Readonly;

use Getopt::Long;
use JSON qw( decode_json encode_json );
use Data::Validate::IP qw(is_ipv4 is_ipv6);
use IPC::System::Simple qw(capture);

use lib "/opt/vyatta/share/perl5/";
use Module::Load::Conditional qw(can_load);
use Vyatta::Dataplane;

my $vrf_available = can_load(
    modules  => { "Vyatta::VrfManager" => undef },
    autoload => "true"
);

my $route_segment_cnt = 1000;

#vyatta@vyatta:~$ /opt/vyatta/bin/vplsh -l -c "route table 254"
#0.0.0.0/0 non-dataplane interface
#192.168.122.0/24 non-dataplane interface
#198.18.4.0/24 is directly connected, dp0port1
#198.18.5.0/24 is directly connected, dp0port0

Readonly::Hash my %mpls_reserved_labels => (
    EXPNULL  => 0,
    RTRALRT  => 1,
    EXP6NULL => 2,
    IMPNULL  => 3,
);

sub show_route_summary {
    my ( $af_cmd, $decoded ) = @_;
    my $entry = $decoded->{ $af_cmd . '_stats' };

    my $prefix = $entry->{prefix};
    print "Prefix:\n";
    foreach my $depth ( sort keys %$prefix ) {
        printf "	/%u\t%u\n", $depth, $prefix->{$depth};
    }
    printf "Total: %u\n", $entry->{total};

    my $hop = $entry->{nexthop};
    printf "Nexthop: %u used %u free\n", $hop->{used}, $hop->{free};
}

sub show_label_decode {
    my ($label) = @_;

    if ( $label eq $mpls_reserved_labels{EXPNULL} ) {
        print "exp-null";
    } elsif ( $label eq $mpls_reserved_labels{RTRALRT} ) {
        print "rtr-alrt";
    } elsif ( $label eq $mpls_reserved_labels{EXP6NULL} ) {
        print "exp6-null";
    } elsif ( $label eq $mpls_reserved_labels{IMPNULL} ) {
        print "imp-null";
    } else {
        print "$label";
    }
}

sub show_labels {
    my ($labels) = @_;

    my $plural = ( scalar @$labels > 1 ) ? "s" : "";
    printf ", outgoing label%s: ", $plural;
    foreach my $label (@$labels) {
        show_label_decode($label);
        print " ";
    }
}

sub show_destination {
    my ( $sock, $entry, $sep, $detail_level ) = @_;

    if ( $entry->{state} eq 'gateway' ) {
        printf "%svia %s", $sep, $entry->{via};
    } else {
        printf "%s%s", $sep, $entry->{state};
    }

    my $ifname = $entry->{ifname};
    print ", $ifname" if $ifname;

    show_labels( $entry->{labels} ) if $entry->{labels};

    print " dead"                       if $entry->{dead};
    print " dynamic"                    if $entry->{dynamic};
    print " static"                     if $entry->{static};
    print " created-by-neighbour-entry" if $entry->{neigh_created};
    print " backup"                     if $entry->{backup};

    if ( $detail_level >= 1 ) {
        print " linked-to-neighbour" if $entry->{neigh_present};
        if ( defined( $entry->{platform_state} ) ) {
            print "\n\t  platform state:\n";
            my $pd_state =
              $sock->format_platform_state( 'route-nh', encode_json($entry) );

            # remove newline since this will be added by the separator
            chomp $pd_state;
            print $pd_state;
        }
    }
}

sub show_nexthop {
    my ( $sock, $prefix, $nexthop, $detail_level ) = @_;

    print $prefix;

    $nexthop = [$nexthop] if ref($nexthop) ne 'ARRAY';

    my $sep =
      ( scalar @$nexthop > 1 || @$nexthop[0]->{platform_state} )
      ? "\n\tnexthop "
      : " ";
    foreach my $entry (@$nexthop) {
        show_destination( $sock, $entry, $sep, $detail_level );
    }

    print "\n";
}

sub show_route_lookup {
    my ( $sock, $af_cmd, $decoded ) = @_;
    my $result = $decoded->{ $af_cmd . '_lookup' };

    foreach my $rt (@$result) {
        my $addr = defined( $rt->{prefix} ) ? $rt->{prefix} : $rt->{address};
        my $nexthop = $rt->{next_hop};

        if ( defined( $rt->{nhg_platform_state} ) ) {
            my $pd_state =
              $sock->format_platform_state( 'route-nhg', encode_json($rt) );

            # remove newline since this will be added by the separator
            # in show_nexthop
            chomp $pd_state;
            $addr .= "\n\tplatform state:\n" . $pd_state;
        }

        if ($nexthop) {
            show_nexthop( $sock, $addr, $nexthop, 1 );
        } else {
            warn "no route to $addr\n" unless $nexthop;
        }
    }
}

sub show_route {
    my ( $sock, $af_cmd, $decoded ) = @_;
    my $result = $decoded->{ $af_cmd . '_show' };
    my $addr   = 0;
    my $depth  = 0;

    foreach my $route (@$result) {
        if ( $route->{prefix} eq 'more' ) {
            return ( 'more', $addr, $depth );
        }
        show_nexthop( $sock, $route->{prefix}, $route->{next_hop}, 0 );
        ( $addr, $depth ) = split( '/', $route->{prefix} );
    }

    return ( 'end', $addr, $depth );
}

sub label_table_fec_hash {
    my ($withprefix) = @_;
    my %config_fec   = ();
    my %tmp_fec      = ();

    return \%config_fec unless $withprefix;

    my $cmd = capture("opc show mpls label-table");
    my @lines = split /\n/, $cmd;
    foreach my $line (@lines) {
        my ( $select, $fec, $inlbl, $outlbl ) = split( ' ', $line );
        next unless ( defined($select) && $select =~ />/ );
        $config_fec{$inlbl}{fec} = $fec;
        $tmp_fec{$fec} = $fec;
    }

    $cmd = capture("opc show mpls forwarding");
    @lines = split /\n/, $cmd;
    foreach my $line (@lines) {
        my ( $select, $fec, $nh, $outlbl ) = split( ' ', $line );
        next unless ( defined($select) && $select =~ />/ );
        $tmp_fec{$fec} = $fec;
    }

    foreach my $fec ( keys %tmp_fec ) {
        if ( index( $fec, ':' ) >= 0 ) {
            $cmd = capture("opc show ipv6 route $fec");
        } else {
            $cmd = capture("opc show ip route $fec");
        }
        @lines = split /\n/, $cmd;
        foreach my $line (@lines) {
            my ( $local, $label, $intlbl ) = split( ' ', $line );
            next unless ( defined($local) && $local eq "Local" );
            next unless defined($intlbl);
            $config_fec{$intlbl}{fec}      = $fec;
            $config_fec{$intlbl}{internal} = $fec;
            last;
        }
    }
    return \%config_fec;
}

sub get_fec {
    my ( $route, $ref ) = @_;
    my %ihash = %{$ref};

    my $fec    = $ihash{ $route->{address} }{fec};
    my $intlbl = $ihash{ $route->{address} }{internal};

    return ( $fec, $intlbl );
}

sub show_fec {
    my ( $route, $fec ) = @_;

    if ( $route->{payload} ) {
        print ", fec:";
        my $payload = $route->{payload};
        if ( $payload eq 4 ) {
            print "ipv4";
        } elsif ( $payload eq 6 ) {
            print "ipv6";
        } else {
            print "$payload";
        }
        if ( defined($fec) ) {
            print " $fec";
        }
    }
}

sub show_mpls_route {
    my ( $sock, $route, $ref ) = @_;

    my $next_hops = $route->{next_hop};
    ( my $fec, my $local ) = get_fec( $route, $ref );

    printf "in label: ";
    show_label_decode( $route->{address} );
    if ( defined($local) ) {
        printf " (local)";
    }
    show_fec( $route, $fec );
    foreach my $nexthop (@$next_hops) {
        my $labels = $nexthop->{labels};
        if ( $nexthop->{state} eq 'gateway' ) {
            print "\n\tnexthop";
            show_destination( $sock, $nexthop, " ", 0 );
        } else {
            show_labels($labels) if $labels;
        }
    }
    print "\n";
}

sub show_label_table {
    my ( $sock, $decoded, $withprefix, $inlabel ) = @_;
    my $tables = $decoded->{mpls_tables};

    my $ref = label_table_fec_hash($withprefix);

    foreach my $table (@$tables) {
        my $route = $table->{mpls_routes};
        print "Label Space: $table->{lblspc}\n";
        foreach my $route ( sort { $a->{address} <=> $b->{address} } @$route ) {
            if ( defined($inlabel) && $route->{address} ne $inlabel ) {
                next;
            }
            show_mpls_route( $sock, $route, $ref );
        }
    }
}

sub function_exists {
    no strict 'refs';
    my $funcname = shift;
    return \&{$funcname} if defined &{$funcname};
    return;
}

my ( $fabric, $table, $v6, $summary, $ip, $routing_instance_name );
my ( $labeltable, $withprefix, $inlabel, $all );

sub usage {

    my $ri_opt_str = " ";

    if ($vrf_available) {
        $ri_opt_str = " [--routing-instance=<NAME>] ";
    }
    print "Usage: $0 [--fabric=N]" . $ri_opt_str . "[table=N] [--v6] [--all] \n";
    print "       $0 --summary" . $ri_opt_str . "[--v6]\n";
    print "       $0 --lookup <ADDR>" . $ri_opt_str . "[--v6]\n";
    print "       $0 --label-table [--with-prefix]\n";
    print "       $0 --in-label <NUM>\n";
}

if ($vrf_available) {
    GetOptions(
        "fabric=s"           => \$fabric,
        "routing-instance=s" => \$routing_instance_name,
        "table=s"            => \$table,
        "v6"                 => \$v6,
        "summary"            => \$summary,
        "lookup=s"           => \$ip,
        "label-table"        => \$labeltable,
        "with-prefix"        => \$withprefix,
        "in-label=s"         => \$inlabel,
        "all"                => \$all,
    ) or usage();

} else {
    GetOptions(
        "fabric=s"    => \$fabric,
        "table=s"     => \$table,
        "v6"          => \$v6,
        "summary"     => \$summary,
        "lookup=s"    => \$ip,
        "label-table" => \$labeltable,
        "with-prefix" => \$withprefix,
        "in-label=s"  => \$inlabel,
        "all"         => \$all,
    ) or usage();
}

my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns($fabric);
die "Dataplane $fabric is not connected or does not exist\n"
  unless ( !defined($fabric) || scalar(@$dpids) > 0 );

my $af_cmd = 'route';
$af_cmd .= '6' if $v6;

my $cmd = $labeltable ? 'mpls show tables' : $af_cmd;

if ( $vrf_available and $routing_instance_name ) {
    my $routing_instance_id =
      Vyatta::VrfManager::get_vrf_id($routing_instance_name);

    # dummy assign to avoid '..VRFID_INVALID used once: ..' warning
    $Vyatta::VrfManager::VRFID_INVALID = $Vyatta::VrfManager::VRFID_INVALID;
    if ( $routing_instance_id == $Vyatta::VrfManager::VRFID_INVALID ) {
        die "$routing_instance_name is not a valid routing-instance\n";
    }
    $cmd .= " vrf_id $routing_instance_id";
}

if (    $table
    and $vrf_available
    and $routing_instance_name
    and my $get_vrf_name_map =
    function_exists("Vyatta::VrfManager::get_vrf_name_map") )
{
    my $name_hash = &$get_vrf_name_map();

    die "Unknown VRF and table $routing_instance_name $table"
      if !defined( $name_hash->{$routing_instance_name} )
      || !defined( $name_hash->{$routing_instance_name}{$table} );

    $cmd .= " table " . $name_hash->{$routing_instance_name}{$table};
} else {
    $cmd .= " table $table" if $table;
}

$cmd .= " summary" if $summary;

$cmd .= " all" if $all;

if ($ip) {
    ( my $addr, my $depth ) = split( '/', $ip );
    $ip = $addr if defined $addr;
    if ($v6) {
        is_ipv6($ip) or die "$ip is not a valid IPv6 address\n";
    } else {
        is_ipv4($ip) or die "$ip is not a valid IPv4 address\n";
    }

    $cmd .= " lookup $ip";
    $cmd .= " $depth" if defined $depth;
}

if ( !$table && !$summary && !$ip ) {
    $cmd .= " show $route_segment_cnt";
}

for my $fid (@$dpids) {
    my $sock    = ${$dpsocks}[$fid];
    my $ret     = 'end';
    my $cmd_tmp = $cmd;
    die "Can not connect to dataplane $fid\n"
      unless defined($sock);

    print "\nvplane $fid:\n\n"
      unless ( $fid == 0 );

    do {
        my $response = $sock->execute($cmd);
        exit 1 unless defined($response);

        my $decoded = decode_json($response);

        if ($summary) {
            show_route_summary( $af_cmd, $decoded );
        } elsif ($labeltable) {
            show_label_table( $sock, $decoded, $withprefix, $inlabel );
        } elsif ($ip) {
            show_route_lookup( $sock, $af_cmd, $decoded );
        } else {
            ( $ret, my $addr, my $depth ) =
              show_route( $sock, $af_cmd, $decoded );
            $cmd = " $af_cmd show get-next $addr $depth $route_segment_cnt";
        }
    } while ( $ret eq 'more' );

    $cmd = $cmd_tmp;
}
Vyatta::Dataplane::close_fabric_conns( $dpids, $dpsocks );
