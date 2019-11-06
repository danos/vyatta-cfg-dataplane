# Implement variable length bit vector for CPU's

# Copyright (c) 2017, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2013-2015, Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::CPUset;

use strict;
use warnings;
use Carp;

# constructor
# internally cpuset is stored as sparse array because dataplane
# needs to store up to 128 CPU's

# Note: none of this code has limit on # of CPU's it is up to
# application to check that

sub new {
    my $class  = shift;
    my $cpuvec = _str2vector(shift);
    my $self   = \$cpuvec;

    bless $self, $class;

    return $self;
}

# string to perl bit vector
# case 0: no argument == empty set
#      1: hex string "0x10af" is interpreted as mask
#      2: list of ranges separated by comma
#	  ie. 1-11,33
#
sub _str2vector {
    my $range = shift;

    # simple hex string
    if ( $range =~ /^ 0x([[:xdigit:]]+) $/x ) {
        return pack( 'h*', scalar( reverse($1) ) );
    }

    # list of cpu-ranges: 0-3,7
    my $vec = '';
    foreach my $str ( split /,/, $range ) {
        if ( $str =~ /^ (\d+)-(\d+) $/x ) {
            vec( $vec, $_, 1 ) = 1 for ( $1 .. $2 );
        } elsif ( $str =~ /^ (\d+) $/x ) {
            vec( $vec, $1, 1 ) = 1;
        } else {
            carp "invalid input range $str\n";
            return;    # bad input return undefined
        }
    }

    return $vec;
}

# Add one cpu to bit mask
sub add_cpu {
    my ( $self, $cpu ) = @_;

    vec( $$self, $cpu, 1 ) = 1;
}

# Delete one cpu from bit mask
sub del_cpu {
    my ( $self, $cpu ) = @_;

    vec( $$self, $cpu, 1 ) = 0;
}

# Is CPU present in mask
sub is_set {
    my ( $self, $cpu ) = @_;

    return vec( $$self, $cpu, 1 );
}

# find first CPU in the vector
# return -1 if no bits set
sub first {
    my $self = shift;
    return index( unpack( 'b*', $$self ), '1' );
}

# find largest CPU in vector
# return -1 if no bits set
sub last {
    my $self = shift;

    return rindex( unpack( 'b*', $$self ), '0' );
}

# convert to list with elements for each set bit
sub list {
    my $self = shift;
    my @bits = split( //, ( unpack( 'b*', $$self ) ) );
    my @cpus;

    for ( my $i = 0 ; $i <= $#bits ; $i++ ) {
        push @cpus, $i
          if ( $bits[$i] eq '1' );
    }

    return @cpus;
}

# format as string (ie "4000000001ffffe" )
sub hex {
    my $self = shift;
    return scalar reverse( unpack( 'h*', $$self ) );
}

# format a user range (ie "1-20,90" )
sub range {
    my $self = shift;
    my $bits = unpack( 'b*', $$self );
    my $n    = length($bits);
    my ( $start, $result );

    for ( my $i = 0 ; $i < $n ; $i++ ) {
        my $bit = substr( $bits, $i, 1 ) eq '1';

        if ( defined($start) ) {
            next if $bit;    # continuation of range

            my $end = $i - 1;
            $result .= '-' . $end
              unless ( $end == $start );
            $start = undef;
        } elsif ($bit) {     # start of new range
            $result .= ','
              if defined($result);
            $result .= $i;
            $start = $i;
        }
    }

    # Handle of last part of range if not terminated
    my $last = $n - 1;
    $result .= '-' . $last
      if ( defined($start) && $start != $last );

    return $result;
}

# Return a vector as required by the dom->pin_vcpu() subroutine.
sub vec {
    my $self = shift;
    return $$self;
}

1;
