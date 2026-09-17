import IOErr exposing [IOErr]
import Streams
## roc:filesystem primitives: WASI's capability model. Every op is relative to a
## Descriptor (a preopened directory or an opened file); there is no ambient
## path authority at this layer (P4). Paths are raw bytes (P11).
Fs :: [].{
	Descriptor :: Box(U64)
	## The preopened directories, as wasi:filesystem/preopens hands them over.
	## Was count+at, whose count nothing ever read and whose index was always 0.
	preopens! : {} => List(Descriptor)
	## WASI's open flags, every one stated. The hosted leaf takes this record
	## because optional fields cannot cross the host boundary; apps call
	## `open_at!`, which fills the defaults and rejects contradictions first.
	OpenFlags : { read : Bool, write : Bool, create : Bool, exclusive : Bool, truncate : Bool, append : Bool, directory : Bool, follow_symlinks : Bool, mode : U32 }
	## The hosted open, for callers that already hold a complete `OpenFlags`.
	## It does not validate: `open_at!` is the door.
	open_with_flags_at! : Descriptor, List(U8), OpenFlags => Try(Descriptor, [Io(IOErr)])
	## Open `path` relative to a descriptor. `read` and `follow_symlinks`
	## default to `True` and the rest to `False`, so `{}` opens an existing file
	## read-only. `exclusive` implies `create`; `append` implies `write` and puts
	## every write through the descriptor at the end of the file, atomically
	## against other appenders (D-S2-27). `create`, `exclusive` or
	## `truncate` without `write`, neither `read` nor `write`, `directory`
	## with `write`, `create` or `truncate`, and `append` with `truncate` or
	## `directory`, are `Unsupported` on every OS,
	## before the host is asked. `directory: True` yields a directory
	## descriptor for the `*_at!` operations; it names the directory by path, so
	## `follow_symlinks: False` holds for the open only, and a later operation
	## through it resolves the path again.
	##
	## `mode` is the Unix permission bits a `create` uses, `0o666` by default
	## and masked by the umask as `open(2)` does; it is ignored without
	## `create` and on Windows.
	open_at! : Descriptor, List(U8), { read ?: Bool, write ?: Bool, create ?: Bool, exclusive ?: Bool, truncate ?: Bool, append ?: Bool, directory ?: Bool, follow_symlinks ?: Bool, mode ?: U32 } => Try(Descriptor, [Io(IOErr)])
	open_at! = |dir, path, opts| {
		flags = Fs.open_flags(opts)?
		Fs.open_with_flags_at!(dir, path, flags)
	}
	## Defaults and validation for `open_at!`, pure so it is testable.
	open_flags : { read ?: Bool, write ?: Bool, create ?: Bool, exclusive ?: Bool, truncate ?: Bool, append ?: Bool, directory ?: Bool, follow_symlinks ?: Bool, mode ?: U32 } -> Try(OpenFlags, [Io(IOErr)])
	open_flags = |o| {
		exclusive = o.?exclusive ?? False
		append = o.?append ?? False
		flags = {
			read: o.?read ?? True,
			write: append or (o.?write ?? False),
			create: exclusive or (o.?create ?? False),
			exclusive,
			truncate: o.?truncate ?? False,
			append,
			directory: o.?directory ?? False,
			follow_symlinks: o.?follow_symlinks ?? True,
			mode: o.?mode ?? Fs.default_file_mode,
		}
		# Every OS refuses these (EINVAL); saying so here gives them one name.
		changes_without_write = (flags.truncate or flags.create) and !flags.write
		neither_read_nor_write = !flags.directory and !flags.read and !flags.write
		directory_with_write = flags.directory and (flags.write or flags.create or flags.truncate)
		append_contradicted = flags.append and (flags.truncate or flags.directory)
		if changes_without_write or neither_read_nor_write or directory_with_write or append_contradicted { Err(Io(Unsupported)) } else { Ok(flags) }
	}
	## A stream reading the descriptor's open file from its cursor. `Io` when
	## the descriptor cannot be duplicated for the stream to own (no fds left),
	## as WASI's `read-via-stream` answers, and `IsADirectory` for a descriptor
	## opened with `directory: True`: the failure used to reach the caller as
	## the first read's. A directory opened without that flag is a file
	## descriptor to the OS, and reading it fails at the read, as it does for
	## `File::open` on Unix.
	read_via_stream! : Descriptor => Try(Streams.InputStream, [Io(IOErr)])
	## A stream writing from `offset`. Every stream on a descriptor, and any
	## child handed it, shares the open file's one cursor (D-S2-23): `offset`
	## sets it when the stream is made, writes move it, and a read stream on the
	## same descriptor reads ahead into a buffer and moves it too. To read and
	## write a file independently, open it twice. A pipe or terminal has no
	## cursor, and `offset` is ignored. Unbuffered: each
	## `Streams.write!` is written before it returns, so its error is that
	## write's error (D-S2-4).
	write_via_stream! : Descriptor, U64 => Try(Streams.OutputStream, [Io(IOErr)])
	## A stream whose every write lands at the end of the file. On a descriptor
	## opened with `append: True` that is atomic against other appenders; on
	## any other, each write first moves the shared cursor to the end, which
	## another process appending can race, and `FdHandoff` refuses the stream
	## (`NotAFile`), since a child given its fd would write at the cursor, not
	## the end (D-S2-31). It never changes the open file (D-S2-27).
	append_via_stream! : Descriptor => Try(Streams.OutputStream, [Io(IOErr)])
	read_file_at! : Descriptor, List(U8) => Try(List(U8), [Io(IOErr)])
	write_file_at! : Descriptor, List(U8), List(U8) => Try({}, [Io(IOErr)])
	## A path's metadata. With `follow_symlinks: False` a link reports as a link
	## (`SymLink`, its own bits), except a name ending in `/` or `/.`, which the
	## OS follows; with `True` it reports what the link leads to, as WASI's
	## `stat-at` path flags do.
	stat_at! : Descriptor, List(U8), { follow_symlinks : Bool } => Try({ kind : [File, Dir, SymLink, Other], size : U64, accessed_ns : U128, modified_ns : U128, created_ns : U128, readable : Bool, writable : Bool, executable : Bool }, [Io(IOErr)])
	## WASI's `metadata-hash-at`: equal for two paths exactly when they name the
	## same file or directory, for telling a revisited directory from a new
	## one. Stable for the life of the process; not a device or inode number.
	metadata_hash_at! : Descriptor, List(U8), { follow_symlinks : Bool } => Try({ lower : U64, upper : U64 }, [Io(IOErr)])
	## A directory's entries, sorted by name, each with its kind as the entry
	## itself is (a symlink is `SymLink`, not what it points to): WASI's
	## `directory-entry`, so a walk needs one call per directory.
	read_dir_at! : Descriptor, List(U8) => Try(List({ name : List(U8), kind : [File, Dir, SymLink, Other] }), [Io(IOErr)])
	## `mode` is masked by the umask, as `mkdir(2)` does, and ignored on
	## Windows. `0o777` is the default every other caller passes.
	create_dir_at! : Descriptor, List(U8), U32 => Try({}, [Io(IOErr)])
	create_dir_all_at! : Descriptor, List(U8) => Try({}, [Io(IOErr)])
	## A name whose last component is `..` is `Unsupported`: `rmdir(2)` refuses
	## it, and a recursive removal spelled that way removed the parent on one
	## backend and nothing on the other.
	remove_dir_at! : Descriptor, List(U8) => Try({}, [Io(IOErr)])
	remove_dir_all_at! : Descriptor, List(U8) => Try({}, [Io(IOErr)])
	unlink_at! : Descriptor, List(U8) => Try({}, [Io(IOErr)])
	rename_at! : Descriptor, List(U8), List(U8) => Try({}, [Io(IOErr)])
	link_at! : Descriptor, List(U8), List(U8) => Try({}, [Io(IOErr)])
	## Copy one regular file's contents and permission bits, following a
	## symlink source. A directory source is `IsADirectory`; a FIFO, socket or
	## device is `Other`. An existing destination is `AlreadyExists`: delete it
	## first to replace it. Timestamps, extended attributes and the setuid,
	## setgid and sticky bits are not copied; both backends behave alike
	## (D-S2-36).
	copy_file_at! : Descriptor, List(U8), Descriptor, List(U8) => Try({}, [Io(IOErr)])
	## Create a directory at the destination with the source directory's
	## permission bits, not its contents: the directory twin of
	## `copy_file_at!`, for a tree copy. The owner always gets read, write and
	## search, so the copy can be filled; the setuid, setgid and sticky bits
	## are dropped, and the umask does not apply. A source that is not a
	## directory is `NotADirectory`, and so is a link, unless named `link/` or
	## `link/.` (as `stat_at!` reads it). Anything at the destination, a link
	## included, is `AlreadyExists`.
	copy_dir_at! : Descriptor, List(U8), Descriptor, List(U8) => Try({}, [Io(IOErr)])
	## A symlink's contents, unresolved.
	readlink_at! : Descriptor, List(U8) => Try(List(U8), [Io(IOErr)])
	## Create a symlink at `link` (the third argument) whose contents are
	## `target` (the second), stored as given. Under a confined root the target
	## must already exist inside the root, resolved from the link's directory:
	## an absolute, escaping or dangling target is refused, so a confined app
	## cannot leave links for unconfined programs to follow outside it.
	symlink_at! : Descriptor, List(U8), List(U8) => Try({}, [Io(IOErr)])

	## What `open(2)` is given when a caller names no mode.
	default_file_mode : U32
	default_file_mode = 0o666
	## What `mkdir(2)` is given when a caller names no mode.
	default_dir_mode : U32
	default_dir_mode = 0o777
}

## The flags defaults and validation settled on, with the refusal made
## comparable: `IOErr` has no equality.
settled : { read ?: Bool, write ?: Bool, create ?: Bool, exclusive ?: Bool, truncate ?: Bool, append ?: Bool, directory ?: Bool, follow_symlinks ?: Bool, mode ?: U32 } -> Try(Fs.OpenFlags, [Unsupported, Refused])
settled = |o| match Fs.open_flags(o) {
	Ok(f) => Ok(f)
	Err(Io(Unsupported)) => Err(Unsupported)
	Err(_) => Err(Refused)
}

expect settled({}) == Ok({ read: True, write: False, create: False, exclusive: False, truncate: False, directory: False, follow_symlinks: True, append: False, mode: 0o666 })
expect settled({ write: True, create: True, truncate: True }) == Ok({ read: True, write: True, create: True, exclusive: False, truncate: True, directory: False, follow_symlinks: True, append: False, mode: 0o666 })
# a named mode is carried through; the host masks it with the umask
expect settled({ write: True, create: True, mode: 0o600 }).map_ok(|f| f.mode) == Ok(0o600)
# exclusive implies create
expect settled({ write: True, exclusive: True }).map_ok(|f| f.create) == Ok(True)
# create, exclusive or truncate without write; neither read nor write
expect settled({ create: True }) == Err(Unsupported)
# append implies write, and contradicts truncate and directory
expect settled({ append: True, create: True }).map_ok(|f| (f.append, f.write)) == Ok((True, True))
expect settled({ append: True, truncate: True }) == Err(Unsupported)
expect settled({ append: True, directory: True }) == Err(Unsupported)
expect settled({ exclusive: True }) == Err(Unsupported)
expect settled({ read: False }) == Err(Unsupported)
expect settled({ read: False, write: True }).map_ok(|f| f.write) == Ok(True)
expect settled({ follow_symlinks: False }).map_ok(|f| f.follow_symlinks) == Ok(False)
expect settled({ directory: True }).map_ok(|f| f.directory) == Ok(True)
# truncate without write
expect settled({ truncate: True }) == Err(Unsupported)
# directory with anything that writes
expect settled({ directory: True, write: True }) == Err(Unsupported)
expect settled({ directory: True, create: True }) == Err(Unsupported)
expect settled({ directory: True, exclusive: True }) == Err(Unsupported)
expect settled({ directory: True, truncate: True, write: True }) == Err(Unsupported)
