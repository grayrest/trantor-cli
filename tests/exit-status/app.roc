app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Cli

## No argument beyond the binary: fall off the end. One: `Cli.exit!(7)`. Two:
## return an error the app does not handle.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	count = List.len(Cli.args!({}))
	if count == 2 { Cli.exit!(7) } else { {} }
	if count > 2 { Err(Boom("unhandled")) } else { Ok({}) }
}
