SUBDIRS = .

libxtables_LTLIBRARIES = lib/libxt_BYPASS.la
libxtablesdir = /lib/xtables/
lib_libxt_BYPASS_la_LDFLAGS = -avoid-version -shared $(AM_LDFLAGS)
lib_libxt_BYPASS_la_SOURCES = lib/iptables/libxt_BYPASS.c
lib_libxt_BYPASS_la_CFLAGS = -Wall -Werror $(AM_CFLAGS)
