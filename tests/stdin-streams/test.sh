# Stdin streams share the process-wide buffer and never hold its lock between
# calls.
#
# Each stream used to hold a `StdinLock` for its whole life. That lock is not
# reentrant, so an app that kept one stdin stream and took a second, or called
# `Stdin.line!`, blocked forever on its next read.
source ../lib.sh
new_project
build_app app.roc streams
got=$(printf '1\n2\n3\n4\n5\n' | capped 20 "$(bin streams)") || { echo "FAIL: reading with two stdin streams held did not finish"; exit 1; }
[[ "$got" == "1 2 3 4 5" ]] || { echo "FAIL: two stdin streams read '$got', want '1 2 3 4 5'"; exit 1; }
# On a terminal, one Ctrl-D must end a stream read. `fill_buf` filled, dropped
# the slice and filled again, and the second read(2) waited for another Ctrl-D.
eof=$(python3 "$PKG/tests/stdin-streams/on_a_terminal.py" "$(bin streams)") || { echo "FAIL: the terminal end-of-input run did not finish: $eof"; exit 1; }
[[ "$eof" == "1=a 2=EOF" ]] || { echo "FAIL: on a terminal one Ctrl-D gave '$eof', want '1=a 2=EOF'"; exit 1; }
# One error mapping for both doors: Stdin.line! named three kinds and called
# everything else Other, so the same failure on the same fd read as
# IsADirectory through a stream and as Other through the line reader.
kinds=$(cd "$TMP" && "$(bin streams)" eof kinds < "$TMP") || { echo "FAIL: the stdin-kinds run did not finish"; exit 1; }
[[ "$kinds" == "err:IsADirectory err:IsADirectory" ]] || { echo "FAIL: a directory as stdin read as '$kinds', want 'err:IsADirectory err:IsADirectory'"; exit 1; }
echo "ok: stdin streams held together read the one buffer in order, without blocking each other"
