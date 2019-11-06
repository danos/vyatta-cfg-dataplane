#! /usr/bin/perl
#
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#
# Script to manage neighbor resolution configuration parameters

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";
use Getopt::Long;
use Vyatta::VPlaned;

sub usage {
    print "Usage: $0 --action={SET|DELETE} --param=<param-name> ",
      "[--value=<value>] [--dev=<interface>] [--ipv6]\n";
    exit 1;
}

my ( $prot, $action, $param, $value, $dev, $ipv6 );
my $cstore = new Vyatta::VPlaned;

GetOptions(
    "action=s" => \$action,
    "param=s"  => \$param,
    "value=s"  => \$value,
    "dev=s"    => \$dev,
    "ipv6"     => \$ipv6,
) or usage();

$action = $ENV{COMMIT_ACTION} unless $action;

usage() unless $action && $param;

$prot = $ipv6 ? "nd6" : "arp";

$dev   = "all" unless $dev;
$value = ""    unless defined($value);

$cstore->store(
    "$prot $dev $param",
    "$prot " . lc($action) . " $dev $param $value",
    $dev, $action
);
