app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr
import pf.Stdout
import pf.Path

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	out_file : Path
	out_file = "out.txt"
	Stdout.line!("Writing a string to out.txt")?
	out_file.write_utf8!("a string!")?
	contents = out_file.read_utf8!()?
	out_file.delete!()?
	Stdout.line!("I read the file back. Its contents are: \"${contents}\"")?
	Ok({})
}
