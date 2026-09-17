# A consumer built from scratch: world.toml and app/main.roc, one [deps] line,
# no wiring and no driver — and stdout and the filesystem work from it.
source ../lib.sh
new_project
n=$(cd "$TMP/myapp" && ls -1 world.toml app/main.roc | wc -l | tr -d ' ')
[[ "$n" == 2 ]] || { echo "FAIL: consumer is not two authored files"; exit 1; }
grep -q '^\[wiring\]\|^driver' "$TMP/myapp/world.toml" && { echo "FAIL: consumer had to declare wiring or a driver"; exit 1; }
echo "ok: a consumer is world.toml + app/main.roc, with one [deps] line"
# The app `trantor new` wrote has to build as written: the scaffold once wrote a
# `main!` signature this package's driver no longer accepted.
"$TRANTOR" check "$TMP/myapp" >/dev/null 2>&1 || { echo "FAIL: the scaffolded app does not typecheck against this package"; exit 1; }
echo "ok: the app trantor new writes typechecks untouched"
cp app.roc "$TMP/myapp/app/main.roc"
got=$("$TRANTOR" run "$TMP/myapp" 2>/dev/null) || { echo "FAIL: run"; exit 1; }
want='Writing a string to out.txt
I read the file back. Its contents are: "a string!"'
[[ "$got" == "$want" ]] || { echo "FAIL: got:"; echo "$got"; exit 1; }
echo "ok: stdout and the filesystem work from a two-file project"
