# The default and the confined filesystem give the same outcome for the same
# call.
#
# They did not, in ways an end-to-end review found and no diff showed: a
# confined path lost its trailing `/`, so writing `out/` made a file and
# deleting `dirlink/` removed the link where unconfined it emptied the
# directory; copies kept timestamps and dropped setuid on one backend and not
# the other, and refused a bad copy in a different order; a file's descriptor
# as the base of an `*_at!` call resolved against the process cwd. A confined
# path also lost a trailing `/.`, so `keep.txt/.` overwrote keep.txt and
# `filelink/.` deleted the link, and `dirlink/` was NotADirectory where the
# kernel follows the link. A FIFO copy source hung both. A tree copy made
# directories under the umask, so a 0700 directory copied as 0755, and a
# link's own mode bits decided whether it was executable, or its own length
# its size. Confined, removing
# `tree/` emptied it and failed (cap-std refuses the slash), while the macOS
# kernel removed the directory `link/` leads to; `dangling/` made the link's
# missing target; and the root named without a slash was refused as a
# directory name confined and answered by the OS unconfined. create_all! kept
# following a dangling link out of the tree, a rename guard called every stat
# failure NotADirectory, and a directory descriptor read as an empty file. The same app
# runs on both worlds from identical fixtures, and the outputs must match line
# for line; the script then checks what each copy actually carries.
source ../lib.sh
# The 000 fixture must not block the harness cleaning up.
trap 'chmod 700 "$TMP"/p/shut "$TMP"/c/shut 2>/dev/null || true' EXIT
fixture() {
	mkdir -p "$1/adir"
	echo keep > "$1/keep.txt"; echo ren > "$1/ren.txt"; echo x > "$1/adir/inner"
	ln -s keep.txt "$1/filelink"
	printf '#!/bin/sh\n' > "$1/setuid.sh"; chmod 4755 "$1/setuid.sh"
	echo old > "$1/old.txt"; touch -t 200001010000 "$1/old.txt"
	ln -s adir "$1/dirlink"
	mkdir -p "$1/sub" "$1/radir"; ln -s ../radir "$1/sub/q"
	mkfifo "$1/fifo"
	mkdir -p "$1/shut/d"; chmod 000 "$1/shut"
	mkdir -p "$1/private" "$1/readonly" "$1/shared"; chmod 700 "$1/private"; chmod 555 "$1/readonly"; chmod 2750 "$1/shared"
	mkdir -p "$1/empty" "$1/tree/d" "$1/emptytarget" "$1/treetarget"; echo t > "$1/tree/d/f"; echo t > "$1/treetarget/f"
	ln -s emptytarget "$1/emptylink"; ln -s treetarget "$1/treelink"
	printf '0123456789' > "$1/big.txt"; ln -s big.txt "$1/biglink"
	echo shut > "$1/shutfile"; chmod 000 "$1/shutfile"; ln -s shutfile "$1/shutlink"
	echo ro > "$1/rofile"; chmod 444 "$1/rofile"; ln -s rofile "$1/rolink"
	ln -s missing "$1/dangling"; ln -s keep.txt "$1/noexec-link"; ln -s setuid.sh "$1/setuid-link"
}
new_project
build_app app.roc plain
printf '\n[wiring]\nfs = "fs-confined"\n' >> "$TMP/myapp/world.toml"
build_app app.roc confined
fixture "$TMP/p"; fixture "$TMP/c"
umask 022
plain=$(cd "$TMP/p" && capped 60 "$(bin plain)") || { echo "FAIL: the plain app did not finish"; exit 1; }
confined=$(cd "$TMP/c" && capped 60 "$(bin confined)") || { echo "FAIL: the confined app did not finish"; exit 1; }
diff <(echo "$plain") <(echo "$confined") > "$TMP/agree.diff" || {
	echo "FAIL: the backends disagree (plain < > confined):"; cat "$TMP/agree.diff"; exit 1; }
mode() { python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o7777, "o"))' "$1"; }
year() { python3 -c 'import os,sys,time; print(time.gmtime(os.stat(sys.argv[1]).st_mtime).tm_year)' "$1"; }
for d in p c; do
	[[ ! -e "$TMP/$d/out" ]] || { echo "FAIL: $d: writing out/ created a file named out"; exit 1; }
	[[ -e "$TMP/$d/ren.txt" && ! -e "$TMP/$d/k3" ]] || { echo "FAIL: $d: renaming a file to k3/ moved it"; exit 1; }
	[[ "$(mode "$TMP/$d/setuid-copy.sh")" == 755 ]] || { echo "FAIL: $d: the setuid copy has mode $(mode "$TMP/$d/setuid-copy.sh"), want 755"; exit 1; }
	[[ "$(year "$TMP/$d/old-copy.txt")" != 2000 ]] || { echo "FAIL: $d: the copy kept the source's 2000 timestamp"; exit 1; }
	[[ "$(cat "$TMP/$d/keep.txt")" == keep && -L "$TMP/$d/filelink" ]] || { echo "FAIL: $d: a /. path changed keep.txt or its link"; exit 1; }
	[[ ! -e "$TMP/$d/empty" && ! -e "$TMP/$d/tree" ]] || { echo "FAIL: $d: empty/ or tree/ was not removed"; exit 1; }
	[[ -d "$TMP/$d/emptytarget" && -f "$TMP/$d/treetarget/f" && -L "$TMP/$d/emptylink" && -L "$TMP/$d/treelink" ]] || { echo "FAIL: $d: removing link/ touched the link or where it leads"; exit 1; }
	[[ ! -e "$TMP/$d/missing" && -d "$TMP/$d/cd1" && -d "$TMP/$d/cd2" && ! -L "$TMP/$d/cd2" ]] || { echo "FAIL: $d: a directory-name copy or mkdir made the wrong thing"; exit 1; }
	[[ "$(mode "$TMP/$d/private.txt")" == 600 && "$(mode "$TMP/$d/private-dir")" == 700 ]] || { echo "FAIL: $d: a named mode did not reach the OS (file $(mode "$TMP/$d/private.txt"), dir $(mode "$TMP/$d/private-dir"))"; exit 1; }
	for n in newf newlink cs2 oc fifo-copy; do [[ ! -e "$TMP/$d/$n" && ! -L "$TMP/$d/$n" ]] || { echo "FAIL: $d: a refused call created $n"; exit 1; }; done
	for pair in private-copy:700 readonly-copy:755 shared-copy:750; do
		[[ "$(mode "$TMP/$d/${pair%%:*}")" == "${pair#*:}" ]] || { echo "FAIL: $d: ${pair%%:*} has mode $(mode "$TMP/$d/${pair%%:*}"), want ${pair#*:}"; exit 1; }
	done
	[[ -d "$TMP/$d/q2" && ! -e "$TMP/$d/radir" && -L "$TMP/$d/sub/q" ]] || { echo "FAIL: $d: renaming sub/q/ should move the directory it links to, not the link"; exit 1; }
done
grep -q '^write-slash err:NotADirectory$' <<<"$plain" || { echo "FAIL: writing out/ should be NotADirectory: $(grep write-slash <<<"$plain")"; exit 1; }
grep -q '^copy-missing err:NotFound$' <<<"$plain" || { echo "FAIL: a missing source onto an existing file should report NotFound: $(grep copy-missing <<<"$plain")"; exit 1; }
for op in write-dot truncate-dot write-new-dot unlink-link-dot symlink-dot copy-dot open-create-slash; do
	grep -q "^$op err:NotADirectory$" <<<"$plain" || { echo "FAIL: $op should be NotADirectory: $(grep "^$op " <<<"$plain")"; exit 1; }
done
for want in "delete-all-dotdot err:Unsupported" "delete-empty-dotdot err:Unsupported" "symlink-dotdot err:AlreadyExists" "write-dotdot err:AlreadyExists" "symlink-missing-dotdot err:NotFound" "size-file 10" "size-link 10" "readable-link False" "writable-link False" "mkdir-all-existing-slash ok" "mkdir-all-dirlink-slash ok" "mkdir-all-deep-again ok" "mkdir-all-dangling-slash err:AlreadyExists" "mkdir-all-filelink-slash err:AlreadyExists" "mkdir-all-file-slash err:AlreadyExists" "rename-unreadable-slash err:PermissionDenied" "rename-missing-slash err:NotFound" "read-dir-stream err:IsADirectory" "delete-empty-slash ok" "delete-all-slash ok" "delete-empty-link-slash err:NotADirectory" "delete-all-link-slash err:NotADirectory" "mkdir-dangling-slash err:AlreadyExists" "copy-dir-link-slash ok" "copy-dir-onto-dangling-slash err:AlreadyExists" "copy-dir-onto-filelink-slash err:AlreadyExists" "copy-dir-new-slash ok" "open-create-dir-slash err:IsADirectory" "copy-dir-link err:NotADirectory" "copy-dir-file err:NotADirectory" "copy-dir-exists err:AlreadyExists" "exec-dangling err:NotFound" "exec-link-noexec False" "exec-link-exec True"; do
	grep -qx "$want" <<<"$plain" || { echo "FAIL: want '$want', got '$(grep "^${want%% *} " <<<"$plain")'"; exit 1; }
done
grep -q '^type-dirlink-slash IsDir$' <<<"$plain" || { echo "FAIL: dirlink/ should follow the link: $(grep type-dirlink-slash <<<"$plain")"; exit 1; }
grep -q '^file-base err:NotADirectory$' <<<"$plain" || { echo "FAIL: a file descriptor as a base should be NotADirectory: $(grep file-base <<<"$plain")"; exit 1; }
echo "ok: the default and confined filesystems agree on trailing slashes, copies and descriptor bases, $(wc -l <<<"$plain" | tr -d ' ') operations"
