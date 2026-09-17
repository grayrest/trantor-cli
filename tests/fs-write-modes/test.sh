# Append, streaming writes, WASI's open flags and directory entry kinds,
# observed in the file.
#
# Before this, a file could be written only whole: no append, no stream, no
# exclusive create. Each case reads the file back rather than trusting a
# returned Ok. Unbuffered writes are checked by reading the file while its
# writer is still alive, and append mode by interleaving two appenders, which a
# seek-then-write implementation passes only by luck and a shared cursor fails.
source ../lib.sh
new_project
W="$TMP/wm"
mkdir -p "$W/sub/deeper"
ln -s ../target.txt "$W/sub/back"
ln -s sub "$W/sublink"
mkfifo "$W/fifo" "$W/fifo2"
cat "$W/fifo" > "$W/fifo.out" & PIDS="$PIDS $!"
cat "$W/fifo2" > "$W/fifo2.out" & PIDS="$PIDS $!"
echo inner > "$W/sub/inner.txt"
echo target > "$W/target.txt"
ln -s target.txt "$W/link.txt"
: > "$W/writeonly.txt"; chmod 200 "$W/writeonly.txt"
build_app app.roc writemodes
got=$(cd "$W" && "$(bin writemodes)") || { echo "FAIL: the write-modes app did not run"; exit 1; }
want="abc xy_/xy_z 1234 hELlo exists,created followed,refused inner,notdir,unsupported wrote back:SymLink,deeper:Dir,inner.txt:File fifo-ok True,False,False XYllo!,XYllo!? fifo-append-ok"
[[ "$got" == "$want" ]] || {
	echo "FAIL: outcomes were '$got'"
	echo "                 want '$want'"
	echo "      (append+truncate writer-unbuffered two-appenders offset exclusive nofollow directory write-only entries fifo identity append-modes fifo-append)"; exit 1; }
wait
[[ "$(cat "$W/fifo2.out")" == "appended" ]] || { echo "FAIL: the append FIFO reader got '$(cat "$W/fifo2.out")'"; exit 1; }
[[ "$(cat "$W/fifo.out")" == "through-fifo" ]] || { echo "FAIL: the FIFO reader got '$(cat "$W/fifo.out")'"; exit 1; }
chmod 600 "$W/writeonly.txt"
[[ "$(cat "$W/writeonly.txt")" == "w" ]] || { echo "FAIL: the write-only file holds '$(cat "$W/writeonly.txt")'"; exit 1; }
echo "ok: append, unbuffered and offset writes, and open's exclusive, nofollow and directory flags land in the file"
