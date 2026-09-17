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
echo "ok: a non-UTF-8 argument arrives as UnixBytes and a text one as Utf8 — argv keeps its bytes"
