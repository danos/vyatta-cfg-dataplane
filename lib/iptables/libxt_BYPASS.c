/*
 * Copyright (c) 2015 by Brocade Communications Systems, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: LGPL-2.1-only
 *
 * "BYPASS" iptables extension.
 */
#include <sys/socket.h>
#include <getopt.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xtables.h>
#include <linux/netfilter.h>
#include <linux/netfilter/x_tables.h>
#include "xt_BYPASS.h"

#define ARRAY_SIZE(a) (sizeof (a) / sizeof ((a)[0]))

enum {
	O_IIF = 0,
	O_OIF = 1,
	O_RADDR = 2,
};

#define s struct xt_bypass_user_tginfo
static const struct xt_option_entry bypass_tg_opts[] = {
	{.name = "oif", .id = O_OIF, .type = XTTYPE_STRING,
	 .flags = XTOPT_PUT | XTOPT_MAND, XTOPT_POINTER(s, oif)},
	{.name = "iif", .id = O_IIF, .type = XTTYPE_STRING,
	 .flags = XTOPT_PUT, XTOPT_POINTER(s, iif)},
	{.name = "raddr", .id = O_RADDR, .type = XTTYPE_STRING,
	 .flags = XTOPT_PUT, XTOPT_POINTER(s, raddr)},
	XTOPT_TABLEEND,
};
#undef s

static void bypass_tg_help(void)
{
	printf("BYPASS target options:\n"
	       "  iif <iif>                   Set input interface\n"
	       "  oif <oif>                   Set output interface\n"
	       "  raddr <raddr>               Set remote address\n");
}

static void bypass_tg_save(const void *ip __attribute__ ((unused)),
			   const struct xt_entry_target *target)
{
	const struct xt_bypass_tginfo *info = (const void *)target->data;

	if (*info->tgparams.iif != '\0')
		printf(" --iif %s", info->tgparams.iif);
	if (*info->tgparams.oif != '\0')
		printf(" --oif %s", info->tgparams.oif);
	if (*info->tgparams.raddr != '\0')
		printf(" --raddr %s", info->tgparams.raddr);
}

static void bypass_tg_print(const void *unused __attribute__ ((unused)),
			    const struct xt_entry_target *target,
			    int numeric __attribute__ ((unused)))
{
	bypass_tg_save(NULL, target);
}

static struct xtables_target bypass_tg_reg[] = {
	{
		.version       = XTABLES_VERSION,
		.name          = "BYPASS",
		.revision      = 0,
		.family        = NFPROTO_UNSPEC,
		.size          = sizeof(struct xt_bypass_tginfo),
		.userspacesize = sizeof(struct xt_bypass_user_tginfo),
		.help          = bypass_tg_help,
		.print         = bypass_tg_print,
		.save          = bypass_tg_save,
		.x6_parse      = xtables_option_parse,
		.x6_options    = bypass_tg_opts,
	},
};

void _init(void)
{
	xtables_register_targets(bypass_tg_reg, ARRAY_SIZE(bypass_tg_reg));
}
