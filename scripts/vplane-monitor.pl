#! /usr/bin/perl

# Copyright (c) 2021, Ciena Corporation. All rights reserved.
# Copyright (c) 2017,2021, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2013-2015 Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

use Getopt::Long;
use Term::Cap;
use IO::Handle;
use JSON qw( decode_json );
use Sort::Key::Natural qw(natsort);

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Dataplane;

my $CTRL_CFG    = "/etc/vyatta/controller.conf";
my $oneshot_fmt = "%-10s %16s %-5s %16s %-5s %9s %9s %5s %5s\n";
my ( $dp_ids, $dp_conns, $local_controller );

# condense pps value
sub fmt_pps {
    my $pps = shift;

    return "" if !defined($pps);

    return sprintf( "%.1fM", $pps / 1000000 )
      if ( $pps >= 1000000 );

    return sprintf( "%.1fK", $pps / 1000 )
      if ( $pps >= 1000 );

    return $pps;
}

# format a value that may be undefined
sub fmt_undef {
    my $value = shift;

    return "" if !defined($value);

    return $value;
}

sub usage {
    print "Usage: $0 [--refresh I] [--fabric F]\n";
    exit 1;
}

# from Perl Cookbook
sub get_cls {
    my $OSPEED = 9600;
    eval {
        require POSIX;
        my $termios = POSIX::Termios->new();
        $termios->getattr;
        $OSPEED = $termios->getospeed;
    };
    my $terminal = Term::Cap->Tgetent( { OSPEED => $OSPEED } );

    return $terminal->Tputs('cl');
}

sub idle {
    my $ticks = shift;

    if ( $ticks < 1000 ) {
        return $ticks . ' µs';
    } else {
        return sprintf "%.1f ms", $ticks / 1000.;
    }
}

# repeated display with screen clear
# could use curses?
sub show_repeated {
    my ( $refresh, $count ) = @_;
    my $clear   = get_cls();
    my $pfx     = "";
    my $hdr_pfx = "";

    # Output format like bmon
    my $fmt = "%-4s %-10s %3s %3s  %8s   %8s   %-8s\n";
    if ( !$local_controller ) {
        $fmt     = "%-5s " . $fmt;
        $hdr_pfx = "DP   ";
    } else {
        $fmt = "%.0s" . $fmt;
    }

    while (1) {

        # Clear may be undefined when redirecting output to a file
        print $clear if defined($clear);
        print "Dataplane CPU activity\n\n";
        printf $fmt, $hdr_pfx, "Core", "Interface", "RXQ", "TXQ", "RX Rate",
          "TX Rate",
          "Idle";
        print "-----------------------------------------------------\n";
        for my $dp_id ( @{$dp_ids} ) {
            my $sock = ${$dp_conns}[$dp_id];

            next unless $sock;
            my $response = $sock->execute('cpu');
            if ( defined($response) ) {
                if ( !$local_controller ) {
                    $pfx = "dp$dp_id";
                }
                my $decoded = decode_json($response);
                my @lcore   = @{ $decoded->{lcore} };

                foreach my $i ( 0 .. $#lcore ) {
                    my $conf = $lcore[$i];
                    my $cpu  = $conf->{core};

                    foreach my $rx ( @{ $conf->{rx} } ) {
                        my $rate = fmt_pps( $rx->{rate} );
                        my $rxq  = '?';
                        if ( defined $rx->{queue} && length $rx->{queue} > 0 ) {
                            $rxq = $rx->{queue};
                        }

                        my $txq = $rx->{directpath} eq "yes" ? "  >" : "  -";

                        printf $fmt, $pfx, $cpu, $rx->{interface},
                          $rxq, $txq, $rate, '-', idle( $rx->{idle} );
                        $cpu = ' ';
                    }

                    foreach my $tx ( @{ $conf->{tx} } ) {
                        my $rate = fmt_pps( $tx->{rate} );
                        my $txq  = '0';
                        if ( defined $tx->{queue} && length $tx->{queue} > 0 ) {
                            $txq = $tx->{queue};
                        }

                        printf $fmt, $pfx, $cpu, $tx->{interface},
                          '-', $txq, '-', $rate, idle( $tx->{idle} );
                        $cpu = ' ';
                    }
                }
            }
        }

        print "\n\nkey:\n";
        print " > the interface is using directpath forwarding.\n";
        print " - not applicable.\n\n";
        STDOUT->flush();
        last            if ( defined($count) && --$count == 0 );
        sleep($refresh) if defined($refresh);
    }
}

# Take parsed JSON response and make summary of cores -> interfaces
sub sum_cores {
    my ( $sum, $decoded ) = @_;
    my @lcore = @{$decoded};

    foreach my $i ( 0 .. $#lcore ) {
        my $conf = $lcore[$i];

        foreach my $rx ( @{ $conf->{rx} } ) {
            my $name = $rx->{interface};
            my $intf = $sum->{$name};

            if ($intf) {
                $intf->{rx_packets} += $rx->{packets};
                $intf->{rx_rate}    += $rx->{rate};
                $intf->{rxq}        += 1;
            } else {
                $intf->{rx_packets} = $rx->{packets};
                $intf->{rx_rate}    = $rx->{rate};
                $intf->{rxq}        = 1;
                $intf->{txq}        = $rx->{directpath} eq "yes" ? "  >" : 0;
                $sum->{$name}       = $intf;
            }
        }

        foreach my $tx ( @{ $conf->{tx} } ) {
            my $name = $tx->{interface};
            my $intf = $sum->{$name};

            if ($intf) {
                $intf->{tx_packets} += $tx->{packets};
                $intf->{tx_rate}    += $tx->{rate};
                $intf->{txq}        += 1;
            } else {
                $intf->{tx_packets} = $tx->{packets};
                $intf->{tx_rate}    = $tx->{rate};
                $intf->{txq}        = 1;
                $sum->{$name}       = $intf;
            }

        }
    }
}

# Add on slow path statistics
sub slow_path {
    my ( $sum, $decoded ) = @_;

    foreach my $rec ( @{$decoded} ) {
        my $name = $rec->{name};
        my $intf;

        $name         = "[Others]" if ( $name eq ".spathintf" );
        $sum->{$name} = {}         if !defined( $sum->{$name} );
        $intf         = $sum->{$name};

        $intf->{slow_in}  = $rec->{rx_packet};
        $intf->{slow_out} = $rec->{tx_packet};
    }
}

# Get stats from the driver if we haven't already got them from the cpu
sub driver_stats {
    my ( $sock, $sum ) = @_;

    foreach my $name ( keys %{$sum} ) {
        my $intf = $sum->{$name};

        if (   !defined( $intf->{rx_packets} )
            or !defined( $intf->{tx_packets} ) )
        {
            my $response = $sock->execute("ifconfig $name");

            return unless defined($response);

            my $decoded = decode_json($response);

            if ( @{ $decoded->{interfaces} } == 1 ) {

                # We have a single interface, hence array-index 0 is okay
                my $if_data = ${ $decoded->{interfaces} }[0];

                return unless ( $name eq $if_data->{name} );

                if ( !defined( $intf->{rx_packets} ) ) {
                    $intf->{rx_packets} = $if_data->{statistics}->{rx_packets};
                    $intf->{rx_rate}    = $if_data->{statistics}->{rx_pps};
                }

                if ( !defined( $intf->{tx_packets} ) ) {
                    $intf->{tx_packets} = $if_data->{statistics}->{tx_packets};
                    $intf->{tx_rate}    = $if_data->{statistics}->{tx_pps};
                }
            }
        }
    }
}

sub show_oneshot_hdr {
    print
"                    RX                     TX                   Slow Path     RXQs  TXQs \n";
    printf $oneshot_fmt, "Interface", "Packets", "Rate", "Packets", "Rate",
      "In", "Out", " ", " ";
    print
"-----------------------------------------------------------------------------------------\n";
}

sub show_oneshot_single {
    my ($sock) = @_;

    my $response = $sock->execute('cpu');
    exit 1 unless defined($response);

    my $summary = {};
    my $decoded = decode_json($response);

    sum_cores( $summary, $decoded->{lcore} );

    $response = $sock->execute('slowpath');

    exit 1 unless defined($response);

    $decoded = decode_json($response);
    slow_path( $summary, $decoded->{interfaces} );

    driver_stats( $sock, $summary );

    foreach my $ifname ( natsort( keys %{$summary} ) ) {
        my $stats = $summary->{$ifname};
        printf $oneshot_fmt, $ifname,
          fmt_undef( $stats->{rx_packets} ), fmt_pps( $stats->{rx_rate} ),
          fmt_undef( $stats->{tx_packets} ), fmt_pps( $stats->{tx_rate} ),
          fmt_undef( $stats->{slow_in} ),    fmt_undef( $stats->{slow_out} ),
          fmt_undef( $stats->{rxq} ),        fmt_undef( $stats->{txq} );
    }
}

sub show_oneshot_key {
    print "\n\nkey:\n";
    print " > the interface is using directpath forwarding.\n";
    STDOUT->flush();
}

sub show_oneshot {

    show_oneshot_hdr();

    for my $i ( 0 .. $#{$dp_ids} ) {
        my $dp_id = ${$dp_ids}[$i];
        my $sock  = ${$dp_conns}[$dp_id];
        if ( defined($sock) ) {
            show_oneshot_single($sock);
        }
    }

    show_oneshot_key();
}

my ( $fabric, $refresh, $count );

GetOptions(
    'fabric=s'  => \$fabric,
    'count=s'   => \$count,
    'refresh=s' => \$refresh,
) or usage();

( $dp_ids, $dp_conns, $local_controller ) =
  Vyatta::Dataplane::setup_fabric_conns($fabric);

if ($refresh) {
    show_repeated( $refresh, $count );
} else {
    show_oneshot();
}
Vyatta::Dataplane::close_fabric_conns( $dp_ids, $dp_conns );
