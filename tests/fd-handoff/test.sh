# FdHandoff gives another package's host the OS file behind a resource.
#
# Nothing in this package reads the numbers; trantor-process's spawn does. So
# this checks what spawn relies on: the fd is the SAME open file (read back
# through /dev/fd), it is a duplicate the caller owns (stdout's is not fd 1, and
# closing it does not close the reader), a resource with no file under it
# answers NotAFile, and close_fd! releases it.
source ../lib.sh
new_project
# Not a package export: a test world names it to reach it.
python3 -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("[world]\n", "[world]\nexports = [\"FdHandoff\"]\n", 1))' "$TMP/myapp/world.toml"
D="$TMP/handoff"
mkdir -p "$D/sub"
echo HANDED > "$D/handed.txt"
build_app app.roc handoff
got=$(cd "$D" && "$(bin handoff)") || { echo "FAIL: the handoff app did not run"; exit 1; }
want="HANDED fd fd notafile unreadable"
[[ "$got" == "$want" ]] || {
	echo "FAIL: outcomes were '$got'"
	echo "                 want '$want'"
	echo "      (reader-fd-reads-file writer-fd stdout-dup directory-notafile closed)"; exit 1; }
# Started with stdin closed. The driver now opens fd 0 on /dev/null before
# the app runs (trantor D-S2-29), and the handoff's own floor of fd 3 backs
# that up; either way the stdout handoff, made before any file is open, must
# not be numbered 0-2.
closed=$(cd "$D" && "$(bin handoff)" <&-) || { echo "FAIL: the handoff app did not run with stdin closed"; exit 1; }
[[ "$closed" == "$want" ]] || { echo "FAIL: with stdin closed, outcomes were '$closed', want '$want'"; exit 1; }
# Out of descriptors, a stream that has one is Io, not NotAFile: spawn used to
# blame the redirect for running out of fds.
exhausted=$(cd "$D" && ulimit -n 64 && "$(bin handoff)" exhaust) || { echo "FAIL: the exhaustion run did not finish"; exit 1; }
[[ "$exhausted" == io ]] || { echo "FAIL: a handoff with no fds left answered '$exhausted', want io"; exit 1; }
# And a reader refuses at the open, rather than answering Ok and failing on the
# first read, which is where the stream's own failure used to surface.
readers=$(cd "$D" && ulimit -n 64 && "$(bin handoff)" exhaust readers) || { echo "FAIL: the reader exhaustion run did not finish"; exit 1; }
[[ "$readers" == open-refused ]] || { echo "FAIL: with no fds left, opening a reader answered '$readers', want open-refused"; exit 1; }
echo "ok: FdHandoff hands over an owned duplicate of the open file, NotAFile without one, Io when none can be made, and closes it"
