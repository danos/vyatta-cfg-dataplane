# Module: Dataplane.pm
#
# Wrapper for accessing dataplane for status commands

# Copyright (c) 2017-2020, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2013-2015 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::Dataplane;
use strict;
use warnings;
require Exporter;

our @ISA = qw(Exporter);

our @EXPORT =
  qw(vplane_exec_cmd vplane_exec_pb_cmd get_vplane_info controller_command is_dp_connected);

use Carp;
use Config::Tiny;
use ZMQ::Constants
  qw(ZMQ_REQ ZMQ_RCVMORE ZMQ_POLLIN ZMQ_LINGER ZMQ_IPV4ONLY ZMQ_SNDMORE);
use ZMQ::LibZMQ3;
use JSON qw(decode_json);
use IPC::Run3 qw( run3 );

use Google::ProtocolBuffers;
use lib "/usr/share/perl5/vyatta/proto";
use DataplaneEnvelope;

my $CTRL_CFG  = "/etc/vyatta/controller.conf";
my $LOCAL_IPC = "ipc:///var/run/vplane.socket";
my $TIMEOUT = 10000;    # timeout in milliseconds, so this is 10 sec

my $PLATFORM_STATE_CMD = "/opt/vyatta/bin/vyatta-platform-util";

# Create one ZMQ context when object is loaded
# -- ok to create multiple instances each with own socketsa
my $zctx = zmq_ctx_new();

# Open new socket to dataplane
# This is really a derived class of ZMQ socket
# Only valid in operational mode;
#   config should never talk to dataplane directly!
sub new {
    my ( $class, $fabric, $endpoint ) = @_;
    if ( !defined $endpoint ) {
        $endpoint = _address($fabric);
    }

    my $sock = zmq_socket( $zctx, ZMQ_REQ );
    croak "ZMQ socket failed"
      unless defined($sock);

    die "Unable to set socket option to allow IPv6 too\n"
      unless ( zmq_setsockopt( $sock, ZMQ_IPV4ONLY, 0 ) == 0 );

    unless ( zmq_connect( $sock, $endpoint ) == 0 ) {
        carp "Can not connect to $endpoint\n";
        return;    #undef;
    }

    carp "Unable to set zmq socket option\n"
      unless ( zmq_setsockopt( $sock, ZMQ_LINGER, 0 ) == 0 );

    my $self = \$sock;

    bless $self, $class;
    return $self;
}

sub execute {
    my ( $self, $cmd ) = @_;
    my $sock = $$self;

    my $msg = zmq_msg_init_data($cmd);
    my $rv = zmq_msg_send( $msg, $sock );
    croak "zmq_msg_send failed: $!" if ( $rv == -1 );

    my ( $status, $response ) = _recv_reply($sock);

    if ( !defined($status) ) {
        die "Error: no response from dataplane\n";
    }
    elsif ( $status eq 'OK' ) {
        return $response;
    }
    else {
        die "Error: $response\n"
          if defined($response);
        return;    # undefined
    }
}

sub execute_pb {
    my ( $self, $pb ) = @_;
    my $sock = $$self;

    my $rv = zmq_msg_send( "protobuf", $sock, ZMQ_SNDMORE );
    croak "zmq_msg_send failed: $!" if ( $rv == -1 );

    my $msg = zmq_msg_init_data($pb);
    $rv = zmq_msg_send( $msg, $sock );
    croak "zmq_msg_send failed: $!" if ( $rv == -1 );

    my ($response) = _recv_reply($sock);

    if ( !defined($response) ) {
        die "Error: no response from dataplane\n";
    }
    return $response;
}

sub _address {
    my $id = shift;

    # No fabric id means local
    return $LOCAL_IPC
      if not defined($id);

    # Parse controller.conf file to get mapping from fabric ID to IP
    my $ini = Config::Tiny->read($CTRL_CFG);
    croak "Can't read $CTRL_CFG: $!\n" unless $ini;

    my $cfg = $ini->{"Dataplane.fabric$id"};
    unless ($cfg) {
        carp "Can't find $id in $CTRL_CFG\n";
        return;
    }

    my $url = $cfg->{"control"};
    unless ( defined($url) ) {
        carp "Missing control line under Dataplane.fabric$id in $CTRL_CFG\n";
        return;
    }

    return "$url";
}

# Receive multi-part message
# This handles ugly part of timeout and multipart messages
sub _recv_reply {
    my $sock = shift;
    my @msgparts;

    zmq_poll(
        [
            {
                socket   => $sock,
                events   => ZMQ_POLLIN,
                callback => sub {
                    while (1) {
                        my $msg = zmq_msg_init();
                        my $rv = zmq_msg_recv( $msg, $sock, 0 );
                        if ( $rv < 0 ) {
                            warn "Error: Failed to receive message $rv";
                            last;
                        }
                        my $str = zmq_msg_data($msg);
                        push @msgparts, $str;
                        zmq_msg_close($msg);

                        # any more ? (multipart message)
                        $rv = zmq_getsockopt( $sock, ZMQ_RCVMORE );
                        if ( $rv < 0 ) {
                            warn "Error: Receive multipart message failed $rv";
                        }
                        last if ( $rv <= 0 );
                    }
                  }
            }
        ],
        $TIMEOUT
    );

    return @msgparts;
}

sub setup_fabric_conns {
    my $fabric   = shift;
    my @dp_ids   = ();
    my @dp_conns = ();
    my @urls;
    my ( $local_controller, @dp_active ) = get_vplane_info( \@urls );

    for my $fid (@dp_active) {
        if ( !defined($fabric) || ( $fabric eq $fid ) ) {
            $dp_conns[$fid] = new Vyatta::Dataplane( $fid, $urls[$fid] );
            if ( defined $dp_conns[$fid] ) {
                push @dp_ids, $fid;
            }
            else {
                warn "Cannot connect to dataplane $fid";
            }
        }
    }

    return ( \@dp_ids, \@dp_conns, $local_controller );
}

sub close_fabric_conns {
    my ( $dp_ids, $dp_conns ) = @_;

    for my $dp_id ( sort @{$dp_ids} ) {
        my $sock = ${$dp_conns}[$dp_id];

        next unless $sock;
        zmq_close($$sock);
    }
}

sub is_local_controller {
    my $local = get_vplane_info();

    return $local;
}

sub vplane_exec_cmd {
    my ( $cmd, $dp_ids, $dp_conns, $expect_response ) = @_;
    my @resp_arr = ();

    for my $dp_id ( sort @{$dp_ids} ) {
        my $sock = ${$dp_conns}[$dp_id];

        next unless $sock;

        if ( $expect_response == 1 ) {
            $resp_arr[$dp_id] = $sock->execute($cmd);
        }
        else {
            $sock->execute($cmd);
        }
    }

    return ( \@resp_arr );
}

sub vplane_exec_pb_cmd {
    my ( $cmd, $pb, $dp_ids, $dp_conns, $expect_response ) = @_;
    my @resp_arr = ();

    my $de = 'DataplaneEnvelope'->new( { type => $cmd, msg => $pb->encode } );

    for my $dp_id ( sort @{$dp_ids} ) {
        my $sock = ${$dp_conns}[$dp_id];

        next unless $sock;

        my $result = $sock->execute_pb( $de->encode );

        my $rde = DataplaneEnvelope->decode($result);

        if ( $expect_response == 1 ) {
            $resp_arr[$dp_id] = $rde->{msg};
        }
    }

    return ( \@resp_arr );
}

sub controller_command {
    my $cmd = shift;

    my $ipc  = 'ipc:///var/run/vyatta/vplaned-config.socket';
    my $sock = new Vyatta::Dataplane( q(), $ipc );
    my $json = $sock->execute($cmd);
    zmq_close($$sock);
    return unless defined $json;
    return decode_json($json);
}

sub is_dp_local {
    my $dp = shift;

    return defined $dp->{local} && ( $dp->{local} eq JSON::true );
}

sub is_dp_connected {
    my $dp = shift;

    return defined $dp->{connected} && ( $dp->{connected} eq JSON::true );
}

sub get_vplane_info {
    my $urls    = shift;
    my $decoded = controller_command('GETVPCONFIG');
    my @ids;
    my $local = 0;

    for my $dp ( @{ $decoded->{dataplanes} } ) {
        next if ( !is_dp_connected($dp) );
        push @ids, $dp->{id};
        $local += is_dp_local($dp);
        $$urls[ $dp->{id} ] = $dp->{control} if defined $urls;
    }

    return $local, sort @ids;
}

sub format_platform_state {
    # dp not currently used, but may be used in the future if we
    # needed to support remote dataplanes of different platform type
    # to the controller
    my ( $dp, $object, $encoded_json ) = @_;
    my $platform_state_str;
    my $platform_state_err;

    run3( [ $PLATFORM_STATE_CMD, '--format-platform-state', $object ],
            \$encoded_json, \$platform_state_str,
            \$platform_state_err );
    print $platform_state_err;

    return $platform_state_str;
}

1;
