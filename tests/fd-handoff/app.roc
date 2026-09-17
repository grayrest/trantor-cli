app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Path exposing [Path]
import pf.File
import pf.Fs
import pf.Cli
import pf.FdHandoff
import pf.IOErr exposing [IOErr]

## What `/dev/fd/N` reads as: a dup of fd N, so the file behind the number.
through! : I32 => Str
through! = |fd| match Path.read_utf8!(Path.utf8("/dev/fd/${fd.to_str()}")) {
	Ok(s) => Str.trim(s)
	Err(_) => "unreadable"
}

answer : Try(I32, [NotAFile, Io(IOErr)]) -> Str
answer = |r| match r {
	Ok(n) => if n > 2 { "fd" } else { "stdio-number:${n.to_str()}" }
	Err(NotAFile) => "notafile"
	Err(Io(_)) => "io"
}

abs! : Str => List(U8)
abs! = |name| {
	cwd = Env.cwd!() ?? Path.utf8(".")
	Str.to_utf8("${Path.display(cwd)}/${name}")
}

## Opens `handed.txt` until the process has no descriptors left, keeping every
## one alive, then asks for a duplicate of stdout.
exhausted! : List(Fs.Descriptor) => Str
exhausted! = |held| match Fs.open_at!(Fs.preopens!({}).first() ?? crash("no preopen"), abs!("handed.txt"), {}) {
	Ok(d) => if held.len() > 100000 { "never-ran-out" } else { exhausted!(held.append(d)) }
	Err(_) => answer(FdHandoff.output_fd!(Cli.get_stdout!({})))
}

## Opens readers until one is refused, reading from each as it is made. A
## reader answers its failure at the open: the stream owns a duplicate of the
## descriptor, so making it can fail too, and that used to reach the caller as
## the first read's error instead.
readers! : List(File.Reader) => Str
readers! = |held| match File.open_reader!(Path.utf8("handed.txt")) {
	Ok(reader) =>
		match reader.read_line!() {
			Ok(_) => if held.len() > 100000 { "never-ran-out" } else { readers!(held.append(reader)) }
			Err(_) => "READ-FAILED-AFTER-OPEN-OK"
		}
	Err(_) => "open-refused"
}

main! : List(OsStr) => Try({}, _)
main! = |args| if args.len() > 2 { Stdout.line!(readers!([])) } else if args.len() > 1 { Stdout.line!(exhausted!([])) } else {
	# First, before any file is open: run with stdin closed, fd 0 is free here,
	# and a duplicate could land on it.
	stdout_fd = answer(FdHandoff.output_fd!(Cli.get_stdout!({})))
	reader = File.open_reader!(Path.utf8("handed.txt"))?
	reader_fd = FdHandoff.descriptor_fd!(reader.descriptor())
	read_back = match reader_fd {
		Ok(fd) => through!(fd)
		Err(_) => "notafile"
	}
	writer = File.open_writer!(Path.utf8("written.txt"))?
	writer_fd = answer(FdHandoff.descriptor_fd!(writer.descriptor()))
	dir = match Fs.open_at!(Fs.preopens!({}).first() ?? crash("no preopen"), abs!("sub"), { directory: True }) {
		Ok(d) => answer(FdHandoff.descriptor_fd!(d))
		Err(_) => "open-failed"
	}
	closed = match reader_fd {
		Ok(fd) => {
			FdHandoff.close_fd!(fd)
			through!(fd)
		}
		Err(_) => "notafile"
	}
	Stdout.line!("${read_back} ${writer_fd} ${stdout_fd} ${dir} ${closed}")
}
