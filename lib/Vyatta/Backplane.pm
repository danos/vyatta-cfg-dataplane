# Module: Backplane.pm
#
# Utility functions for backplane info

# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::Backplane;
use strict;
use warnings;
require Exporter;

our @ISA = qw(Exporter);

our @EXPORT = qw(get_backplane_intfs is_backplane_intf);

sub get_backplane_intfs {
    opendir( my $fh, "/sys/class/net" );
    my @result = sort grep { /^bp/ } readdir($fh);
    return \@result;
}

sub is_backplane_intf {
    my ($intf) = @_;
    my $bp_intfs = get_backplane_intfs();
    my $match = grep { $_ eq $intf } @{$bp_intfs};
    if ($match) {
        return 1;
    }
    return 0;
}

1;
