app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Cli
import pf.Path

## `paths REL`: the process's own paths, each as the bytes it arrived with or
## the failure it reported, and what reading the relative path REL gives.
## Anything else: the tag each argument arrived with.
main! : List(OsStr) => Try({}, _)
main! = |args| match (List.get(args, 1), List.get(args, 2)) {
	(Ok(mode), Ok(relative)) if OsStr.display(mode) == "paths" => paths!(OsStr.display(relative))
	_ => {
		tags = List.map(List.drop_first(args, 1), tag)
		Stdout.line!(Str.join_with(tags, ","))
	}
}

tag : OsStr -> Str
tag = |a| match OsStr.to_raw(a) {
	Utf8(_) => "Utf8"
	UnixBytes(_) => "UnixBytes"
	WindowsU16s(_) => "WindowsU16s"
}

paths! : Str => Try({}, _)
paths! = |relative| {
	lines = [
		"env-cwd ${match Env.cwd!() {
			Ok(p) => Str.inspect(Path.to_os_str(p))
			Err(CwdUnavailable) => "CwdUnavailable"
		}}",
		"cli-cwd ${match Cli.cwd!({}) {
			Ok(os) => Str.inspect(os)
			Err(Io(e)) => "Io(${Str.inspect(e)})"
		}}",
		"env-temp ${Str.inspect(Path.to_os_str(Env.temp_dir!()))}",
		"cli-temp ${Str.inspect(Cli.temp_dir!({}))}",
		"env-exe ${match Env.exe_path!() {
			Ok(p) => Str.inspect(Path.to_os_str(p))
			Err(ExePathUnavailable) => "ExePathUnavailable"
		}}",
		"cli-exe ${match Cli.exe_path!({}) {
			Ok(os) => Str.inspect(os)
			Err(Io(e)) => "Io(${Str.inspect(e)})"
		}}",
		"relative-read ${match Path.read_bytes!(Path.utf8(relative)) {
			Ok(_) => "ok"
			Err(PathErr(e)) => "err:${Str.inspect(e)}"
			Err(_) => "err:other"
		}}",
	]
	Stdout.line!(Str.join_with(lines, "\n"))
}
