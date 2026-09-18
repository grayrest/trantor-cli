# Three things that reported success, or reported the wrong failure; the third,
# a signal death reported as `Ok(-1)` by `Cmd.exec_exit_code!`, moved to
# trantor-process with `Cmd`, whose copy of this suite still checks all three.
#
# `File.Reader.read_line!` split any line past its 1MiB cap into chunks a caller
# cannot tell from real lines. `Env.var!` mapped every `std::env::var` error to
# `VarNotFound`, so a variable SET with a non-UTF-8 value read exactly like one
# never set. Each is asserted next to the case that always worked, so a version
# that failed everything would not pass.
#
# Two more in the same places: the cap itself was off by one, so a last line of
# exactly 1MiB was LineTooLong and lost; and a variable name holding `=`, NUL,
# or nothing was looked up anyway, which read a different variable.
source ../lib.sh
new_project
mkdir -p "$TMP/lines"
python3 -c "open('$TMP/lines/long.txt','w').write('a'*2000000 + chr(10) + 'short' + chr(10))"
printf 'one\ntwo\n' > "$TMP/lines/ok.txt"
# The cap is 1 MiB: a last line exactly that long was LineTooLong and lost.
python3 -c "open('$TMP/lines/exact.txt','w').write('a'*1048576)"
python3 -c "open('$TMP/lines/exact-nl.txt','w').write('a'*1048576 + chr(10))"
python3 -c "open('$TMP/lines/over.txt','w').write('a'*1048577)"
build_app app.roc three
three=$(cd "$TMP/lines" && env "BADVAR=$(printf '\xff\xfe')" "KEYX=B=v" "$(bin three)") \
	|| { echo "FAIL: the three-defect app did not run"; exit 1; }
want="eof2 toolong bytes notfound eof1 eof1 toolong invalid invalid invalid"
[[ "$three" == "$want" ]] || {
	echo "FAIL: outcomes were '$three', want '$want'"
	echo "       (short-file long-file set-nonutf8 unset exact-cap exact-cap-newline cap-plus-one key-with-= empty-key key-with-nul)"; exit 1; }
echo "ok: a long line, a line exactly at the cap, a non-UTF-8 variable and an invalid variable name each report themselves"
