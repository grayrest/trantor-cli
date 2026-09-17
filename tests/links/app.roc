app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Path exposing [Path]

outcome : Try(Str, _) -> Str
outcome = |r| match r {
	Ok(s) => s
	Err(e) => "err:${Str.inspect(e)}"
}

## A copy carries the executable bit and the bytes.
copy_keeps_mode! : () => Try(Str, _)
copy_keeps_mode! = || {
	Path.copy!(Path.utf8("tool.sh"), Path.utf8("tool-copy.sh"))?
	exec = Path.is_executable!(Path.utf8("tool-copy.sh"))?
	same = Path.read_bytes!(Path.utf8("tool.sh"))? == Path.read_bytes!(Path.utf8("tool-copy.sh"))?
	Ok("${Str.inspect(exec)},${Str.inspect(same)}")
}

## Copying onto an existing file is refused and leaves it alone.
copy_refuses_existing! : () => Str
copy_refuses_existing! = || {
	refused = match Path.copy!(Path.utf8("tool.sh"), Path.utf8("keep.txt")) {
		Ok({}) => "copied"
		Err(PathErr(AlreadyExists)) => "exists"
		Err(PathErr(e)) => "err:${Str.inspect(e)}"
	}
	kept = Str.trim(Path.read_utf8!(Path.utf8("keep.txt")) ?? "<unreadable>")
	"${refused},${kept}"
}

## A link stores its target unresolved, and reads follow it.
link_round_trip! : () => Try(Str, _)
link_round_trip! = || {
	Path.sym_link!(Path.utf8("keep.txt"), Path.utf8("keep-link"))?
	target = Path.display(Path.read_sym_link!(Path.utf8("keep-link"))?)
	through = Str.trim(Path.read_utf8!(Path.utf8("keep-link"))?)
	is_link = Path.is_sym_link!(Path.utf8("keep-link"))?
	Ok("${target},${through},${Str.inspect(is_link)}")
}

## A dangling link can be made and read back.
dangling! : () => Try(Str, _)
dangling! = || {
	Path.sym_link!(Path.utf8("../nowhere"), Path.utf8("dangling"))?
	Ok(Path.display(Path.read_sym_link!(Path.utf8("dangling"))?))
}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	cases = [
		outcome(copy_keeps_mode!()),
		copy_refuses_existing!(),
		outcome(link_round_trip!()),
		outcome(dangling!()),
	]
	Stdout.line!(Str.join_with(cases, " "))
}
