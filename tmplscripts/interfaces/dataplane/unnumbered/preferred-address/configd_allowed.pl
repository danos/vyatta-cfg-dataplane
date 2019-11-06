#! /usr/bin/perl
#
# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;
use Getopt::Long;
use Vyatta::Interface;
use Vyatta::Misc;

my $dev;
my $atype;
my $iftype;

sub usage {
    print "Usage: $0 --donor-dev=<interface> --ipv4|--ipv6\n";
    exit 1;
}

GetOptions(
    "donor-dev=s" => \$dev,
    "ipv6"        => sub { $atype = "ipv6" },
    "ipv4"        => sub { $atype = "ipv4" },
) or usage();

usage() unless defined($dev);
usage() unless defined($atype);

my @match;
my $quiet = 1;

my $intf = new Vyatta::Interface($dev);
exit 0 unless defined($intf);
exit 0
  unless ( ( "loopback" eq $intf->type() )
    || ( "dataplane" eq $intf->type() ) );
my $config = new Vyatta::Config( $intf->path() );
my @addrs  = $config->returnValues("address");

foreach my $addr (@addrs) {
    my ( $ipaddr, $prefixlen ) = split( /\//, $addr );
    next unless defined($ipaddr);
    my $is_valid = ( $atype eq "ipv4" ) ? valid_ip_addr ( $ipaddr ) :
	valid_ipv6_addr ( $ipaddr );
    if ( $is_valid ) {
        push @match, $ipaddr;
    }
}

print join( ' ', @match ), "\n";

exit 0
