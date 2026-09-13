# SPDX-License-Identifier: MIT
#
# os-agnic: OPNsense plugin that pulls in the agnic-kmod port and loads if_agnic
# at boot. Mirrors net/realtek-re in opnsense/plugins. Drop into that tree as
# net/agnic and `make package`.

PLUGIN_NAME=		agnic
PLUGIN_VERSION=		0.1
PLUGIN_COMMENT=		Sophos XGS front-panel ports via the Marvell NPU (if_agnic)
PLUGIN_MAINTAINER=	piorkowski.michael@gmail.com
PLUGIN_WWW=		https://github.com/piorkowskim79/xgs-npu-freebsd
PLUGIN_DEPENDS=		agnic-kmod

.include "../../Mk/plugins.mk"
