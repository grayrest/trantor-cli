# The other surface. The point of the package is that an app may skip the shim
# entirely and program the hosted capabilities directly — same platform, same
# composition, no Path and no Stdout anywhere.
source ../lib.sh
grep -q 'pf.Stdout\|pf.Path\|pf.Env' app.roc && { echo "FAIL: positive control — that app uses the shim after all"; exit 1; }
new_project
cp app.roc "$TMP/myapp/app/main.roc"
raw=$("$TRANTOR" run "$TMP/myapp" 2>/dev/null) || { echo "FAIL: the WASI-derived layer does not build"; exit 1; }
[[ "$raw" == "argc=1" ]] || { echo "FAIL: raw layer gave '$raw', want 'argc=1'"; exit 1; }
echo "ok: the WASI-derived layer runs with no shim import at all"
