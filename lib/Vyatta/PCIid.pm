# Access to PCI id database

# Copyright (c) 2013-2015, Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::PCIid;
use strict;
use warnings;

our @EXPORT = qw(pci_vendor pci_device);
use base qw(Exporter);

# Read PCI id's file into a hash
my $PCI_IDS = '/usr/share/misc/pci.ids';
my %pci_id;

if ( open( my $pcif, '<', $PCI_IDS ) ) {
    my ( $vendor, $device ) = ( '', '', '' );

    while (<$pcif>) {
        next if ( /^#/ or /^\s*$/ );
        chomp;

        # Stop when get to list of classes
        last if (/^C/);

        if (/^([0-9a-f]+)\s+(.*)/i) {
            $vendor = $1;
            $pci_id{$vendor}{vendor_name} = $2;
        } elsif (/^\t([0-9a-f]+)\s+(.*)/i) {
            $device = $1;
            $pci_id{$vendor}{$device}{device_name} = $2;
        } elsif (/^\t\t([0-9a-f]+)\s+([0-9a-f]+)\s+(.*)/i) {
            $pci_id{$vendor}{$device}{$1}{$2} = $3;
        }
    }
    close $pcif;
}

sub pci_vendor {
    my $vendor = shift;

    return $pci_id{$vendor}{vendor_name};
}

sub pci_device {
    my ( $vendor, $device ) = @_;

    return $pci_id{$vendor}{$device}{device_name};
}

1;
