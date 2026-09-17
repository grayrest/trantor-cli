import IOErr exposing [IOErr]
import Fs
import Cwd
import CliEnv
import Streams
## The List(U8) core beneath basic-cli's `Path` and `File` (through `Host`). Paths
## resolve against the userland cwd (a Cwd prefix; empty = the process cwd),
## then run against preopen 0 -- basic-cli's ambient authority re-expressed as
## a capability the world granted (P4/P8).
FsOps :: [].{
	cwd! : {} => Str
	cwd! = |{}| {
		c = Cwd.get!({})
		if Str.is_empty(c) { CliEnv.cwd!({}) } else { c }
	}
	## Stores an ABSOLUTE path, and refuses one that is not a directory.
	##
	## Two defects, one line. It stored whatever it was handed, so a RELATIVE
	## path was later joined onto `root!()` — preopen 0, which is `/` — while
	## the subprocess layer passed the same string to `Command::current_dir`,
	## where the OS resolved it against the PROCESS cwd. One `set_cwd!("sub")`
	## call, two different directories, and the file-op side was the dangerous
	## one: a relative path from user input became root-absolute. Resolving it
	## here, once, makes both sides read the same slot.
	##
	## It was also infallible — any string accepted, `Env.cwd!` echoing it back,
	## and every later path failing with a misleading `NotFound` somewhere else.
	## `Env.set_cwd!` has always documented `Err(InvalidCwd(err))` "when the path
	## cannot be used as a working directory"; now it can happen.
	set_cwd! : Str => Try({}, IOErr)
	## A link to a directory is a working directory, as it is to `cd` and to
	## `std::env::set_current_dir`, so the kind is read following links — this
	## is a directory check, not a report of what the name is (D-S2-47).
	set_cwd! = |p| {
		abs = Str.from_utf8_lossy(resolve!(Str.to_utf8(p)))
		match followed_kind!(Str.to_utf8(abs)) {
			Ok(Dir) => {
				Cwd.set!(abs)
				Ok({})
			}
			Ok(_) => Err(NotADirectory)
			Err(e) => Err(e)
		}
	}

	## The first preopen, which is this layer's ambient root. Was
	## `root!()` repeated at every call site below.
	root! : () => Fs.Descriptor
	root! = || match List.first(Fs.preopens!({})) {
		Ok(d) => d
		Err(_) => crash("roc:cli filesystem: the host published no preopened directory")
	}

	resolve! : List(U8) => List(U8)
	resolve! = |p| if is_absolute(p) { p } else { join_bytes(Str.to_utf8(cwd!({})), p) }

	read! : List(U8) => Try(List(U8), [FileErr(IOErr)])
	read! = |p| as_file(Fs.read_file_at!(root!(), resolve!(p)))
	write! : List(U8), List(U8) => Try({}, [FileErr(IOErr)])
	write! = |p, b| as_file(Fs.write_file_at!(root!(), resolve!(p), b))
	delete! : List(U8) => Try({}, [FileErr(IOErr)])
	delete! = |p| as_file(Fs.unlink_at!(root!(), resolve!(p)))
	## The kind of what a path leads to, for a caller asking "is this a
	## directory" rather than "what is this name".
	followed_kind! : List(U8) => Try([File, Dir, SymLink, Other], IOErr)
	followed_kind! = |p| {
		match Fs.stat_at!(root!(), resolve!(p), { follow_symlinks: True }) {
			Ok(s) => Ok(s.kind)
			Err(Io(e)) => Err(e)
		}
	}
	kind! : List(U8) => Try([File, Dir, SymLink, Other], IOErr)
	kind! = |p| {
		match Fs.stat_at!(root!(), resolve!(p), { follow_symlinks: False }) {
			Ok(s) => Ok(s.kind)
			Err(Io(e)) => Err(e)
		}
	}
	size! : List(U8) => Try(U64, IOErr)
	size! = |p| {
		match Fs.stat_at!(root!(), resolve!(p), { follow_symlinks: True }) {
			Ok(s) => Ok(s.size)
			Err(Io(e)) => Err(e)
		}
	}
	## Whether what the path leads to has an executable bit, following links as
	## `exec` does: a link's own bits said a dangling link in PATH was runnable.
	executable! : List(U8) => Try(Bool, IOErr)
	executable! = |p| {
		match Fs.stat_at!(root!(), resolve!(p), { follow_symlinks: True }) {
			Ok(s) => Ok(s.executable)
			Err(Io(e)) => Err(e)
		}
	}
	Entry : { name : List(U8), kind : [File, Dir, SymLink, Other] }
	## Entry names with their kinds, sorted by name.
	entries! : List(U8) => Try(List(Entry), [DirErr(IOErr)])
	entries! = |p| as_dir(Fs.read_dir_at!(root!(), resolve!(p)))
	list! : List(U8) => Try(List(List(U8)), [DirErr(IOErr)])
	list! = |p| Ok(entries!(p)?.map(|e| e.name))
	create_dir! : List(U8) => Try({}, [DirErr(IOErr)])
	create_dir! = |p| FsOps.create_dir_mode!(p, Fs.default_dir_mode)
	## A directory with the permission bits named, masked by the umask.
	create_dir_mode! : List(U8), U32 => Try({}, [DirErr(IOErr)])
	create_dir_mode! = |p, mode| as_dir(Fs.create_dir_at!(root!(), resolve!(p), mode))
	create_all! : List(U8) => Try({}, [DirErr(IOErr)])
	create_all! = |p| as_dir(Fs.create_dir_all_at!(root!(), resolve!(p)))
	delete_empty! : List(U8) => Try({}, [DirErr(IOErr)])
	delete_empty! = |p| as_dir(Fs.remove_dir_at!(root!(), resolve!(p)))
	delete_all! : List(U8) => Try({}, [DirErr(IOErr)])
	delete_all! = |p| as_dir(Fs.remove_dir_all_at!(root!(), resolve!(p)))
	rename! : List(U8), List(U8) => Try({}, [FileErr(IOErr)])
	rename! = |a, b| as_file(Fs.rename_at!(root!(), resolve!(a), resolve!(b)))
	hard_link! : List(U8), List(U8) => Try({}, [FileErr(IOErr)])
	hard_link! = |a, b| as_file(Fs.link_at!(root!(), resolve!(a), resolve!(b)))
	## Copy a file's contents and permission bits; an existing destination is
	## `AlreadyExists`.
	copy! : List(U8), List(U8) => Try({}, [FileErr(IOErr)])
	copy! = |a, b| as_file(Fs.copy_file_at!(root!(), resolve!(a), root!(), resolve!(b)))
	## Create directory `b` with directory `a`'s permission bits (owner rwx
	## always); see `Fs.copy_dir_at!`.
	copy_dir! : List(U8), List(U8) => Try({}, [DirErr(IOErr)])
	copy_dir! = |a, b| as_dir(Fs.copy_dir_at!(root!(), resolve!(a), root!(), resolve!(b)))
	## A symlink at `link` holding `target` as given: the target is link
	## contents, so it is not resolved against the cwd.
	sym_link! : List(U8), List(U8) => Try({}, [FileErr(IOErr)])
	sym_link! = |target, link| as_file(Fs.symlink_at!(root!(), target, resolve!(link)))
	read_sym_link! : List(U8) => Try(List(U8), [FileErr(IOErr)])
	read_sym_link! = |p| as_file(Fs.readlink_at!(root!(), resolve!(p)))
	readable! : List(U8) => Try(Bool, IOErr)
	readable! = |p| stat_field!(p, |s| s.readable)
	writable! : List(U8) => Try(Bool, IOErr)
	writable! = |p| stat_field!(p, |s| s.writable)
	accessed! : List(U8) => Try(U128, IOErr)
	accessed! = |p| stat_field!(p, |s| s.accessed_ns)
	modified! : List(U8) => Try(U128, IOErr)
	modified! = |p| stat_field!(p, |s| s.modified_ns)
	created! : List(U8) => Try(U128, IOErr)
	created! = |p| stat_field!(p, |s| s.created_ns)
	## A write stream and the descriptor it was opened from. The descriptor is
	## kept so a child process can be handed the same open file (D-S2-21), at
	## the cost of a second OS descriptor per open writer or reader: the stream
	## owns a duplicate, so an app holding many open files reaches its limit at
	## half as many as the raw `Fs.open_at!` would.
	Writer : { descriptor : Fs.Descriptor, stream : Streams.OutputStream }
	## Create or truncate, then write from the start.
	open_writer! : List(U8) => Try(Writer, [FileErr(IOErr)])
	open_writer! = |p| as_file(writer_at!(resolve!(p), Truncate))
	## Create if missing, then write at the end.
	open_append! : List(U8) => Try(Writer, [FileErr(IOErr)])
	open_append! = |p| as_file(writer_at!(resolve!(p), Append))
	write_stream! : Writer, List(U8) => Try({}, [FileErr(IOErr)])
	write_stream! = |w, b| as_file(Streams.write!(w.stream, b))
	## Append bytes to a file, creating it if missing.
	append! : List(U8), List(U8) => Try({}, [FileErr(IOErr)])
	append! = |p, b| write_stream!(open_append!(p)?, b)
	## A buffered read stream and the descriptor it was opened from.
	Reader : { descriptor : Fs.Descriptor, stream : Streams.InputStream }
	## Open for buffered reading: a sync-io stream over the descriptor.
	open_read! : List(U8) => Try(Reader, [FileErr(IOErr)])
	open_read! = |p| {
		match Fs.open_at!(root!(), resolve!(p), {}) {
			Ok(descriptor) =>
				match Fs.read_via_stream!(descriptor) {
					Ok(stream) => Ok({ descriptor, stream })
					Err(Io(e)) => Err(FileErr(e))
				}
			Err(Io(e)) => Err(FileErr(e))
		}
	}
}

## Not readable: a writer does not need read permission, and asking for it
## would refuse a write-only file.
writer_at! : List(U8), [Truncate, Append] => Try(FsOps.Writer, [Io(IOErr)])
writer_at! = |abs, mode| {
	match mode {
		Truncate => {
			descriptor = Fs.open_at!(FsOps.root!(), abs, { read: False, write: True, create: True, truncate: True })?
			Ok({ descriptor, stream: Fs.write_via_stream!(descriptor, 0)? })
		}
		Append => {
			descriptor = Fs.open_at!(FsOps.root!(), abs, { read: False, write: True, create: True, append: True })?
			Ok({ descriptor, stream: Fs.append_via_stream!(descriptor)? })
		}
	}
}

is_absolute : List(U8) -> Bool
is_absolute = |p| {
	match List.first(p) {
		Ok(c) => c == '/'
		Err(_) => False
	}
}

join_bytes : List(U8), List(U8) -> List(U8)
join_bytes = |a, b| {
	match List.last(a) {
		Ok(c) => if c == '/' { List.concat(a, b) } else { List.concat(List.append(a, '/'), b) }
		Err(_) => b
	}
}

## The roc:cli filesystem answers every failure with one `Io(IOErr)`. These
## put back the names this layer's consumers already use, so the uniform hosted
## error stops at this boundary instead of rippling through the basic-cli shim.
as_file : Try(a, [Io(IOErr)]) -> Try(a, [FileErr(IOErr)])
as_file = |r| match r {
	Ok(v) => Ok(v)
	Err(Io(e)) => Err(FileErr(e))
}

as_dir : Try(a, [Io(IOErr)]) -> Try(a, [DirErr(IOErr)])
as_dir = |r| match r {
	Ok(v) => Ok(v)
	Err(Io(e)) => Err(DirErr(e))
}

## The fields basic-cli reads through `fs::metadata`, which follows a link:
## a link's own size is its target's name length, and its own mode bits say
## nothing about what it leads to (D-S2-40 amended). Only `kind!` reports the
## link itself.
stat_field! : List(U8), ({ kind : [File, Dir, SymLink, Other], size : U64, accessed_ns : U128, modified_ns : U128, created_ns : U128, readable : Bool, writable : Bool, executable : Bool } -> a) => Try(a, IOErr)
stat_field! = |p, pick| {
	match Fs.stat_at!(FsOps.root!(), FsOps.resolve!(p), { follow_symlinks: True }) {
		Ok(s) => Ok(pick(s))
		Err(Io(e)) => Err(e)
	}
}
