# Three things that reported success, or reported the wrong failure; the third,
# a signal death reported as `Ok(-1)` by `Cmd.exec_exit_code!`, moved to
# trantor-process with `Cmd`, whose copy of this suite still checks all three.
#
# `File.Reader.read_line!` split any line past its 1MiB cap into chunks a caller
# cannot tell from real lines. `Env.var!` mapped every `std::env::var` error to
# `VarNotFound`, so a variable SET with a non-UTF-8 value read exactly like one
# never set. Each is asserted next to the case that always worked, so a version
# that failed everything would not pass.
source ../lib.sh
new_project
mkdir -p "$TMP/lines"
python3 -c "open('$TMP/lines/long.txt','w').write('a'*2000000 + chr(10) + 'short' + chr(10))"
printf 'one\ntwo\n' > "$TMP/lines/ok.txt"
build_app app.roc three
three=$(cd "$TMP/lines" && env "BADVAR=$(printf '\xff\xfe')" "$(bin three)") \
	|| { echo "FAIL: the three-defect app did not run"; exit 1; }
[[ "$three" == "eof2 toolong bytes notfound" ]] || {
	echo "FAIL: outcomes were '$three', want 'eof2 toolong bytes notfound'"
	echo "       (short-file long-file set-nonutf8 unset)"; exit 1; }
echo "ok: a long line and a non-UTF-8 variable each report themselves"
