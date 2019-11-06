# Module: VPlaned.pm

# Copyright (c) 2017-2019, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2013-2015 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::VPlaned;
use strict;
use warnings;

use Carp;
use JSON;
use ZMQ::Constants qw(ZMQ_REQ ZMQ_RCVMORE ZMQ_POLLIN);
use ZMQ::LibZMQ3;

use MIME::Base64;
use Google::ProtocolBuffers;

use lib"/usr/share/perl5/vyatta/proto";
use DataplaneEnvelope;
use VPlanedEnvelope;

# IPC socket to talk to controller
my $controller_ipc = "ipc:///var/run/vyatta/vplaned.socket";

# timeout in milliseconds, so this is 10 sec
my $TIMEOUT = 10000;

# special hook for debugging
my $debug = $ENV{'VPLANED_DEBUG'};

# Create one ZMQ context when object is loaded
# -- ok to create multiple instances each with own socketa
my $zctx = zmq_ctx_new();

# Create new object
# opens connection to controller
#
# Usage:
#  my $ctrl = new Vyatta::VPlaned;
# or
#  my $ctrl = new Vyatta::VPlaned("tcp://controllerIP:999");
#
# returns undefined if communication not possible
sub new {
    my $class = shift;
    my $self  = {};
    bless $self, $class;

    $self->_initialize(@_);

    return $self;
}

sub DESTROY {
    my $self = shift;

    if (defined($self->{socket})) {
        my $sock = $self->{socket};
        zmq_close($sock);
    }
}

# Setup connection with controller
sub _initialize {
    my ( $self, $endpoint ) = @_;
    $endpoint = $controller_ipc unless defined($endpoint);

    # Open socket
    my $sock = zmq_socket( $zctx, ZMQ_REQ );
    croak "ZMQ socket failed"
      unless defined($sock);

    croak "Can not connect to $endpoint"
      unless zmq_connect( $sock, $endpoint ) == 0;

    $self->{socket} = $sock;

    # Hold a reference to zctx so we can clean up the socket
    # before zctx is automatically garbage collected.
    $self->{zctx} = $zctx;
}

# Install a debugging hook
sub _hook {
    my ( $self, $callback ) = @_;

    if ( defined $callback ) {
        $self->{callback} = $callback;
    } else {
        delete $self->{callback};
    }
}

# Utility hook to allow access to underlying socket
sub socket {
    my $self = shift;

    return $self->{socket};
}

# Take config path and new command
# and convert into hash for to_json
sub _to_tree {
    my ( $path, $cmd, $commit_action, $interface, $protobuf ) = @_;
    my %hash = ();

    my $h = \%hash;
    for my $k ( split( ' ', $path ) ) {
        $h->{$k} = {} unless exists $h->{$k};
        $h = $h->{$k};
    }

    my $action = "__" . $commit_action . "__";
    $h->{$action} = $cmd;
    if (defined($interface)) {
	$h->{'__INTERFACE__'} = $interface;
    }
    $h->{'__PROTOBUF__'} = $protobuf;
    
    return \%hash;
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

# Store send command to dataplane controller
# fatal in case of errors
#
# This variant builds up the protobuf message
sub store_pb {
    my ( $self, $path, $msg, $msg_type, $interface, $action ) = @_;
    my $sock = $self->{socket};

    #allow the callee to override the action applied to this
    #node, if the callee is located in a different node path
    #than the action that is to be applied.
    $action = $ENV{COMMIT_ACTION} unless defined($action);

    # can happen if erronously run outside of commit
    croak "commit action not set\n" unless defined($action);

    #build the protocol buffers wrappers
    #first the dataplane envelope
    my $de = 'DataplaneEnvelope'->new();
    $de->{type} = $msg_type;
    $de->{msg} = $msg->encode;

    #now wrap with the vplaned wrapper
    my $vpe = 'VPlanedEnvelope'->new();
    $vpe->{key} = $path;
    if (defined($interface)) {
	$vpe->{interface} = $interface;
    }
    $vpe->{action} = $action;
    $vpe->{msg} = $de->encode;
    
    #convert message to base64
    my $out = encode_base64($vpe->encode, '');
    $out = "protobuf " . $out;
    
    my $json_msg = to_json( _to_tree( $path, $out, $action, $interface, JSON::true ) );

    &{ $self->{callback} }( $path, $out, $action, $interface )
      if ( defined $self->{callback} );

    if ($debug) {
        my $s_json_msg = $json_msg;
        $s_json_msg =~ s/\$/\\\$g/;
        $s_json_msg =~ s/</\\\</g;
        $s_json_msg =~ s/>/\\\>/g;
        $s_json_msg =~ s/\)/\\\)/g;
        $s_json_msg =~ s/\(/\\\(/g;
        $s_json_msg =~ s/;/\\\;/g;
        print "send $s_json_msg \n";
    }

    my $zmsg = zmq_msg_init_data($json_msg);
    my $rv = zmq_msg_send( $zmsg, $sock );
    die "zmq_msg_send failed: $!"
      if ( $rv == -1 );

    my ($status) = _recv_reply($sock);
    die "No response from controller\n"
      unless defined($status);

    printf "recv $status " if $debug;

    return if ( $status eq 'OK' );

    carp "Config store failed\n";
    return 1;
}

# Store send command to dataplane controller
# fatal in case of errors
sub store {
    my ( $self, $path, $cmd, $interface, $action ) = @_;
    my $sock = $self->{socket};

    #allow the callee to override the action applied to this
    #node, if the callee is located in a different node path
    #than the action that is to be applied.
    $action = $ENV{COMMIT_ACTION} unless defined($action);

    # can happen if erronously run outside of commit
    croak "commit action not set\n" unless defined($action);

    my $json_msg = to_json( _to_tree( $path, $cmd, $action, $interface, JSON::false ) );

    &{ $self->{callback} }( $path, $cmd, $action, $interface )
      if ( defined $self->{callback} );

    if ($debug) {
        my $s_json_msg = $json_msg;
        $s_json_msg =~ s/\$/\\\$g/;
        $s_json_msg =~ s/</\\\</g;
        $s_json_msg =~ s/>/\\\>/g;
        $s_json_msg =~ s/\)/\\\)/g;
        $s_json_msg =~ s/\(/\\\(/g;
        $s_json_msg =~ s/;/\\\;/g;
        print "send $s_json_msg \n";
    }

    my $msg = zmq_msg_init_data($json_msg);
    my $rv = zmq_msg_send( $msg, $sock );
    die "zmq_msg_send failed: $!"
      if ( $rv == -1 );

    my ($status) = _recv_reply($sock);
    die "No response from controller\n"
      unless defined($status);

    printf "recv $status " if $debug;

    return if ( $status eq 'OK' );

    carp "Config store failed\n";
    return 1;
}

1;
