# Process this file with autoconf to produce a configure script.
AC_PREREQ(2.59)

m4_define([VERSION_ID], [m4_esyscmd([
    echo -n `dpkg-parsechangelog | sed -n 's/^Version: //p'`
    ])])
AC_INIT([vyatta-cfg-dataplane], VERSION_ID, [vyatta-support@vyatta.com])

test -n "$VYATTA_VERSION" || VYATTA_VERSION=$PACKAGE_VERSION

AC_CONFIG_AUX_DIR([config])
AM_INIT_AUTOMAKE([foreign no-dist-gzip dist-bzip2 subdir-objects])
AC_PREFIX_DEFAULT([/opt/vyatta])

AC_CONFIG_FILES(
	[Makefile]
	[tests/Makefile])

AC_PROG_LIBTOOL
AC_PATH_PROG(PERL, perl)
AC_OUTPUT
