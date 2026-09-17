# The confined root holds under a concurrent swap, for every filesystem
# operation that takes a path.
#
# It used to check a canonicalized path with `starts_with(base)` and then hand
# the ORIGINAL path to std::fs, so the path was resolved twice and a directory
# component swapped for a symlink in between escaped. Measured with exactly
# this swapper, 20,000 reads per run: 192, 970 and 323 of them returned the
# OUTSIDE file. The root is a cap-std directory handle now, resolved component
# by component at the moment of use, so there is no separate check to race.
#
# Each operation races at least 2000 times, then for up to 10 s more until both
# controls below have been seen (app.roc's `race!` says why). Reads report what
# they saw; a write cannot see where it landed, so the outside directory is
# checked afterwards for anything the writes left there. That check is what
# found cap-std's `Dir::copy` resolving the destination itself on macOS and
# writing 108 of 2000 copies outside.
#
# Two controls per operation keep it from passing vacuously. REFUSED must be
# nonzero, or the swapper never landed inside that operation and "no escapes"
# proves nothing; INSIDE must be nonzero, or the operation was failing outright.
# A link to outside the root, absolute or relative, or to nothing, must be
# refused when it is created; a link to a file inside is made and followed; a
# link valid where it was made cannot be moved or hard-linked to where it is
# not; and a copy that fails leaves no file behind.
source ../lib.sh
new_project
printf '\n[wiring]\nfs = "fs-confined"\n' >> "$TMP/myapp/world.toml"
build_app app.roc race
RR="$TMP/raceroot"; RO="$TMP/raceout"
mkdir -p "$RR/sub" "$RO" "$RR/private-src"
echo INSIDE > "$RR/sub/secret.txt"; echo OUTSIDE > "$RO/secret.txt"
echo ROOT > "$RR/secret-root.txt"; chmod 750 "$RR/secret-root.txt"
ln -s INSIDE "$RR/sub/lnk"; ln -s OUTSIDE "$RO/lnk"
touch "$RO/outside-only.txt"
ln -s "$RR/secret-root.txt" "$RR/abs-link"; ln -s gone "$RR/dangling"
mkdir -p "$RR/m1" "$RR/m2"; ln -s ../secret-root.txt "$RR/m1/rel"
before=$(ls -A "$RO")
python3 swapper.py "$RR" "$RO" 2>/dev/null & PIDS="$PIDS $!"
raceout=$(cd "$RR" && capped 300 "$(bin race)" "$RO" "../raceout") || { echo "FAIL: the race app did not finish"; exit 1; }
failed=0
while read -r op r_in r_out r_ref r_tries; do
	if [[ "$op" == planted ]]; then
		[[ "$r_in" == "refused,refused,refused,made,inside,refused,clean,allowed,denied" ]] || { echo "FAIL: planted links (absolute relative dangling inside followed moved copy-dir allowed-moves dangling-moved): '$r_in', want 'refused,refused,refused,made,inside,refused,clean,allowed,denied'"; failed=1; }
		continue
	fi
	[[ "$r_out" == 0 ]] || { echo "FAIL: $op: $r_out of $r_tries escaped the confined root (inside=$r_in refused=$r_ref)"; failed=1; }
	[[ "$r_ref" -gt 0 ]] || { echo "FAIL: $op: never refused in $r_tries attempts — the swapper never raced it, so 0 escapes proves nothing"; failed=1; }
	[[ "$r_in" -gt 0 ]] || { echo "FAIL: $op: never succeeded in $r_tries attempts — it is failing outright"; failed=1; }
done <<<"$raceout"
ran=$(grep -vc planted <<<"$raceout" || true)
[[ "$ran" == 12 ]] || { echo "FAIL: $ran operations reported, want 12 — a missing line is a check that never ran"; failed=1; }
grep -q '^planted ' <<<"$raceout" || { echo "FAIL: the planted-link case did not report"; failed=1; }
after=$(ls -A "$RO")
[[ "$after" == "$before" ]] || { echo "FAIL: writes escaped the confined root; outside now holds:"; comm -13 <(echo "$before") <(echo "$after") | head -5; failed=1; }
[[ "$failed" == 0 ]] || exit 1
# Stop the swapper before looking, or `find` races it too. `find` does not
# follow the swapped link, so it sees only files inside.
for p in $PIDS; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
copy=""
for f in $(find "$RR" -type f -name 'copied-in-*'); do copy=$f; break; done
[[ -n "$copy" && "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$copy")" == 750 ]] || { echo "FAIL: a confined copy did not keep mode 750 ('$copy')"; exit 1; }
echo "ok: the confined root holds under a concurrent symlink swap for all $(grep -vc planted <<<"$raceout") path operations, and refuses links to outside it"
