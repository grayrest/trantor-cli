# A path built from Windows UTF-16 units keeps what it was given, and a Unix
# host refuses to write through it rather than transcoding it somewhere else.
#
# `StrPath/OsPath.windows_u16s` (removed with those modules) was
# `|_u| from_str("")`: the argument discarded and the EMPTY path returned. Empty
# is cwd-relative, so `join(windows_u16s("sub"), "note.txt")` produced
# "note.txt" and the write landed beside the program. `Path` keeps the units
# and its host has no Windows paths, so the write is an error. Asserted by
# WHICH FILE EXISTS afterwards, because a misplaced write is the damage.
source ../lib.sh
new_project
mkdir -p "$TMP/myapp/sub"
build_app app.roc u16
shown=$(cd "$TMP/myapp" && ./target/trantor/myapp/bin/u16) || { echo "FAIL: the utf-16 path app did not run"; exit 1; }
[[ "$shown" == 'sub\note.txt refused' ]] || { echo "FAIL: the utf-16 path app said '$shown', want 'sub\\note.txt refused'"; exit 1; }
[[ ! -e "$TMP/myapp/note.txt" ]] || { echo "FAIL: the write escaped to note.txt, beside the program"; exit 1; }
[[ ! -e "$TMP/myapp/sub/note.txt" ]] || { echo "FAIL: a Windows path was written on a Unix host"; exit 1; }
[[ -z "$(ls -A "$TMP/myapp/sub")" ]] || { echo "FAIL: something was written in sub: $(ls -A "$TMP/myapp/sub")"; exit 1; }
echo "ok: a UTF-16 path keeps its units, and a Unix host refuses to write through it"
