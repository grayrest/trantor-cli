# A non-UTF-8 argument reaches `main!` as bytes.
#
# Three states so far: `std::env::args()` panicked on one, killing every app
# before its code ran; then a lossy `args_os()` fixed the crash by throwing the
# bytes away; now `CliEnv.args!` and `main!` name the same `OsStr` nominal, so
# nothing converts. Only the last is correct and only a test tells them apart —
# the first two both pass a check that merely runs.
source ../lib.sh
new_project
build_app app.roc argv
raw=$("$(bin argv)" $'\xff\xfe' plain) || { echo "FAIL: a non-UTF-8 argument crashed the app"; exit 1; }
# Both halves: without the second, a host that made EVERYTHING UnixBytes would pass.
[[ "$raw" == "UnixBytes,Utf8" ]] || { echo "FAIL: argv tags were '$raw', want 'UnixBytes,Utf8'"; exit 1; }

# The process's own paths keep their bytes too, and say when they are missing.
# They were lossy `Str`s, and `""` for a cwd that was gone — which a relative
# path was then joined onto, so `etc/hosts` read /etc/hosts.
# `inspect TEXT` is how OsStr's `Str.inspect` shows these bytes.
inspect() { python3 -c 'import sys; b = sys.argv[1].encode("utf-8", "surrogateescape"); print(("OsStr.utf8(\"%s\")" % b.decode()) if all(c < 128 for c in b) else "OsStr.unix_bytes([%s])" % ", ".join(map(str, b)))' "$1"; }
weird=$'/nowhere/t\xff'
paths=$(cd "$TMP" && TMPDIR="$weird" "$(bin argv)" paths etc/hosts) || { echo "FAIL: the paths app did not run"; exit 1; }
for want in "env-temp $(inspect "$weird")" "cli-temp $(inspect "$weird")" "env-cwd $(inspect "$TMP")" "cli-cwd $(inspect "$TMP")" "cli-exe $(inspect "$(bin argv)")" "env-exe $(inspect "$(bin argv)")"; do
	grep -qxF "$want" <<<"$paths" || { echo "FAIL: want '$want' in:"; echo "$paths"; exit 1; }
done
mkdir "$TMP/gone"
gone=$(cd "$TMP/gone" && rmdir "$TMP/gone" && "$(bin argv)" paths etc/hosts) || { echo "FAIL: the paths app did not run in a deleted directory"; exit 1; }
for want in "env-cwd CwdUnavailable" "cli-cwd Io(NotFound)" "relative-read err:NotFound"; do
	grep -qxF "$want" <<<"$gone" || { echo "FAIL: in a deleted cwd, want '$want' in:"; echo "$gone"; exit 1; }
done
# A directory name that is not UTF-8, where the filesystem allows one (APFS
# does not).
if mkdir "$TMP/d"$'\xff' 2>/dev/null; then
	named=$(cd "$TMP/d"$'\xff' && "$(bin argv)" paths x) || { echo "FAIL: the paths app did not run in a non-UTF-8 directory"; exit 1; }
	grep -qxF "env-cwd $(inspect "$TMP/d"$'\xff')" <<<"$named" || { echo "FAIL: a non-UTF-8 cwd lost its bytes:"; echo "$named"; exit 1; }
fi
echo "ok: a non-UTF-8 argument arrives as UnixBytes and a text one as Utf8, the process's own paths keep their bytes, and a deleted cwd is an error"
