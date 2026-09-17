# A RELATIVE userland cwd means one directory to every path op, and a cwd that
# cannot be one is refused.
#
# A relative one was stored as given and then joined onto preopen 0, so "sub"
# meant /sub: the comment in FsOps.set_cwd! calls that the dangerous one. The
# suite that covered it moved to trantor-process with the child's cwd; this is
# the half that belongs to the package that owns set_cwd!, and it covers every
# op the S2 work added as well as reading.
source ../lib.sh
new_project
mkdir -p "$TMP/cwdcheck/sub"
echo "INSIDE-SUB" > "$TMP/cwdcheck/sub/marker.txt"
echo "TOPLEVEL"   > "$TMP/cwdcheck/marker.txt"
build_app app.roc cwd
out=$(cd "$TMP/cwdcheck" && capped 60 "$(bin cwd)") || { echo "FAIL: the cwd app did not run"; exit 1; }
[[ "$out" == "INSIDE-SUB marker.txt refused refused" ]] || { echo "FAIL: outcomes were '$out', want 'INSIDE-SUB marker.txt refused refused'"; exit 1; }
for made in written.txt streamed.txt copied.txt linked made/deep; do
	[[ -e "$TMP/cwdcheck/sub/$made" ]] || { echo "FAIL: $made was not made under the relative cwd"; exit 1; }
	[[ ! -e "$TMP/cwdcheck/$made" ]] || { echo "FAIL: $made was made beside the relative cwd, not under it"; exit 1; }
done
[[ "$(cat "$TMP/cwdcheck/sub/written.txt")" == wa ]] || { echo "FAIL: write then append under a relative cwd left '$(cat "$TMP/cwdcheck/sub/written.txt")'"; exit 1; }
echo "ok: every path op resolves against a relative userland cwd, and a bad cwd is refused"
