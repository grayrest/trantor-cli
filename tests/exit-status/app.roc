app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Cli

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# One argument beyond the binary means "exit 7"; none means fall off the end.
	if List.len(Cli.args!({})) > 1 { Cli.exit!(7) } else { {} }
	Ok({})
}
