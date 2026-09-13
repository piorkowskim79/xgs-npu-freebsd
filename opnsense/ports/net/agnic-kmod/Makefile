# SPDX-License-Identifier: MIT
#
# FreeBSD/OPNsense port for the if_agnic kernel module. Mirrors net/realtek-re-kmod
# in opnsense/ports. Drop this directory into that tree as net/agnic-kmod, then
# `make makesum && make package` on a FreeBSD 15.1 host with SRC_BASE pointing at the
# OPNsense kernel source (opnsense-code src). Not yet built: no tagged release exists.

PORTNAME=	agnic
DISTVERSIONPREFIX=	v
DISTVERSION=	0.1.0
CATEGORIES=	net
PKGNAMESUFFIX=	-kmod

MAINTAINER=	piorkowski.michael@gmail.com
COMMENT=	Kernel driver for the Marvell AGNIC NPU endpoint of Sophos XGS appliances
WWW=		https://github.com/piorkowskim79/xgs-npu-freebsd

LICENSE=	BSD2CLAUSE
LICENSE_FILE=	${WRKSRC}/../LICENSES/BSD-2-Clause.txt

USES=		kmod uidfix

USE_GITHUB=	yes
GH_ACCOUNT=	piorkowskim79
GH_PROJECT=	xgs-npu-freebsd

WRKSRC_SUBDIR=	driver

PLIST_FILES=	${KMODDIR}/if_agnic.ko

.include <bsd.port.mk>
