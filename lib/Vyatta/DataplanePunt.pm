#
# module to manage dataplane punt (iptables) rules
#
# Copyright (c) 2015, Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#

package Vyatta::DataplanePunt;

use strict;
use warnings;

use parent qw( Exporter );

our @EXPORT_OK = qw( discoverAndMarkPuntRules hasPuntRule addPuntRule
  deletePuntRule sweepPuntRules parseAndAddExistingRule );

# Collect set of existing punt rules.
my %existingPunt = ();

sub parseAndAddExistingRule {
    my ($rule) = @_;
    my ( $target, $in, $out, $src, $dst, $iif, $oif ) = parseRule($rule);

    # Ignore other types of rules
    return if !$target eq 'BYPASS';

    if ( !defined($oif) ) {
        print
"WARNING: No output interface specified for BYPASS rule $src, $dst, $iif, $oif\n";
        return;
    }

    my $key = generatePuntRuleKey( $in, $out, $src, $dst, $iif, $oif );

    # To avoid having to reparse the key later, cheat and also put
    # the key in the value
    my %value = (
        in  => $in,
        out => $out,
        src => $src,
        dst => $dst,
        iif => $iif,
        oif => $oif,

        # Stale until told otherwise
        mark => 1,
    );

    #    print "Discover: $key\n";
    $existingPunt{$key} = \%value;
}

# Discovers all existing punt rules and marks each of them as stale
sub discoverAndMarkPuntRules {
    my @currentRules = `/sbin/iptables -t mangle -L OUTPUT -n -v | tail -n +3`;
    foreach my $curRule (@currentRules) {
        parseAndAddExistingRule($curRule);
    }
}

sub generatePuntRuleKey {
    my ( $in, $out, $src, $dst, $iif, $oif ) = @_;
    my $key = "src=$src,dst=$dst,oif=$oif";
    if ( defined($in) ) {
        $key .= ",in=$in";
    }
    if ( defined($out) ) {
        $key .= ",out=$out";
    }
    if ( defined($iif) ) {
        $key .= ",iif=$iif";
    }
    return $key;
}

#
# Api takes as input the o/p of 'iptables -L' and
#  returns a list with {iptables-target, input i/f, output i/f, src
#  prefix, dst prefix, input i/f to set, output i/f to set}
# Example input:
#      0     0 BYPASS  all  --  *      *       20.0.0.0/24          10.0.0.0/24          oif=.spathintf
sub parseRule {
    my ($rule) = @_;
    my ( $cnt_in, $cnt_out, $tgt, $prot, $opt, $in, $out, $src, $dst, $args );
    ( $cnt_in, $cnt_out, $tgt, $prot, $opt, $in, $out, $src, $dst, $args ) =
      unpack( "A6 A6 A11 A5 A4 A7 A8 A21 A21 A*", $rule );

    undef $in  if $in eq '*';
    undef $out if $out eq '*';

    my ( $iif, $oif );

    if ( $tgt eq 'BYPASS' ) {
        if ( $args =~ m/iif=([^ ]+)/ ) {
            $iif = $1;
        }
        if ( $args =~ m/oif=([^ ]+)/ ) {
            $oif = $1;
        }
    }
    return ( $tgt, $in, $out, $src, $dst, $iif, $oif );
}

sub hasPuntRule {
    my ( $in, $out, $src, $dst, $iif, $oif ) = @_;
    my $key = generatePuntRuleKey( $in, $out, $src, $dst, $iif, $oif );
    if ( exists $existingPunt{$key} ) {
        return 1;
    } else {
        return 0;
    }
}

# Adds a rule, unmarking it if already present. Returns command to run
# using the shell to actually create the rule.
sub addPuntRule {
    my ( $in, $out, $src, $dst, $iif, $oif ) = @_;
    my $key = generatePuntRuleKey( $in, $out, $src, $dst, $iif, $oif );

    #    print "Add: $key\n";
    if ( hasPuntRule( $in, $out, $src, $dst, $iif, $oif ) ) {

        # No longer stale
        $existingPunt{$key}->{mark} = 0;
        return "";
    }
    my %value = (
        in  => $in,
        out => $out,
        src => $src,
        dst => $dst,
        iif => $iif,
        oif => $oif,

        # Not stale
        mark => 0,
    );
    $existingPunt{$key} = \%value;

    my $i_opt   = "";
    my $o_opt   = "";
    my $iif_opt = "";
    if ( defined($in) ) {
        $i_opt = "-i $in";
    }
    if ( defined($out) ) {
        $o_opt = "-o $out";
    }
    if ( defined($iif) ) {
        $iif_opt = "--iif $iif";
    }
    return
"/sbin/iptables -t mangle -A OUTPUT -j BYPASS $i_opt $o_opt -s $src -d $dst $iif_opt --oif $oif\n";
}

# Deletes a rule. Returns command to run using the shell to actually
# delete the rule.
sub deletePuntRule {
    my ( $in, $out, $src, $dst, $iif, $oif ) = @_;
    if ( !hasPuntRule( $in, $out, $src, $dst, $iif, $oif ) ) {
        return "";
    }
    my $key = generatePuntRuleKey( $in, $out, $src, $dst, $iif, $oif );

    #    print "Delete: $key\n";
    delete $existingPunt{$key};

    my $i_opt   = "";
    my $o_opt   = "";
    my $iif_opt = "";
    if ( defined($in) ) {
        $i_opt = "-i $in";
    }
    if ( defined($out) ) {
        $o_opt = "-o $out";
    }
    if ( defined($iif) ) {
        $iif_opt = "--iif $iif";
    }
    return
"/sbin/iptables -t mangle -D OUTPUT -j BYPASS $i_opt $o_opt -s $src -d $dst $iif_opt --oif $oif\n";
}

# Sweeps all marked (stale) rules
sub sweepPuntRules {
    my $cmds = "";
    while ( my ( $key, $value ) = each(%existingPunt) ) {

        #        print "Sweep: $key mark: $value->{mark}\n";
        # Only consider marked (stale) rules
        next if $value->{mark} == 0;
        $cmds .= deletePuntRule(
            $value->{in},  $value->{out}, $value->{src},
            $value->{dst}, $value->{iif}, $value->{oif}
        );
    }
    return $cmds;
}

1;
