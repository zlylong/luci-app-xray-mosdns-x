#!/bin/sh
# luci-app-xray-mosdns-x - the rules' domain files to where mosdns-x reads them
#
#   rule-files.sh sync <dir in use> <live dir>
#
# The names written out in a routing rule are not in mosdns.yaml but in a
# file per rule (rule_<n>.domains, listed in rule-files.list): mosdns-x
# reloads such a file when it changes, so editing a rule's names does not
# restart it and its cache stays. mosdns-x watches the file it opened, not
# the name: a file put in place by rename is reloaded once and never again.
# So the generated files stay with their set, and this copies each one that
# differs over its counterpart in the live directory, in place. Files of
# rules that are gone are removed, here and from the set's directory (the
# switch leaves files only the old set had).
#
# A set from before the list existed has nothing to copy. Exit status: 0,
# or 1 when a file could not be written (mosdns-x does not start without
# one it is told to read): which, on stderr.
[ "$1" = sync ] && [ -d "$2" ] && [ -n "$3" ] || { echo "usage: rule-files.sh sync <dir in use> <live dir>" >&2; exit 2; }
S=$2
L=$3
[ -f "$S/rule-files.list" ] || exit 0
mkdir -p "$L" 2>/dev/null && chmod 700 "$L" || { echo "cannot create $L" >&2; exit 1; }
rc=0
while read -r n; do
	case $n in rule_*.domains) ;; *) continue ;; esac
	[ -f "$S/$n" ] || { echo "$S/$n is missing" >&2; rc=1; continue; }
	[ -f "$L/$n" ] && cmp -s "$S/$n" "$L/$n" && continue
	cat "$S/$n" > "$L/$n" 2>/dev/null && cmp -s "$S/$n" "$L/$n" || { echo "cannot write $L/$n" >&2; rc=1; }
done < "$S/rule-files.list"
for d in "$S" "$L"; do
	for f in "$d"/rule_*.domains; do
		[ -f "$f" ] || continue
		grep -qxF "${f##*/}" "$S/rule-files.list" || rm -f "$f"
	done
done
exit $rc
