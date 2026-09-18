app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.File
import pf.Path
import pf.Env

read_all! : Str => Try(Str, _)
read_all! = |name| {
	r = File.open_reader!(Path.utf8(name)) ? |_| OpenFailed
	loop!(r, 0)
}

loop! : File.Reader, U64 => Try(Str, _)
loop! = |r, n|
	match r.read_line!() {
		Ok([]) => Ok("eof${Str.inspect(n)}")
		Ok(_) => loop!(r, n + 1)
		Err(LineTooLong) => Ok("toolong")
		Err(FileErr(_)) => Ok("fileerr")
	}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	short = read_all!("ok.txt")?
	long = read_all!("long.txt")?
	set = match Env.var!(OsStr.utf8("BADVAR")) {
		Ok(v) => match OsStr.to_raw(v) {
			UnixBytes(_) => "bytes"
			Utf8(_) => "utf8"
			WindowsU16s(_) => "u16s"
		}
		Err(VarNotFound(_)) => "notfound"
		Err(_) => "other"
	}
	unset = match Env.var!(OsStr.utf8("DEFINITELY_UNSET_XYZ")) {
		Ok(_) => "found"
		Err(VarNotFound(_)) => "notfound"
		Err(_) => "other"
	}
	# A line of exactly the 1 MiB cap is a line, with or without its newline;
	# one byte more without a newline is too long.
	exact = read_all!("exact.txt")?
	exact_nl = read_all!("exact-nl.txt")?
	over = read_all!("over.txt")?
	# A name the environment cannot hold is refused, not looked up: `KEYX=B`
	# read KEYX, whose value begins `B=`.
	keys = [key!(OsStr.utf8("KEYX=B")), key!(OsStr.utf8("")), key!(OsStr.unix_bytes([75, 0, 66]))]
	Stdout.line!("${short} ${long} ${set} ${unset} ${exact} ${exact_nl} ${over} ${Str.join_with(keys, " ")}")
}

key! : OsStr => Str
key! = |name| match Env.var!(name) {
	Ok(_) => "found"
	Err(VarNotFound(_)) => "notfound"
	Err(EnvErr(Other(message))) => if Str.contains(message, "cannot be empty or contain nul bytes or '='") { "invalid" } else { "other" }
	Err(_) => "other"
}
