## The basic-cli `Host` surface, reconstructed in pure Roc over the WASI-shaped
## primitives (P4/D2). basic-cli's own Stdout.roc/Stderr.roc/Stdin.roc
## `import Host` and compile here UNCHANGED. Each stdout/stderr call mints the
## process stream resource and drops it after the write (drop-balanced by B0).
import IOErr exposing [IOErr]
import OsStr exposing [OsStr]
import Streams
import CliOut
import CliIn
import CliEnv
import FsOps
import Clocks
import RandomHost
Host :: [].{
	## Two domain names for one crossing: the `OsStr` nominal under both.
	NativeOsStr : OsStr
	stdout_line! : Str => Try({}, [StdoutErr(IOErr)])
	stdout_line! = |s| out_write!(CliOut.get_stdout!({}), Str.to_utf8(Str.concat(s, "\n")))
	stdout_write! : Str => Try({}, [StdoutErr(IOErr)])
	stdout_write! = |s| out_write!(CliOut.get_stdout!({}), Str.to_utf8(s))
	stdout_write_bytes! : List(U8) => Try({}, [StdoutErr(IOErr)])
	stdout_write_bytes! = |b| out_write!(CliOut.get_stdout!({}), b)

	stderr_line! : Str => Try({}, [StderrErr(IOErr)])
	stderr_line! = |s| err_write!(CliOut.get_stderr!({}), Str.to_utf8(Str.concat(s, "\n")))
	stderr_write! : Str => Try({}, [StderrErr(IOErr)])
	stderr_write! = |s| err_write!(CliOut.get_stderr!({}), Str.to_utf8(s))
	stderr_write_bytes! : List(U8) => Try({}, [StderrErr(IOErr)])
	stderr_write_bytes! = |b| err_write!(CliOut.get_stderr!({}), b)

	stdin_line! : () => Try(Str, [EndOfFile, StdinErr(IOErr)])
	stdin_line! = || match CliIn.read_line!({}) {
		Ok(line) => Ok(line)
		Err(EndOfFile) => Err(EndOfFile)
		Err(Io(e)) => Err(StdinErr(e))
	}
	stdin_bytes! : () => Try(List(U8), [EndOfFile, StdinErr(IOErr)])
	stdin_bytes! = || {
		match Streams.read!(CliIn.get_stdin!({}), 4096) {
			Ok([]) => Err(EndOfFile)
			Ok(bytes) => Ok(bytes)
			Err(Io(e)) => Err(StdinErr(e))
		}
	}
	stdin_read_to_end! : () => Try(List(U8), [StdinErr(IOErr)])
	stdin_read_to_end! = || CliIn.read_to_end!({}).map_err(|Io(e)| StdinErr(e))

	env_platform! : () => { arch : [X86, X64, ARM, AARCH64, OTHER(Str)], os : [LINUX, MACOS, WINDOWS, OTHER(Str)] }
	env_platform! = || CliEnv.platform!({})

	utc_now! : () => Try(U128, [ClockBeforeEpoch])
	utc_now! = || Clocks.wall_now!({})
	sleep_millis! : U64 => {}
	sleep_millis! = |ms| Clocks.sleep_millis!(ms)
	random_seed_u64! : () => Try(U64, [RandomErr(IOErr)])
	random_seed_u64! = || RandomHost.seed_u64!({}).map_err(|Io(e)| RandomErr(e))
	random_seed_u32! : () => Try(U32, [RandomErr(IOErr)])
	random_seed_u32! = || RandomHost.seed_u32!({}).map_err(|Io(e)| RandomErr(e))
	locale_get! : () => Try(Str, [NotAvailable])
	locale_get! = || match List.first(locale_all!()) {
		Ok(l) => Ok(l)
		Err(_) => Err(NotAvailable)
	}

	## The user's locales as BCP 47 tags, most preferred first: LANGUAGE
	## (colon-separated), then LC_ALL, then LANG, de-duplicated.
	##
	## This was a Rust host component, `locale-host`, whose entire body was
	## these three `std::env::var` calls and `locale_tag` below. It read no OS
	## locale API, so it was an env read wearing a capability's clothes: an
	## interface, a wiring line, an export and a staticlib for something
	## `CliEnv.var!` already grants. In Roc the normalisation is also testable,
	## which it never was in the host.
	locale_all! : () => List(Str)
	locale_all! = || locale_tags(List.concat(
		Str.split_on(env_or_empty!("LANGUAGE"), ":"),
		[env_or_empty!("LC_ALL"), env_or_empty!("LANG")],
	))

	# ---- basic-cli's file/dir/env seam (P15): its Path.roc/File.roc/Env.roc
	# compile UNCHANGED over these, which are pure Roc over FsOps' bytes
	# primitives (P11) and CliEnv. NativePath is the same union as OsStr.
	NativePath : OsStr
	PathType : [File, Dir, SymLink, Other]
	## basic-cli's buffered reader handle: a sync-io input stream, with the
	## descriptor it was opened from.
	FileReader : FsOps.Reader
	## An unbuffered write stream with the descriptor it was opened from.
	FileWriter : FsOps.Writer

	## NativePath -> FsOps bytes. Windows UTF-16 units are not representable on
	## this host and surface as an IOErr rather than a silent transcoding.
	native_bytes : NativePath -> Try(List(U8), IOErr)
	native_bytes = |p| match p {
		Utf8(s) => Ok(Str.to_utf8(s))
		UnixBytes(b) => Ok(b)
		WindowsU16s(_) => Err(Other("windows paths are not supported on this host"))
	}
	bytes_native : List(U8) -> NativePath
	bytes_native = |b| match Str.from_utf8(b) {
		Ok(s) => Utf8(s)
		Err(_) => UnixBytes(b)
	}
	file_bytes : NativePath -> Try(List(U8), [FileErr(IOErr)])
	file_bytes = |p| native_bytes(p).map_err(|e| FileErr(e))
	dir_bytes : NativePath -> Try(List(U8), [DirErr(IOErr)])
	dir_bytes = |p| native_bytes(p).map_err(|e| DirErr(e))

	dir_create! : NativePath => Try({}, [DirErr(IOErr)])
	dir_create! = |p| FsOps.create_dir!(dir_bytes(p)?)
	dir_create_all! : NativePath => Try({}, [DirErr(IOErr)])
	dir_create_all! = |p| FsOps.create_all!(dir_bytes(p)?)
	dir_delete_empty! : NativePath => Try({}, [DirErr(IOErr)])
	dir_delete_empty! = |p| FsOps.delete_empty!(dir_bytes(p)?)
	dir_delete_all! : NativePath => Try({}, [DirErr(IOErr)])
	dir_delete_all! = |p| FsOps.delete_all!(dir_bytes(p)?)
	## basic-cli lists entries joined to the directory (`dir/name`), as
	## `std::fs::read_dir`'s `entry.path()` does; FsOps yields bare names.
	dir_list! : NativePath => Try(List(NativePath), [DirErr(IOErr)])
	dir_list! = |p| {
		dir = dir_bytes(p)?
		Ok(List.map(FsOps.list!(dir)?, |name| bytes_native(join_entry(dir, name))))
	}
	join_entry : List(U8), List(U8) -> List(U8)
	join_entry = |dir, name| match List.last(dir) {
		Ok(c) => if c == '/' { List.concat(dir, name) } else { List.concat(List.append(dir, '/'), name) }
		Err(_) => name
	}

	file_read_bytes! : NativePath => Try(List(U8), [FileErr(IOErr)])
	file_read_bytes! = |p| FsOps.read!(file_bytes(p)?)
	file_write_bytes! : NativePath, List(U8) => Try({}, [FileErr(IOErr)])
	file_write_bytes! = |p, bytes| FsOps.write!(file_bytes(p)?, bytes)
	file_read_utf8! : NativePath => Try(Str, [FileErr(IOErr)])
	file_read_utf8! = |p| match Str.from_utf8(FsOps.read!(file_bytes(p)?)?) {
		Ok(s) => Ok(s)
		Err(_) => Err(FileErr(Other("file is not valid UTF-8")))
	}
	file_write_utf8! : NativePath, Str => Try({}, [FileErr(IOErr)])
	file_write_utf8! = |p, s| FsOps.write!(file_bytes(p)?, Str.to_utf8(s))
	file_open_reader! : NativePath => Try(FileReader, [FileErr(IOErr)])
	file_open_reader! = |p| FsOps.open_read!(file_bytes(p)?)
	## `LineTooLong` rather than a silent split. `read_until!` stops at its cap
	## and cannot say whether the delimiter was among what it returned, so a
	## line longer than the cap came back as a chunk with no trailing newline —
	## which no caller can tell from a real last line except by inspecting the
	## final byte. A JSON-lines or CSV reader over such a file quietly got two
	## corrupt records where there was one long one.
	file_read_line! : FileReader => Try(List(U8), [FileErr(IOErr), LineTooLong])
	file_read_line! = |r| {
		bytes = Streams.read_until!(r.stream, 10, max_line).map_err(|Io(e)| FileErr(e))?
		ended_with_newline =
			match List.last(bytes) {
				Ok(b) => b == 10
				Err(_) => Bool.False
			}
		if List.len(bytes) >= max_line and !ended_with_newline { Err(LineTooLong) } else { Ok(bytes) }
	}
	file_append_bytes! : NativePath, List(U8) => Try({}, [FileErr(IOErr)])
	file_append_bytes! = |p, bytes| FsOps.append!(file_bytes(p)?, bytes)
	file_append_utf8! : NativePath, Str => Try({}, [FileErr(IOErr)])
	file_append_utf8! = |p, s| FsOps.append!(file_bytes(p)?, Str.to_utf8(s))
	file_open_writer! : NativePath => Try(FileWriter, [FileErr(IOErr)])
	file_open_writer! = |p| FsOps.open_writer!(file_bytes(p)?)
	file_open_append! : NativePath => Try(FileWriter, [FileErr(IOErr)])
	file_open_append! = |p| FsOps.open_append!(file_bytes(p)?)
	file_write! : FileWriter, List(U8) => Try({}, [FileErr(IOErr)])
	file_write! = |w, bytes| FsOps.write_stream!(w, bytes)
	file_delete! : NativePath => Try({}, [FileErr(IOErr)])
	file_delete! = |p| FsOps.delete!(file_bytes(p)?)
	file_size_in_bytes! : NativePath => Try(U64, [FileErr(IOErr)])
	file_size_in_bytes! = |p| FsOps.size!(file_bytes(p)?).map_err(|e| FileErr(e))
	file_is_executable! : NativePath => Try(Bool, [FileErr(IOErr)])
	file_is_executable! = |p| FsOps.executable!(file_bytes(p)?).map_err(|e| FileErr(e))
	file_is_readable! : NativePath => Try(Bool, [FileErr(IOErr)])
	file_is_readable! = |p| FsOps.readable!(file_bytes(p)?).map_err(|e| FileErr(e))
	file_is_writable! : NativePath => Try(Bool, [FileErr(IOErr)])
	file_is_writable! = |p| FsOps.writable!(file_bytes(p)?).map_err(|e| FileErr(e))
	file_time_accessed! : NativePath => Try(U128, [FileErr(IOErr)])
	file_time_accessed! = |p| FsOps.accessed!(file_bytes(p)?).map_err(|e| FileErr(e))
	file_time_modified! : NativePath => Try(U128, [FileErr(IOErr)])
	file_time_modified! = |p| FsOps.modified!(file_bytes(p)?).map_err(|e| FileErr(e))
	file_time_created! : NativePath => Try(U128, [FileErr(IOErr)])
	file_time_created! = |p| FsOps.created!(file_bytes(p)?).map_err(|e| FileErr(e))
	file_hard_link! : NativePath, NativePath => Try({}, [FileErr(IOErr)])
	file_hard_link! = |from, to| FsOps.hard_link!(file_bytes(from)?, file_bytes(to)?)
	file_copy! : NativePath, NativePath => Try({}, [FileErr(IOErr)])
	file_copy! = |from, to| FsOps.copy!(file_bytes(from)?, file_bytes(to)?)
	file_sym_link! : NativePath, NativePath => Try({}, [FileErr(IOErr)])
	file_sym_link! = |target, link| FsOps.sym_link!(file_bytes(target)?, file_bytes(link)?)
	file_read_sym_link! : NativePath => Try(NativePath, [FileErr(IOErr)])
	file_read_sym_link! = |p| Ok(bytes_native(FsOps.read_sym_link!(file_bytes(p)?)?))
	file_rename! : NativePath, NativePath => Try({}, [FileErr(IOErr)])
	file_rename! = |from, to| FsOps.rename!(file_bytes(from)?, file_bytes(to)?)
	path_type! : NativePath => Try(PathType, IOErr)
	path_type! = |p| FsOps.kind!(native_bytes(p)?)

	env_var! : NativeOsStr => Try(NativeOsStr, [VarNotFound(NativeOsStr), EnvErr(IOErr)])
	## No longer decides that a non-Utf8 NAME cannot exist. It used to answer
	## `VarNotFound(other)` without asking the host at all.
	env_var! = |name| match CliEnv.var!(name) {
		Ok(v) => Ok(v)
		Err(VarNotFound(n)) => Err(VarNotFound(n))
		Err(Io(e)) => Err(EnvErr(e))
	}
	env_dict! : () => List((NativeOsStr, NativeOsStr))
	env_dict! = || List.map(CliEnv.env!({}), |e| (e.name, e.value))
	env_cwd! : () => Try(NativePath, [CwdUnavailable])
	env_cwd! = || Ok(Utf8(FsOps.cwd!({})))
	env_set_cwd! : NativePath => Try({}, IOErr)
	env_set_cwd! = |p| match p {
		Utf8(s) => FsOps.set_cwd!(s)
		UnixBytes(b) => match Str.from_utf8(b) {
			Ok(s) => FsOps.set_cwd!(s)
			Err(_) => Err(Other("cwd is not valid UTF-8"))
		}
		WindowsU16s(_) => Err(Other("windows paths are not supported on this host"))
	}
	env_exe_path! : () => Try(NativePath, [ExePathUnavailable])
	env_exe_path! = || Ok(Utf8(CliEnv.exe_path!({})))
	env_temp_dir! : () => NativePath
	env_temp_dir! = || Utf8(CliEnv.temp_dir!({}))
}

out_write! : Streams.OutputStream, List(U8) => Try({}, [StdoutErr(IOErr)])
out_write! = |stream, bytes| {
	match Streams.write!(stream, bytes) {
		Ok({}) => Ok({})
		Err(Io(e)) => Err(StdoutErr(e))
	}
}
err_write! : Streams.OutputStream, List(U8) => Try({}, [StderrErr(IOErr)])
err_write! = |stream, bytes| {
	match Streams.write!(stream, bytes) {
		Ok({}) => Ok({})
		Err(Io(e)) => Err(StderrErr(e))
	}
}


## name\0value\0... -> [(name, value), ...]

env_or_empty! : Str => Str
env_or_empty! = |name| match CliEnv.var!(OsStr.utf8(name)) {
	Ok(value) => OsStr.display(value)
	Err(_) => ""
}

## "en_US.UTF-8" -> "en-US". The `.charset` and `@modifier` suffixes are not
## part of a language tag, and "C"/"POSIX" name the absence of a locale rather
## than one, so they are dropped rather than reported as a tag nobody can parse.
locale_tag : Str -> Try(Str, [NotALocale])
locale_tag = |raw| {
	base = before(before(raw, "."), "@")
	if Str.is_empty(base) or base == "C" or base == "POSIX" {
		Err(NotALocale)
	} else {
		Ok(Str.replace_each(base, "_", "-"))
	}
}

## The part of `s` before the first `sep`, or all of `s` when there is none.
before : Str, Str -> Str
before = |s, sep| match List.first(Str.split_on(s, sep)) {
	Ok(head) => head
	Err(_) => s
}

## Candidate strings, most preferred first, reduced to the distinct tags among
## them. Pure, and separate from the env reads above, so it is testable.
locale_tags : List(Str) -> List(Str)
locale_tags = |candidates|
	List.fold(candidates, [], |acc, raw| match locale_tag(raw) {
		Err(NotALocale) => acc
		Ok(tag) => if List.any(acc, |seen| seen == tag) { acc } else { List.append(acc, tag) }
	})

expect locale_tags(["en_US.UTF-8"]) == ["en-US"]
expect locale_tags(["fr_FR.UTF-8", "en_US.UTF-8"]) == ["fr-FR", "en-US"]
expect locale_tags(["de_DE", "fr_FR", "en_US.UTF-8"]) == ["de-DE", "fr-FR", "en-US"]
expect locale_tags(["en_US", "", "en_US.UTF-8"]) == ["en-US"]
expect locale_tags(["", "C", "POSIX"]) == []
expect locale_tags([]) == []

expect locale_tag("en_US.UTF-8") == Ok("en-US")
expect locale_tag("en_US") == Ok("en-US")
expect locale_tag("fr") == Ok("fr")
expect locale_tag("de_DE@euro") == Ok("de-DE")
expect locale_tag("sr_RS.UTF-8@latin") == Ok("sr-RS")

# The absence of a locale is not a locale.
expect locale_tag("C") == Err(NotALocale)
expect locale_tag("POSIX") == Err(NotALocale)
expect locale_tag("") == Err(NotALocale)
expect locale_tag(".UTF-8") == Err(NotALocale)


## The most one `file_read_line!` will accumulate before calling the line too
## long. A cap is needed at all because a file with no newline in it would
## otherwise be read entirely into memory by a function the caller believes
## reads one line.
max_line : U64
max_line = 1_048_576
