app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Path exposing [Path]

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# "sub" as UTF-16 code units.
	p = Path.windows_u16s([115, 117, 98]).join("note.txt")
	written = match p.write_utf8!("kept") {
		Ok({}) => "written"
		Err(PathErr(Other(_))) => "refused"
		Err(PathErr(e)) => "err:${Str.inspect(e)}"
	}
	Stdout.line!("${p.display()} ${written}")
}
