#!/usr/bin/perl -w

# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use File::Basename;
use Cwd 'abs_path';
use lib abs_path(dirname(__FILE__) . '/../lib');

use strict;
use warnings 'all';
use Test::More tests => 10;

use_ok('Vyatta::DataplanePunt', qw( discoverAndMarkPuntRules hasPuntRule
        addPuntRule deletePuntRule sweepPuntRules parseAndAddExistingRule ));

my $gencmds;

# Test 1 - add a punt rule, test the commands generated and delete the rule

$gencmds = addPuntRule(undef, "vti1", "0.0.0.0/0", "0.0.0.0/0",
                       "vti1", ".spathintf");
is($gencmds,
   "/sbin/iptables -t mangle -A OUTPUT -j BYPASS  -o vti1 -s 0.0.0.0/0 -d 0.0.0.0/0 --iif vti1 --oif .spathintf\n",
   "1: add commands");

# Test 2 - sweep with no rules

$gencmds = sweepPuntRules();
is($gencmds, "", "2: sweep commands");

# Test 3 - add an existing rule and then sweep

parseAndAddExistingRule("    0     0 BYPASS     all  --  *      *       10.0.0.0/24          20.0.0.0/24          oif=.spathintf");
$gencmds = sweepPuntRules();
is($gencmds,
      "/sbin/iptables -t mangle -D OUTPUT -j BYPASS   -s 10.0.0.0/24 -d 20.0.0.0/24  --oif .spathintf\n",
   "3: sweep commands");

# Test 4 - add existing rules, readd them and then sweep

parseAndAddExistingRule("    0     0 BYPASS     all  --  *      *       10.0.0.0/24          20.0.0.0/24          oif=.spathintf");
parseAndAddExistingRule("    0     0 BYPASS     all  --  *      vti1    0.0.0.0/0            0.0.0.0/0            iif=vti1 oif=.spathintf");
$gencmds = addPuntRule(undef, "vti1", "0.0.0.0/0", "0.0.0.0/0",
                       "vti1", ".spathintf");
is($gencmds, "", "4: readd existing commands");
$gencmds = addPuntRule(undef, undef, "10.0.0.0/24", "20.0.0.0/24",
                       undef, ".spathintf");
is($gencmds, "", "4: readd existing commands");
$gencmds = sweepPuntRules();
is($gencmds, "", "4: sweep commands");

# Test 5 - add existing rules, readd one rule and sweep the remaining rules

parseAndAddExistingRule("    5     5 BYPASS     all  --  *      *       10.0.0.0/24          20.0.0.0/24          oif=.spathintf");
parseAndAddExistingRule("   10    10 BYPASS     all  --  *      vti1    0.0.0.0/0            0.0.0.0/0            iif=vti1 oif=.spathintf");
parseAndAddExistingRule("99999 99999 BYPASS     all  --  *      vti2    0.0.0.0/0            0.0.0.0/0            iif=vti2 oif=.spathintf");
$gencmds = addPuntRule(undef, "vti1", "0.0.0.0/0", "0.0.0.0/0",
                       "vti1", ".spathintf");
is($gencmds, "", "5: readd existing commands");
$gencmds = addPuntRule(undef, undef, "10.0.0.0/24", "20.0.0.0/24",
                       undef, ".spathintf");
is($gencmds, "", "5: readd existing commands");
$gencmds = sweepPuntRules();
is($gencmds,
   "/sbin/iptables -t mangle -D OUTPUT -j BYPASS  -o vti2 -s 0.0.0.0/0 -d 0.0.0.0/0 --iif vti2 --oif .spathintf\n",
   "5: sweep commands");
