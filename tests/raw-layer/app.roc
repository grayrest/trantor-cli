app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.IOErr exposing [IOErr]
import pf.Cli
import pf.Streams
import pf.Clocks

main! : List(OsStr) => Try({}, [Io(IOErr), ..])
main! = |_args| {
	out = Cli.get_stdout!({})
	n = List.len(Cli.args!({}))
	Clocks.sleep_millis!(1)
	Streams.write!(out, Str.to_utf8("argc=${n.to_str()}\n"))?
	Ok({})
}
