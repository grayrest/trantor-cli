app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Stdin
import pf.Cli
import pf.Streams

line! : Streams.InputStream => Str
line! = |stream| match Streams.read_until!(stream, '\n', 100) {
	Ok(bytes) => Str.trim(Str.from_utf8_lossy(bytes))
	Err(_) => "err"
}

## Two stdin streams held at once, and `Stdin.line!` between them, all read
## from the one process-wide buffer in order.
## One line, then end of input — through a stream, on a terminal: `fill_buf`
## used to read twice, so the second read waited for a second Ctrl-D.
eof! : () => Try({}, _)
eof! = || {
	stream = Cli.get_stdin!({})
	one = line!(stream)
	two = match Streams.read_until!(stream, '\n', 100) {
		Ok([]) => "EOF"
		Ok(bytes) => Str.trim(Str.from_utf8_lossy(bytes))
		Err(_) => "err"
	}
	Stdout.line!("1=${one} 2=${two}")
}

## The same error from the same fd, through both doors.
kinds! : () => Try({}, _)
kinds! = || {
	stream = match Streams.read_until!(Cli.get_stdin!({}), '\n', 100) {
		Ok(_) => "ok"
		Err(Io(e)) => "err:${Str.inspect(e)}"
	}
	line = match Stdin.line!() {
		Ok(_) => "ok"
		Err(StdinErr(e)) => "err:${Str.inspect(e)}"
		Err(_) => "eof"
	}
	Stdout.line!("${stream} ${line}")
}

main! : List(OsStr) => Try({}, _)
main! = |args| if List.len(args) > 2 { kinds!() } else if List.len(args) > 1 { eof!() } else {
	first = Cli.get_stdin!({})
	one = line!(first)
	second = Cli.get_stdin!({})
	two = line!(second)
	three = Stdin.line!() ?? "err"
	four = line!(first)
	five = match Streams.read!(second, 100) {
		Ok(bytes) => Str.trim(Str.from_utf8_lossy(bytes))
		Err(_) => "err"
	}
	Stdout.line!("${one} ${two} ${three} ${four} ${five}")
}
