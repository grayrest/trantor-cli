## roc:cli/exit — ending the process with a status, shaped after wasi:cli/exit.
##
## Exit is an EFFECT, not a return value. `main!` used to report it by handing
## back `Err(Exit(code))`, which meant every app's error type had to carry an
## `Exit` variant whether or not the app ever used one, and an app that just
## wanted to fail had to name a tag about process lifetime.
##
## It is its own interface rather than a leaf on CliEnv because ending the
## process is its own authority: a world can decline to wire it.
CliExit :: [].{
	## Does not return.
	exit! : I32 => {}
}
