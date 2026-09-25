# The confined root is found and opened at the first `Fs` call, and both ways
# that can fail are the calling operation's error rather than a panic.
#
# It was `std::env::current_dir().expect("cwd")` and
# `Dir::open_ambient_dir(..).expect("open the confined root")`, both reachable:
# a working directory deleted after the process started (getcwd answers ENOENT)
# and one that is searchable but not readable (mode 0311, the open answers
# EACCES). The confined app died in the panic hook and the driver exited 70,
# where the default backend answers the same call NotFound or PermissionDenied
# and exits 0. The two must agree here as they do everywhere else, so each case
# runs on both backends and both must print the same tag.
source ../lib.sh
# A 0311 directory the harness must still be able to clean up.
trap 'chmod 700 "$TMP/noread" 2>/dev/null || true' EXIT
new_project
build_app app.roc plain
printf '\n[wiring]\nfs = "fs-confined"\n' >> "$TMP/myapp/world.toml"
build_app app.roc confined
mkdir -p "$TMP/noread"; chmod 311 "$TMP/noread"
for w in plain confined; do
	# rmdir of the working directory from inside it: the process keeps running
	# with a cwd no path leads to.
	mkdir -p "$TMP/gone"
	gone=$(cd "$TMP/gone" && rmdir "$TMP/gone" && capped 60 "$(bin "$w")") \
		|| { echo "FAIL: $w exited $? in a deleted working directory"; exit 1; }
	[[ "$gone" == "NotFound" ]] || { echo "FAIL: $w in a deleted working directory said '$gone', want 'NotFound'"; exit 1; }
	noread=$(cd "$TMP/noread" && capped 60 "$(bin "$w")") \
		|| { echo "FAIL: $w exited $? in an unreadable working directory"; exit 1; }
	[[ "$noread" == "PermissionDenied" ]] || { echo "FAIL: $w in an unreadable working directory said '$noread', want 'PermissionDenied'"; exit 1; }
done
echo "ok: a deleted or unreadable working directory is NotFound or PermissionDenied on both backends, not a panic"
