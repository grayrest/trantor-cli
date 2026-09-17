app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Path
import pf.File

## Every path op resolves against the userland cwd, relative or not, and a cwd
## that cannot be one is refused.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	Env.set_cwd!(Path.utf8("sub")) ? |_| RelativeCwdRefused
	marker = Path.read_utf8!(Path.utf8("marker.txt")) ?? "<none>"
	Path.write_utf8!(Path.utf8("written.txt"), "w")?
	Path.append_utf8!(Path.utf8("written.txt"), "a")?
	writer = File.open_writer!(Path.utf8("streamed.txt"))?
	writer.write_utf8!("s")?
	Path.copy!(Path.utf8("marker.txt"), Path.utf8("copied.txt"))?
	Path.sym_link!(Path.utf8("marker.txt"), Path.utf8("linked"))?
	Path.create_all!(Path.utf8("made/deep"))?
	target = Path.display(Path.read_sym_link!(Path.utf8("linked"))?)
	missing = match Env.set_cwd!(Path.utf8("/no/such/directory")) {
		Ok({}) => "accepted"
		Err(InvalidCwd(_)) => "refused"
	}
	file = match Env.set_cwd!(Path.utf8("/etc/hosts")) {
		Ok({}) => "accepted"
		Err(InvalidCwd(_)) => "refused"
	}
	Stdout.line!("${Str.trim(marker)} ${target} ${missing} ${file}")
}
