# Exit is an effect (roc:cli/exit), so it is the only way an app names its own
# status — and nothing else in either repo exercises it. b8's upstream examples
# cannot: basic-cli had no such call.
source ../lib.sh
new_project
build_app app.roc exiter
EXITER=$(bin exiter)
# `|| x=$?`, because a nonzero exit is the point here and `set -e` would
# otherwise kill the script before the status could be read.
plain=0; "$EXITER" 2>"$TMP/plain.err" || plain=$?
coded=0; "$EXITER" one 2>"$TMP/coded.err" || coded=$?
failed=0; "$EXITER" one two 2>"$TMP/failed.err" || failed=$?
[[ "$plain" == 0 ]] || { echo "FAIL: returning Ok gave status $plain, want 0"; exit 1; }
[[ "$coded" == 7 ]] || { echo "FAIL: Cli.exit!(7) gave status $coded, want 7"; exit 1; }
# An unhandled Err is 1 and says what it was, in basic-cli 0.21's words; it
# used to exit 1 with nothing on stderr.
[[ "$failed" == 1 ]] || { echo "FAIL: an unhandled Err gave status $failed, want 1"; exit 1; }
want='Program exited with error: Boom("unhandled")'
[[ "$(cat "$TMP/failed.err")" == "$want" ]] || { echo "FAIL: an unhandled Err wrote '$(cat "$TMP/failed.err")' to stderr, want '$want'"; exit 1; }
[[ ! -s "$TMP/plain.err" && ! -s "$TMP/coded.err" ]] || { echo "FAIL: Ok or Cli.exit! wrote to stderr"; exit 1; }
echo "ok: exit is an effect — Ok is 0, Cli.exit!(7) is 7, an unhandled Err is 1 and names itself on stderr"
