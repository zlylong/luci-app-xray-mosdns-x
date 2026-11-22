#!/bin/sh
# luci-app-xray-mosdns-x - put a checked set of generated files in place
#
#   switch.sh <new dir> <dir in use>
#
# Every file of <new dir> replaces the file of the same name in <dir in
# use>; files only the old set has (the firewall state, say) stay. Both
# directories are on the same filesystem, so each step is a rename. The
# files being replaced are kept as hard links until all have moved: if any
# step fails, the new files go back to <new dir>, the old ones back in
# place, and it exits 1 with the reason on stderr. The daemons never see a
# mix of the two sets.
#
# Exit status: 0 the new set is in place; 1 it is not, the old set is (the
# caller can go on with it); 3 neither is whole, because putting the old
# set back failed too: what is left of it stays in <dir in use>/.prev, and
# nothing may be started on <dir in use>.
NEW=$1
OUT=$2
[ -d "$NEW" ] && [ -d "$OUT" ] || { echo "usage: switch.sh <new dir> <dir in use>" >&2; exit 2; }
P="$OUT/.prev"

names() {
	for f in "$NEW"/* "$NEW"/.[!.]*; do
		[ -e "$f" ] && echo "${f##*/}"
	done
}

# $1 = what failed. The moved files go back, the old ones back in place;
# the links are only dropped once every old file is back.
undo() {
	back=1
	for n in $moved; do
		if [ -e "$P/$n" ]; then
			# the new file back to look at, the old one in its place (over
			# the new one, if that could not be moved back)
			mv -f "$OUT/$n" "$NEW/" 2>/dev/null
			mv -f "$P/$n" "$OUT/" 2>/dev/null || back=0
		else
			# a file the old set did not have must not stay
			mv -f "$OUT/$n" "$NEW/" 2>/dev/null || rm -f "$OUT/$n" 2>/dev/null || back=0
		fi
	done
	echo "$1" >&2
	if [ "$back" = 1 ]; then
		rm -rf "$P"
		exit 1
	fi
	echo "the old set could not be put back whole either: what is left of it is in $P" >&2
	exit 3
}

rm -rf "$P"
mkdir "$P" || { echo "cannot create $P" >&2; exit 1; }
moved=""
list=$(names)
for n in $list; do
	if [ -e "$OUT/$n" ]; then
		err=$(ln -f "$OUT/$n" "$P/$n" 2>&1) || undo "cannot keep $OUT/$n: $err"
	fi
done
for n in $list; do
	# into the directory, not onto the name: a directory there is an error,
	# not a place to move the file into
	err=$(mv -f "$NEW/$n" "$OUT/" 2>&1) || undo "cannot move $n into $OUT: $err"
	moved="$moved $n"
done
rm -rf "$P"
exit 0
