import sys, tomllib, pathlib
pkg = pathlib.Path(sys.argv[1])
p = tomllib.loads((pkg / "package.toml").read_text())

# Every interface is in exactly one of these, and the check fails in BOTH
# directions — a module that quietly appears in exports is as wrong as one that
# quietly leaves. The older version only looked for absences, so re-exposing
# `cwd` or `random` would have gone unnoticed.
BEHIND_FACADE = {"cli-env", "cli-exit", "cli-stdin", "cli-stdout"}  # -> Cli
INTERNAL = {"cwd", "random", "fd-handoff"}   # userland cwd slot: plumbing. random: `Random` is the door. fd-handoff: raw fds for another package's host.
FACADE = "Cli"
# The shim surface, by name. It used to be asserted only as "not empty", so
# three modules could vanish from the offer and this stayed green — verified by
# deleting File, StrPath and OsPath and watching it pass. The offer is a
# deliberate list, so changing it should mean changing this line.
SHIM = {"Env", "File", "Locale", "Path", "Random", "Sleep",
        "Stderr", "Stdin", "Stdout", "Url", "Utc"}

exports = set(p["package"]["exports"])
direct, hidden = set(), set()
for i in p["interfaces"]:
    module = tomllib.loads((pkg / "interfaces" / i / "interface.toml").read_text())["module"]
    (hidden if i in BEHIND_FACADE | INTERNAL else direct).add((i, module))

def fail(msg):
    print(f"FAIL: {msg}")
    raise SystemExit(1)

missing = sorted(m for _, m in direct if m not in exports)
if missing:
    fail(f"the WASI-derived layer is not exposed: {missing}")
leaked = sorted(f"{i} -> {m}" for i, m in hidden if m in exports)
if leaked:
    fail(f"an interface meant to sit behind {FACADE} or stay internal is exported: {leaked}")
if FACADE not in exports:
    fail(f"{FACADE} is not exported, so five interfaces are now unreachable")
shim = exports - {m for _, m in direct} - {FACADE}
if shim != SHIM:
    fail(f"the shim surface changed: missing {sorted(SHIM - shim)}, unexpected {sorted(shim - SHIM)}")
if not direct or not hidden or not shim:
    fail("one of the three groups is empty - the check is vacuous")
raw = {m for _, m in direct} | {FACADE}
print(f"ok: both surfaces exposed - {len(raw)} WASI-derived ({len(hidden)} behind {FACADE}/internal), "
      f"{len(exports) - len(raw)} shim, {len(exports)} total, "
      f"{len(p['provides'])} wiring, {len(p['components'])} components")
