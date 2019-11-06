#!/usr/bin/env python3
#

from argparse import ArgumentParser
from vplaned import Controller
from collections import Counter, defaultdict
try:
    from vrfmanager import VrfManager
except ImportError:
    pass

def print_summary_header():
    print("{:>23} {:>9} {:>9} {:>9} {:>9} {:>9}".format("full",
                                                        "partial",
                                                        "no-res",
                                                        "no-sup",
                                                        "no-need",
                                                        "error"))

def find_dps(objects):
    '''Find all the dataplanes that are in this json.
    The json is an array of top level feature objects, with each entry
    in this array being an object that contains the dataplane name
    and feature details for that dataplane.
    '''

    dps = []
    for feat in objects:
        for data in feat:
            vals = feat[data]
            for k in vals:
                if not k['dp'] in dps:
                    dps.append(k['dp'])
    return dps

def find_feats(objects):
    feats = []

    for feat in objects:
        for f in feat:
            if not f in feats:
                feats.append(f)
    return sorted(feats)

def print_feat_summary_for_dp(obj, dp, in_feat):
    for feat in obj:
        for key in feat:
            vals = feat[key]
            for k in vals:
                if (k['dp'] == dp) and key == in_feat:
                    print("  {:11} {:>9} {:>9} {:>9} {:>9} {:>9} {:>9}".format(in_feat,
                                                                               k['full'],
                                                                               k['partial'],
                                                                               k['no_resource'],
                                                                               k['no_support'],
                                                                               k['not_needed'],
                                                                               k['error']))
def print_summary_data(data):
    obj = data['objects']
    dps = find_dps(obj)
    feats = find_feats(obj)

    print_summary_header()
    for dp in dps:
        print("{}:".format(dp))
        for feat in feats:
            print_feat_summary_for_dp(obj, dp, feat)

def show_route_nexthops(nh):
    if len(nh) > 1:
        indent = "            nexthop"
        print()
    else:
        indent = ""

    for hop in nh:
        if hop['state'] == 'gateway':
            state = 'via'
            gw = hop['via']
            ifname = hop['ifname']
            sep = ','
        else:
            state = hop['state']
            gw = ''
            ifname = ''
            sep = ''
        print("{} {} {}{} {}".format(indent, state, gw, sep, ifname))

def show_route_prefix(prefix):
    print ("    {}".format(prefix), end='')

def print_route_subset_data(subset, data):
    try:
        vrf_manager = VrfManager()
    except:
        pass
    header_needed = True;

    for val in data:
        for field in data[val]:
            if 'vrf_id' in field:
                if field['table'] >= 254:
                    table = 'MAIN'
                else:
                    table = field['table']
                # If we have a vrf manager then show routing instance name.
                # Otherwise ignore it, as everthng is in the default vrf.
                try:
                    vrf_name = vrf_manager.get_vrf_name(field['vrf_id'])
                    vrf_header = "  routing-instance: {}, table: {}".format(vrf_name, table)
                except:
                    vrf_header = "  table: {}".format(table)

                header_needed = True
            else:
                if header_needed:
                    print(vrf_header)
                    header_needed = False

                show_route_prefix(field['prefix'])
                show_route_nexthops(field['next_hop'])

def show_mroute_field(field):
    print ("  {}".format(field), end='')

def show_last_mroute_field(field):
    print ("  {}".format(field))

def print_mroute_subset_data(subset, data):
    try:
        vrf_manager = VrfManager()
    except:
        pass
    header_needed = True;

    for val in data:
        for field in data[val]:
            if 'vrf_id' in field:
                # If we have a vrf manager then show routing instance name.
                # Otherwise ignore it, as everthng is in the default vrf.
                try:
                    vrf_name = vrf_manager.get_vrf_name(field['vrf_id'])
                    vrf_header = "  routing-instance: {}".format(vrf_name)
                except:
                    vrf_header = "  "

                header_needed = True
            else:
                if header_needed:
                    print(vrf_header)
                    header_needed = False

                show_route_prefix(field['source'])
                show_mroute_field(field['group'])
                show_mroute_field(field['ifindex'])
                show_last_mroute_field(field['ifname'])

def print_subset_data(feat, subset, data):
    if feat == 'route':
        print_route_subset_data(subset, data)
    elif feat == 'route6':
        print_route_subset_data(subset, data)
    elif feat == 'mroute':
        print_mroute_subset_data(subset, data)
    elif feat == 'mroute6':
        print_mroute_subset_data(subset, data)


def main():
    parser = ArgumentParser()
    parser.add_argument("--obj", choices=['route', 'route6', 'mroute', 'mroute6'])
    parser.add_argument("--subset", choices=['no_resource', 'no_support', 'not_needed', 'partial', 'error'])

    args = parser.parse_args()

    if args.obj:
        obj=args.obj
    else:
        obj=""

    if args.subset:
        subset=args.subset
    else:
        subset=""

    with Controller() as controller:
        for dp in controller.get_dataplanes():
            with dp:
                data = dp.json_command("pd show dataplane {} {}".format(obj, subset))

                if (subset):
                    print_subset_data(obj, subset, data)
                else:
                    print_summary_data(data)

if __name__ == '__main__':
    main()
