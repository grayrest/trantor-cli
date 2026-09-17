app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Path exposing [Path]
import pf.File
import pf.Fs
import pf.Streams

## One word per case, joined, so the script compares a single line.
outcome : Try(Str, _) -> Str
outcome = |r| match r {
	Ok(s) => s
	Err(e) => "err:${Str.inspect(e)}"
}

## The raw layer takes absolute bytes against the first preopen.
abs! : Str => List(U8)
abs! = |name| {
	cwd = Env.cwd!() ?? Path.utf8(".")
	Str.to_utf8("${Path.display(cwd)}/${name}")
}

root! : () => Fs.Descriptor
root! = || match List.first(Fs.preopens!({})) {
	Ok(d) => d
	Err(_) => crash("no preopen")
}

## append_utf8! creates, then appends; write_utf8! truncates.
append_and_truncate! : () => Try(Str, _)
append_and_truncate! = || {
	p = Path.utf8("append.txt")
	p.append_utf8!("a")?
	p.append_bytes!(['b'])?
	appended = p.read_utf8!()?
	p.write_utf8!("c")?
	Ok("${appended}${p.read_utf8!()?}")
}

## A writer's bytes are in the file before the writer is dropped (unbuffered),
## and open_writer! truncates what was there.
writer_unbuffered! : () => Try(Str, _)
writer_unbuffered! = || {
	p = Path.utf8("writer.txt")
	p.write_utf8!("old contents")?
	w = File.open_writer!(p)?
	w.write_utf8!("x")?
	w.line!("y")?
	seen = p.read_utf8!()?
	w.write!(['z'])?
	Ok(Str.replace_each("${seen}/${p.read_utf8!()?}", "\n", "_"))
}

## Two append writers on one file interleave; nothing is overwritten.
two_appenders! : () => Try(Str, _)
two_appenders! = || {
	p = Path.utf8("log.txt")
	a = File.open_append!(p)?
	b = File.open_append!(p)?
	a.write_utf8!("1")?
	b.write_utf8!("2")?
	a.write_utf8!("3")?
	b.write_utf8!("4")?
	p.read_utf8!()
}

## write_via_stream! writes from its offset without truncating.
offset_write! : () => Try(Str, _)
offset_write! = || {
	p = Path.utf8("offset.txt")
	p.write_utf8!("hello")?
	d = Fs.open_at!(root!(), abs!("offset.txt"), { read: False, write: True }).map_err(|Io(e)| Raw(e))?
	s = Fs.write_via_stream!(d, 1).map_err(|Io(e)| Raw(e))?
	Streams.write!(s, Str.to_utf8("EL")).map_err(|Io(e)| Raw(e))?
	p.read_utf8!()
}

## exclusive refuses an existing file and creates a missing one.
exclusive! : () => Str
exclusive! = || {
	existing = match Fs.open_at!(root!(), abs!("offset.txt"), { write: True, exclusive: True }) {
		Ok(_) => "opened"
		Err(Io(AlreadyExists)) => "exists"
		Err(Io(e)) => "err:${Str.inspect(e)}"
	}
	fresh = match Fs.open_at!(root!(), abs!("fresh.txt"), { write: True, exclusive: True }) {
		Ok(_) => "created"
		Err(Io(e)) => "err:${Str.inspect(e)}"
	}
	"${existing},${fresh}"
}

## follow_symlinks: False refuses a final symlink; the default follows it.
nofollow! : () => Str
nofollow! = || {
	followed = match Fs.open_at!(root!(), abs!("link.txt"), {}) {
		Ok(_) => "followed"
		Err(_) => "refused"
	}
	not_followed = match Fs.open_at!(root!(), abs!("link.txt"), { follow_symlinks: False }) {
		Ok(_) => "followed"
		Err(_) => "refused"
	}
	"${followed},${not_followed}"
}

## A directory descriptor is a base for the *_at! operations; a file is not a directory.
directory! : () => Str
directory! = || {
	dir = match Fs.open_at!(root!(), abs!("sub"), { directory: True }) {
		Ok(d) => match Fs.read_file_at!(d, Str.to_utf8("inner.txt")) {
			Ok(bytes) => Str.from_utf8_lossy(bytes)
			Err(Io(e)) => "err:${Str.inspect(e)}"
		}
		Err(Io(e)) => "err:${Str.inspect(e)}"
	}
	file = match Fs.open_at!(root!(), abs!("offset.txt"), { directory: True }) {
		Ok(_) => "opened"
		Err(Io(NotADirectory)) => "notdir"
		Err(Io(e)) => "err:${Str.inspect(e)}"
	}
	rejected = match Fs.open_at!(root!(), abs!("sub"), { directory: True, write: True }) {
		Ok(_) => "opened"
		Err(Io(Unsupported)) => "unsupported"
		Err(Io(e)) => "err:${Str.inspect(e)}"
	}
	"${Str.trim(dir)},${file},${rejected}"
}

## Entries come sorted, each with its own kind: a link is a link.
entries! : () => Str
entries! = || match Fs.read_dir_at!(root!(), abs!("sub")) {
	Ok(es) => Str.join_with(es.map(|e| "${Str.from_utf8_lossy(e.name)}:${Str.inspect(e.kind)}"), ",")
	Err(Io(e)) => "err:${Str.inspect(e)}"
}

## An append stream leaves the open file alone: a later offset stream on the
## same descriptor still writes where it says. A descriptor opened in append
## mode appends through any stream (D-S2-27).
append_modes! : () => Try(Str, _)
append_modes! = || {
	Path.write_utf8!(Path.utf8("modes.txt"), "hello")?
	plain = Fs.open_at!(root!(), abs!("modes.txt"), { write: True }).map_err(|Io(e)| Raw(e))?
	Streams.write!(Fs.append_via_stream!(plain).map_err(|Io(e)| Raw(e))?, Str.to_utf8("!")).map_err(|Io(e)| Raw(e))?
	Streams.write!(Fs.write_via_stream!(plain, 0).map_err(|Io(e)| Raw(e))?, Str.to_utf8("XY")).map_err(|Io(e)| Raw(e))?
	after_plain = Path.read_utf8!(Path.utf8("modes.txt"))?
	appending = Fs.open_at!(root!(), abs!("modes.txt"), { append: True }).map_err(|Io(e)| Raw(e))?
	Streams.write!(Fs.write_via_stream!(appending, 0).map_err(|Io(e)| Raw(e))?, Str.to_utf8("?")).map_err(|Io(e)| Raw(e))?
	Ok("${after_plain},${Path.read_utf8!(Path.utf8("modes.txt"))?}")
}

## An append through a FIFO opened without `append`: no seek, and the bytes
## arrive (the seek failed before).
fifo_append! : () => Try(Str, _)
fifo_append! = || {
	d = Fs.open_at!(root!(), abs!("fifo2"), { read: False, write: True }).map_err(|Io(e)| Raw(e))?
	Streams.write!(Fs.append_via_stream!(d).map_err(|Io(e)| Raw(e))?, Str.to_utf8("appended")).map_err(|Io(e)| Raw(e))?
	Ok("fifo-append-ok")
}

## A writer on a FIFO: nothing to seek, and the offset is ignored (D-S2-23).
fifo! : () => Try(Str, _)
fifo! = || {
	w = File.open_writer!(Path.utf8("fifo"))?
	w.write_utf8!("through-fifo")?
	Ok("fifo-ok")
}

## Same directory through a link when followed, the link itself when not, and
## a different directory otherwise (D-S2-25).
identity! : () => Str
identity! = || {
	match (hash!("sub", True), hash!("sublink", True), hash!("sublink", False), hash!("sub/deeper", True)) {
		(Ok(dir), Ok(through), Ok(link), Ok(other)) =>
			"${Str.inspect(dir == through)},${Str.inspect(dir == link)},${Str.inspect(dir == other)}"
		_ => "hash-failed"
	}
}

hash! : Str, Bool => Try({ lower : U64, upper : U64 }, [Failed])
hash! = |name, follow| match Fs.metadata_hash_at!(root!(), abs!(name), { follow_symlinks: follow }) {
	Ok(h) => Ok(h)
	Err(_) => Err(Failed)
}

## A writer needs no read permission.
write_only! : () => Try(Str, _)
write_only! = || {
	w = File.open_append!(Path.utf8("writeonly.txt"))?
	w.write_utf8!("w")?
	Ok("wrote")
}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	cases = [
		outcome(append_and_truncate!()),
		outcome(writer_unbuffered!()),
		outcome(two_appenders!()),
		outcome(offset_write!()),
		exclusive!(),
		nofollow!(),
		directory!(),
		outcome(write_only!()),
		entries!(),
		outcome(fifo!()),
		identity!(),
		outcome(append_modes!()),
		outcome(fifo_append!()),
	]
	Stdout.line!(Str.join_with(cases, " "))
}
