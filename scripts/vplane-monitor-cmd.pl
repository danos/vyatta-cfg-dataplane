#! /usr/bin/perl
#
# Wrapper script to issue cmds to one or more vplane instances
#
# Copyright (c) 2013-2016 Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

use Getopt::Long;
use Vyatta::Dataplane;

sub usage {
    print "Usage: $0 --cmd=\"<cmd_arg>\"\n";
    exit 1;
}

my ($cmd_arg) = "";

if ( @ARGV == 0 ) {
    usage();
}

GetOptions( 'cmd=s' => \$cmd_arg, )
  or usage();

my ( $dpids, $dpconns ) = Vyatta::Dataplane::setup_fabric_conns();
vplane_exec_cmd( $cmd_arg, $dpids, $dpconns, 0 );
Vyatta::Dataplane::close_fabric_conns( $dpids, $dpconns );
