# Every operation against every spelling of a path, on both filesystems.
#
# The trailing-slash class took four review rounds to work through — `/`, then
# `/.`, then removal, then `mkdir -p` — because each round checked the cases
# someone thought to write down. This generates the matrix instead: 6 names x
# 6 spellings x 26 operations, run on the default and the confined world, and
# the two outputs must match line for line.
#
# One fresh tree per name-and-spelling pair. These operations change what they
# name, so a single tree for all of them meant `rm-r` and `open-create` had
# turned every entry into a plain 2-byte file by the second spelling, and 84%
# of the rows were the same `NotADirectory`.
#
# It says nothing about which answer is right; tests/backends-agree pins the
# answers that matter. This says the two backends cannot drift apart.
source ../lib.sh
new_project
build_app app.roc plain
printf '\n[wiring]\nfs = "fs-confined"\n' >> "$TMP/myapp/world.toml"
build_app app.roc confined
# The entries live one level down, so a `/..` spelling names a directory inside
# the confined root (which is the process cwd) rather than its parent.
fixture() {
	rm -rf "$1"; mkdir -p "$1/work/adir/inner"
	echo a > "$1/work/afile"; echo i > "$1/work/adir/inner/deep"
	ln -s adir "$1/work/dirlink"
	ln -s afile "$1/work/filelink"
	ln -s nowhere "$1/work/dangling"
	# One movable file per operation number, so `rename-to` always has a source.
	for n in $(seq 0 25); do echo m > "$1/work/movable-$n"; done
}
# `find` with the type, so a run that leaves a file where the other leaves a
# directory shows up, and without the movables, which every run consumes.
snapshot() { ( cd "$1" && find . -name 'movable-*' -prune -o -printf '%y %p\n' 2>/dev/null || find . -name 'movable-*' -prune -o -exec stat -f '%HT %N' {} + ) | sort; }
umask 022
names="adir afile dirlink filelink dangling missing"
# An array, so the bare name (the empty spelling) is one of the cases: written
# as a string it was word-split away, and 156 of the pairs never ran.
spellings=("" "/" "/." "//" "/.." "/./")
pairs=0
for name in $names; do
	for spelling in "${spellings[@]}"; do
		fixture "$TMP/sp-plain"; fixture "$TMP/sp-confined"
		plain=$(cd "$TMP/sp-plain" && capped 60 "$(bin plain)" "work/${name}${spelling}" work) || { echo "FAIL: the plain app did not finish for '${name}${spelling}'"; exit 1; }
		confined=$(cd "$TMP/sp-confined" && capped 60 "$(bin confined)" "work/${name}${spelling}" work) || { echo "FAIL: the confined app did not finish for '${name}${spelling}'"; exit 1; }
		diff <(echo "$plain") <(echo "$confined") > "$TMP/spellings.diff" || {
			echo "FAIL: the backends answer differently for '${name}${spelling}' (plain < > confined):"
			head -20 "$TMP/spellings.diff"; exit 1
		}
		# The trees must match afterwards too: an operation that changed one and
		# not the other is a difference the outcome lines cannot show.
		diff <(snapshot "$TMP/sp-plain") <(snapshot "$TMP/sp-confined") > "$TMP/tree.diff" || {
			echo "FAIL: the trees differ after '${name}${spelling}' (plain < > confined):"
			head -20 "$TMP/tree.diff"; exit 1
		}
		pairs=$((pairs + $(wc -l <<<"$plain" | tr -d ' ')))
	done
done
echo "ok: $pairs operation-spelling pairs answer the same on both filesystems, each against a fresh tree"
