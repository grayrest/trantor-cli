app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Path

kind! : Str => Str
kind! = |p| {
	path : Path
	path = Path.utf8(p)
	match Path.read_utf8!(path) {
		Ok(_) => "Ok"
		Err(PathErr(e)) => Str.inspect(e)
	}
}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	dir = kind!("/tmp")
	notdir = kind!("/etc/hosts/nope")
	missing = kind!("/no/such/file/at/all")
	Stdout.line!("${dir},${notdir},${missing}")
}
