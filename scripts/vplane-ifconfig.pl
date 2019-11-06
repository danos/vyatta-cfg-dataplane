#! /usr/bin/perl

# Copyright (c) 2014-2016, Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

use Getopt::Long;
use File::Slurp;
use JSON qw( decode_json );

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Misc;
use Vyatta::DataplaneStats;
use Vyatta::Interface;

my %action_hash = (
    'show'          => \&show_dataplane_interfaces,
    'show-slowpath' => \&show_dataplane_interfaces_slowpath,
    'show-detail'   => \&show_dataplane_interfaces_per_vplane,
    'clear'         => \&clear_dataplane_interfaces,
);

sub usage {
    print "Usage: $0 <interface> action=ACTION\n";
    print "  ACTION = ", join( ' | ', keys %action_hash ), "\n";
    exit 1;
}

my $action = 'show';
my $vif_only;
my $vrrp_only;
my @intf_list;

GetOptions(
    "action=s" => \$action,
    "vif"      => \$vif_only,
    "vrrp"     => \$vrrp_only
) or usage();

if (@ARGV) {
    @intf_list = @ARGV;
} elsif ($vif_only) {
    @intf_list = sort grep { /^dp\d+\w+\.\d+?$/ } getInterfaces();
} elsif ($vrrp_only) {
    @intf_list = sort grep { /^dp\d+\w+v\d+$/ } getInterfaces();
} else {
    @intf_list = sort grep { /^dp\d/ } getInterfaces();
}

my $func;
if ( defined $action_hash{$action} ) {
    $func = $action_hash{$action};
}
else {
    print "Invalid action [$action]\n";
    usage();
}

&$func(\@intf_list);
