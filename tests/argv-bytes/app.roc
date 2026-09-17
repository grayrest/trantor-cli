app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout

main! : List(OsStr) => Try({}, _)
main! = |args| {
	tags = List.map(List.drop_first(args, 1), |a| match OsStr.to_raw(a) {
		Utf8(_) => "Utf8"
		UnixBytes(_) => "UnixBytes"
		WindowsU16s(_) => "WindowsU16s"
	})
	Stdout.line!(Str.join_with(tags, ","))
}
