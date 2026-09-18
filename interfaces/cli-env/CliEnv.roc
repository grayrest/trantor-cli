import IOErr exposing [IOErr]
import OsStr exposing [OsStr]
## roc:cli/environment primitives, shaped after wasi:cli/environment.
##
## Lists cross whole. They used to arrive as count+at pairs because the glue of
## the day could not build a `RocList<RocStr>` host-side (R-B5); measured again
## on the pinned compiler, it can — a host-built list of records survives with
## its contents intact — so four count+at pairs across this package collapsed to
## four single leaves.
##
## `args!` exists for the DRIVER, which has no argv of its own: it is how argv
## reaches `main!`. An app already has its arguments as a parameter and should
## use that.
CliEnv :: [].{
	## The `OsStr` an app annotates `main!` with — the same nominal, so the
	## hosted list is handed over as it arrives.
	##
	## `std::env::args()` PANICS on a non-Unicode argument, and this is read
	## unconditionally to build `main!`'s parameter, so one such argument killed
	## every app before its code ran. It was briefly `List(Str)` built lossily
	## from `args_os()`, which fixed the crash by discarding the bytes; that was
	## a workaround for a type error I had misdiagnosed. A NEW nominal here does
	## break every app writing `main! : List(OsStr)` — but this IS that nominal.
	args! : {} => List(OsStr)
	## `OsStr`, because a variable's VALUE need not be UTF-8 and the answer to
	## "is it set?" should not depend on whether it is. `std::env::var` returns
	## `Err(NotUnicode)` for a non-UTF-8 value, and the host mapped every error
	## to `VarNotFound` — so a variable that was set, with a value the caller
	## could have used, reported identically to one that was never set at all.
	var! : OsStr => Try(OsStr, [VarNotFound(OsStr), Io(IOErr)])
	## Native for the same reason: `std::env::vars()` panics on a non-Unicode
	## value, which aborted `Env.dict!()` — the one function whose doc promises
	## "native non-Unicode values are preserved".
	env! : {} => List({ name : OsStr, value : OsStr })
	## `OsStr` and a failure, for the same reason as `var!`. These were `Str`,
	## built lossily, and `""` when the OS call failed: a non-UTF-8 directory
	## came back with U+FFFD where its bytes were, and a deleted cwd came back
	## as `""`, which a caller joining paths onto it turned into the root.
	cwd! : {} => Try(OsStr, [Io(IOErr)])
	exe_path! : {} => Try(OsStr, [Io(IOErr)])
	## No failure: it reads `TMPDIR`, falling back to the platform default.
	temp_dir! : {} => OsStr
	platform! : {} => { arch : [X86, X64, ARM, AARCH64, OTHER(Str)], os : [LINUX, MACOS, WINDOWS, OTHER(Str)] }
}
