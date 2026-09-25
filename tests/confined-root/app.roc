app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Path

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	here = match Path.list!(Path.utf8(".")) {
		Ok(_) => "listed"
		Err(PathErr(e)) => Str.inspect(e)
	}
	Stdout.line!(here)
}
