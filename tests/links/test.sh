# Single-file copy and symlinks, each checked against the filesystem itself.
#
# A copy made by reading and writing bytes loses the executable bit, so the
# copy is a host operation and this asserts the bit with `test -x` as well as
# through the app. An existing destination is refused rather than replaced, and
# a link keeps its target unresolved, which a tree copy depends on.
source ../lib.sh
new_project
L="$TMP/links"
mkdir -p "$L"
printf '#!/bin/sh\necho hi\n' > "$L/tool.sh"; chmod 755 "$L/tool.sh"
echo keep > "$L/keep.txt"
build_app app.roc links
got=$(cd "$L" && "$(bin links)") || { echo "FAIL: the links app did not run"; exit 1; }
want="True,True exists,keep keep.txt,keep,True ../nowhere"
[[ "$got" == "$want" ]] || {
	echo "FAIL: outcomes were '$got'"
	echo "                 want '$want'"
	echo "      (copy-mode copy-existing link-round-trip dangling)"; exit 1; }
[[ -x "$L/tool-copy.sh" ]] || { echo "FAIL: the copy is not executable"; exit 1; }
[[ "$(readlink "$L/keep-link")" == "keep.txt" ]] || { echo "FAIL: the link holds '$(readlink "$L/keep-link")'"; exit 1; }
echo "ok: a copy keeps its mode and refuses to replace, and a link keeps its target as written"
