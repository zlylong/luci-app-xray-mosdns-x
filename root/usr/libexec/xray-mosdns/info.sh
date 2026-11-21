#!/bin/sh
# luci-app-xray-mosdns-x - the read-only views of the helpers
#
#   info.sh groups | adlist-status | adlist-catalog | versions | check | cron-status
#
# groups.uc, adlist.uc and update.sh also change things (pin a group,
# download lists, install binaries), so they are in the ACL's write group,
# and rpcd grants exec by path, not by argument. This script runs only their
# read-only commands, so it can be in the read group: a read-only login sees
# the node groups, the blocklists and the versions too.
L=/usr/libexec/xray-mosdns
case "$1" in
	groups) exec "$L/groups.uc" list ;;
	adlist-status) exec "$L/adlist.uc" status ;;
	adlist-catalog) exec "$L/adlist.uc" catalog ;;
	versions) exec "$L/update.sh" versions ;;
	check) exec "$L/update.sh" check ;;
	cron-status) exec "$L/update.sh" cron-status ;;
	*) printf '{"ok":false,"error":"unknown view"}\n'; exit 1 ;;
esac
