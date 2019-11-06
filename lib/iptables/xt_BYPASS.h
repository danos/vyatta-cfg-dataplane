/*
 * Copyright (c) 2015 by Brocade Communications Systems, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: LGPL-2.1-only
 *
 * "BYPASS" target extension for Xtables
 */
#ifndef _XT_BYPASS_TARGET_H
#define _XT_BYPASS_TARGET_H

struct xt_bypass_user_tginfo {
	char iif[IFNAMSIZ];
	char oif[IFNAMSIZ];
	char raddr[INET6_ADDRSTRLEN];
};

struct xt_bypass_tginfo {
	struct xt_bypass_user_tginfo tgparams;
	struct xt_bypass_priv *priv __attribute__((aligned(8)));
};

#endif /* _XT_BYPASS_TARGET_H */
