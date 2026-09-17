# The swap the README promises, asserted where it is decided: which component's
# symbols the platform actually binds.
source ../lib.sh
new_project
"$TRANTOR" compose "$TMP/myapp" >/dev/null 2>&1 || { echo "FAIL: compose"; exit 1; }
M="$TMP/myapp/target/trantor/myapp/platform/main.roc"
before=$(grep -o 'trantor__fs_[a-z]*__' "$M" | sort -u)
[[ "$before" == "trantor__fs_unconfined__" ]] || { echo "FAIL: default fs is $before"; exit 1; }
printf '\n[wiring]\nfs = "fs-confined"\n' >> "$TMP/myapp/world.toml"
"$TRANTOR" compose "$TMP/myapp" >/dev/null 2>&1 || { echo "FAIL: compose with override"; exit 1; }
after=$(grep -o 'trantor__fs_[a-z]*__' "$M" | sort -u)
[[ "$after" == "trantor__fs_confined__" ]] || { echo "FAIL: override did not take — still $after"; exit 1; }
echo "ok: [wiring] fs = \"fs-confined\" beats the package default ($before -> $after)"
