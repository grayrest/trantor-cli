# trantor-cli

A Roc CLI package for the [trantor platform](http://github.com/grayrest/trantor).
At core, this is a Roc port of the WASI 0.3 cli world but it also offers a
`basic-cli` 0.21 API shim for easier migration.

Choose this over `basic-cli` if you want to use `trantor` to add Rust-based
dependencies as your app grows.

## Setup

```sh
git clone http://github.com/grayrest/trantor-cli
cd ./myapp
```

```toml
# world.toml
[world]
name = "myapp"

[deps]
trantor-cli = { path = "../trantor-cli" }
```

## roc:cli

This API is derived from WASI 0.3's `wasi:cli` and features:

* streams rather than files
* preopens rather than paths (limited file operations)

Since the Trantor system supports extension, this package covers a significantly
smaller domain than `basic-cli` and a particular design goal was to allow apps
opting into `fs-confined` to only write to a pre-existing set of files and not
run arbitrary processes, make network requests, or control the terminal without
opting into a package covering those features.

The modules are `Cli`,`Fs`, `Streams`, `Clocks`,  `OsStr`, and `IOErr`.
`Cli` is for the app process itself — arguments, environment, the three
standard streams, the terminal, and `exit!`.

```roc
app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.IOErr exposing [IOErr]
import pf.Cli
import pf.Streams
import pf.Clocks

main! : List(OsStr) => Try({}, [Io(IOErr), ..])
main! = |_args| {
	out = Cli.get_stdout!({})
	n = List.len(Cli.args!({}))
	Clocks.sleep_millis!(1)
	Streams.write!(out, Str.to_utf8("argc=${n.to_str()}\n"))?
	Ok({})
}
```

### Cli

```roc
# environment
Cli.args! : {} => List(OsStr)                                   # argv[0] first; an app uses main!'s argument
Cli.var! : OsStr => Try(OsStr, [VarNotFound(OsStr), Io(IOErr)])
Cli.env! : {} => List({ name : OsStr, value : OsStr })
Cli.cwd! : {} => Try(OsStr, [Io(IOErr)])                        # the OS's bytes; Io when it is gone
Cli.exe_path! : {} => Try(OsStr, [Io(IOErr)])
Cli.temp_dir! : {} => OsStr                                     # TMPDIR, or the platform default
Cli.platform! : {} => { arch : [X86, X64, ARM, AARCH64, OTHER(Str)], os : [LINUX, MACOS, WINDOWS, OTHER(Str)] }

# exit
Cli.exit! : I32 => {}                                           # does not return

# standard streams
Cli.get_stdin! : {} => Streams.InputStream
Cli.get_stdout! : {} => Streams.OutputStream
Cli.get_stderr! : {} => Streams.OutputStream
Cli.stdin_line! : {} => Try(Str, [EndOfFile, Io(IOErr)])        # without its newline
Cli.stdin_read_to_end! : {} => Try(List(U8), [Io(IOErr)])
```

### Clocks

```roc
Clocks.wall_now! : {} => Try(U128, [ClockBeforeEpoch])   # nanoseconds since the Unix epoch
Clocks.monotonic_now! : {} => U64                        # nanoseconds, arbitrary origin
Clocks.sleep_millis! : U64 => {}
```

### Streams

```roc
InputStream :: Box(U64)                                   # refcounted host handle
OutputStream :: Box(U64)

Streams.read! : InputStream, U64 => Try(List(U8), [Io(IOErr)])         # up to U64 bytes; [] at end of stream
Streams.read_until! : InputStream, U8, U64 => Try(List(U8), [Io(IOErr)])   # through the delimiter byte, at most U64 bytes
Streams.write! : OutputStream, List(U8) => Try({}, [Io(IOErr)])
```

### Fs

Every operation is relative to a `Descriptor`, and paths are bytes.

```roc
Descriptor :: Box(U64)                                    # a preopened directory or an open file
OpenFlags : { read : Bool, write : Bool, create : Bool, exclusive : Bool, truncate : Bool,
              append : Bool, directory : Bool, follow_symlinks : Bool, mode : U32 }

# opening
Fs.open_with_flags_at! : Descriptor, List(U8), OpenFlags => Try(Descriptor, [Io(IOErr)])   # no checks
Fs.default_file_mode : U32                                # 0o666
Fs.default_dir_mode : U32                                 # 0o777
Fs.preopens! : {} => List(Descriptor)
Fs.open_at! : Descriptor, List(U8), { read ?: Bool, write ?: Bool, create ?: Bool, exclusive ?: Bool, truncate ?: Bool,
                                      append ?: Bool, directory ?: Bool, follow_symlinks ?: Bool, mode ?: U32 }
              => Try(Descriptor, [Io(IOErr)])
Fs.open_flags : { read ?: Bool, write ?: Bool, create ?: Bool, exclusive ?: Bool, truncate ?: Bool,
                  append ?: Bool, directory ?: Bool, follow_symlinks ?: Bool, mode ?: U32 }
                -> Try(OpenFlags, [Io(IOErr)])            # open_at!'s defaults and checks

# streams
Fs.read_via_stream! : Descriptor => Try(Streams.InputStream, [Io(IOErr)])
Fs.write_via_stream! : Descriptor, U64 => Try(Streams.OutputStream, [Io(IOErr)])   # from the offset; unbuffered
Fs.append_via_stream! : Descriptor => Try(Streams.OutputStream, [Io(IOErr)])

# whole files
Fs.read_file_at! : Descriptor, List(U8) => Try(List(U8), [Io(IOErr)])
Fs.write_file_at! : Descriptor, List(U8), List(U8) => Try({}, [Io(IOErr)])

# metadata
Fs.stat_at! : Descriptor, List(U8), { follow_symlinks : Bool }
              => Try({ kind : [File, Dir, SymLink, Other], size : U64, accessed_ns : U128, modified_ns : U128,
                       created_ns : U128, readable : Bool, writable : Bool, executable : Bool }, [Io(IOErr)])
Fs.metadata_hash_at! : Descriptor, List(U8), { follow_symlinks : Bool }
                       => Try({ lower : U64, upper : U64 }, [Io(IOErr)])   # equal when two paths name one file
Fs.read_dir_at! : Descriptor, List(U8) => Try(List({ name : List(U8), kind : [File, Dir, SymLink, Other] }), [Io(IOErr)])   # sorted by name

# directories
Fs.create_dir_at! : Descriptor, List(U8), U32 => Try({}, [Io(IOErr)])   # the U32 is the mode, before the umask
Fs.create_dir_all_at! : Descriptor, List(U8) => Try({}, [Io(IOErr)])
Fs.remove_dir_at! : Descriptor, List(U8) => Try({}, [Io(IOErr)])
Fs.remove_dir_all_at! : Descriptor, List(U8) => Try({}, [Io(IOErr)])

# files and links
Fs.unlink_at! : Descriptor, List(U8) => Try({}, [Io(IOErr)])
Fs.rename_at! : Descriptor, List(U8), List(U8) => Try({}, [Io(IOErr)])
Fs.link_at! : Descriptor, List(U8), List(U8) => Try({}, [Io(IOErr)])
Fs.copy_file_at! : Descriptor, List(U8), Descriptor, List(U8) => Try({}, [Io(IOErr)])   # AlreadyExists if the destination exists
Fs.copy_dir_at! : Descriptor, List(U8), Descriptor, List(U8) => Try({}, [Io(IOErr)])    # the directory and its bits, not its contents
Fs.readlink_at! : Descriptor, List(U8) => Try(List(U8), [Io(IOErr)])
Fs.symlink_at! : Descriptor, List(U8), List(U8) => Try({}, [Io(IOErr)])                 # target, then link
```

### IOErr

```roc
IOErr := [AlreadyExists, BrokenPipe, Interrupted, IsADirectory, NotFound, NotADirectory,
          Other(Str), OutOfMemory, PermissionDenied, Unsupported]

to_str : IOErr -> Str                                     # "entity was not found"
```

### OsStr

```roc
OsStr := [Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]

# constructing
from_str : Str -> OsStr
utf8 : Str -> OsStr
unix : Str -> OsStr                                       # stores the UTF-8 bytes
unix_bytes : List(U8) -> OsStr                            # not checked for UTF-8
windows : Str -> OsStr                                    # stores the UTF-16 code units
windows_u16s : List(U16) -> OsStr
from_quote : Str -> Try(OsStr, [BadQuotedBytes(Str)])
from_interpolation : Str, Iter((Str, Str)) -> OsStr

# reading
to_str_try : OsStr -> Try(Str, [InvalidStr(U64)])
display : OsStr -> Str                                    # lossy, U+FFFD for invalid text
to_inspect : OsStr -> Str                                 # "OsStr.unix_bytes([97, 255, 98])"

# comparing: by representation, so utf8("abc") != unix("abc")
is_eq : OsStr, OsStr -> Bool
to_hash : OsStr, Hasher -> Hasher

# the host representation
to_raw : OsStr -> [Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]
from_raw : [Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))] -> OsStr
```

## roc:basic-cli

`basic-cli` 0.21's surface minus Sqlite (use `trantor-sqlite`), Tty (`trantor-terminal`)
and Cmd (`trantor-process`).

```roc
app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr
import pf.Stdout
import pf.Path

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	out_file : Path
	out_file = "out.txt"
	out_file.write_utf8!("a string!")?
	Stdout.line!(out_file.read_utf8!()?)?
	Ok({})
}
```

### basic-cli Extensions

Within its domain, `roc:cli` has a larger set of features than `basic_cli` and
making them available seemed reasonable:

- `Path.append_bytes!` and `append_utf8!` create the file if missing and write
  at its end.
- `File.open_writer!` (create or truncate) and `File.open_append!` return a
  `File.Writer` with `write!`, `write_utf8!` and `line!`. Writes are
  unbuffered: each one reaches the file before it returns, so its error is
  that write's error. Batch in Roc when the number of writes matters.
- `Path.copy!` copies one file with its permission bits (not timestamps or
  setuid/setgid) and refuses an existing destination. `Path.sym_link!(target, link)` and `Path.read_sym_link!` sit
  beside `hard_link!`.
- `File.Reader.descriptor` and `File.Writer.descriptor` give the open file, for
  redirecting a child process's stdio in `trantor-process`.

Walking, globbing, temp files and tree copies are in the `trantor-files`
package.

```roc
log = File.open_append!(Path.utf8("build.log"))?
log.line!("started")?
Path.copy!(Path.utf8("tool.sh"), Path.utf8("bin/tool.sh"))?
```

A `File.Reader` or `File.Writer` holds two OS descriptors — the open file and
the stream's duplicate — so that a child process can be handed the same open
file; the raw `Fs.open_at!` holds one.

The raw layer underneath: `Fs.open_at!` takes WASI's open flags as a record
with defaults (`{}` opens an existing file read-only; `write`, `create`,
`exclusive`, `truncate`, `append`, `directory`, `follow_symlinks`, and `mode`
for what a `create` makes), plus
`write_via_stream!`, `append_via_stream!`, `copy_file_at!`, `copy_dir_at!`
(a directory with its source's permission bits), `readlink_at!` and
`symlink_at!`; `read_dir_at!` returns each entry with its kind, and `stat_at!`
takes `{ follow_symlinks }`.

### Path

```roc
Path := [Utf8(Str), Unix(List(U8)), Windows(List(U16))]

# constructing
utf8 : Str -> Path
unix : Str -> Path                                        # stores the UTF-8 bytes
unix_bytes : List(U8) -> Path
windows : Str -> Path                                     # stores the UTF-16 code units
windows_u16s : List(U16) -> Path
from_quote : Str -> Try(Path, [BadQuotedBytes(Str)])
from_interpolation : Str, Iter((Str, Str)) -> Path        # text concatenation; join adds a separator
from_os_str : OsStr -> Path
from_raw : OsStr -> Path

# rendering and comparing
to_str : Path -> Try(Str, [InvalidStr(U64)])
display : Path -> Str                                     # lossy
to_inspect : Path -> Str                                  # "Path.unix(\"abc\")"
to_os_str : Path -> OsStr
to_raw : Path -> OsStr
is_eq : Path, Path -> Bool                                # by representation, as OsStr
to_hash : Path, Hasher -> Hasher

# components
filename : Path -> Try(Path, [IsDirPath, EndsInDots])
ext : Path -> Try(Path, [IsDirPath, EndsInDots])          # without the dot
join : Path, Str -> Path

# what is on disk
type! : Path => Try([IsFile, IsDir, IsSymLink, IsOther], [PathErr(IOErr), ..])
exists! : Path => Try(Bool, [PathErr(IOErr), ..])
is_file! : Path => Try(Bool, [PathErr(IOErr), ..])        # a link is not followed
is_dir! : Path => Try(Bool, [PathErr(IOErr), ..])         # a link is not followed
is_sym_link! : Path => Try(Bool, [PathErr(IOErr), ..])
size_in_bytes! : Path => Try(U64, [PathErr(IOErr), ..])
is_executable! : Path => Try(Bool, [PathErr(IOErr), ..])  # any x bit, links followed
is_readable! : Path => Try(Bool, [PathErr(IOErr), ..])    # any r bit, not this user's access
is_writable! : Path => Try(Bool, [PathErr(IOErr), ..])    # any w bit, not this user's access
time_accessed! : Path => Try(U128, [PathErr(IOErr), ..])  # nanoseconds since the epoch
time_modified! : Path => Try(U128, [PathErr(IOErr), ..])
time_created! : Path => Try(U128, [PathErr(IOErr), ..])

# files
read_bytes! : Path => Try(List(U8), [PathErr(IOErr), ..])
read_utf8! : Path => Try(Str, [PathErr(IOErr), ..])
write_bytes! : Path, List(U8) => Try({}, [PathErr(IOErr), ..])
write_utf8! : Path, Str => Try({}, [PathErr(IOErr), ..])
append_bytes! : Path, List(U8) => Try({}, [PathErr(IOErr), ..])   # creates the file if missing
append_utf8! : Path, Str => Try({}, [PathErr(IOErr), ..])
replace_utf8! : Path, Str, Str => Try({}, [PathErr(IOErr), ..])   # pattern, replacement; not atomic
delete! : Path => Try({}, [PathErr(IOErr), ..])
copy! : Path, Path => Try({}, [PathErr(IOErr), ..])               # from, to
rename! : Path, Path => Try({}, [PathErr(IOErr), ..])             # from, to

# links
hard_link! : Path, Path => Try({}, [PathErr(IOErr), ..])          # original, link
sym_link! : Path, Path => Try({}, [PathErr(IOErr), ..])           # target, link
read_sym_link! : Path => Try(Path, [PathErr(IOErr), ..])          # unresolved

# directories
create_dir! : Path => Try({}, [PathErr(IOErr), ..])
create_all! : Path => Try({}, [PathErr(IOErr), ..])
delete_empty! : Path => Try({}, [PathErr(IOErr), ..])
delete_all! : Path => Try({}, [PathErr(IOErr), ..])
list! : Path => Try(List(Path), [PathErr(IOErr), ..])
```

### File

```roc
Reader :: { host : Host.FileReader }
Writer :: { host : Host.FileWriter }

# opening
File.open_reader! : Path.Path => Try(Reader, [FileErr(IOErr), ..])
File.open_writer! : Path.Path => Try(Writer, [FileErr(IOErr), ..])   # create or truncate
File.open_append! : Path.Path => Try(Writer, [FileErr(IOErr), ..])   # create if missing

# reading
read_line! : Reader => Try(List(U8), _)                   # through the newline; [] at EOF, LineTooLong past the cap
descriptor : Reader -> Fs.Descriptor
to_inspect : Reader -> Str                                # "File.Reader(<opaque>)"

# writing, unbuffered
write! : Writer, List(U8) => Try({}, [FileErr(IOErr), ..])
write_utf8! : Writer, Str => Try({}, [FileErr(IOErr), ..])
line! : Writer, Str => Try({}, [FileErr(IOErr), ..])      # one write, newline included
descriptor : Writer -> Fs.Descriptor
to_inspect : Writer -> Str                                # "File.Writer(<opaque>)"
from_host : Host.FileWriter -> Writer                     # for a writer opened through Fs, as trantor-files' Temp does
```

### Env

```roc
# variables
Env.var! : OsStr => Try(OsStr, [VarNotFound(OsStr), EnvErr(IOErr), ..])
Env.var_str! : OsStr => Try(Str, [VarNotFound(OsStr), EnvErr(IOErr), InvalidStr(U64), ..])
Env.dict! : () => List((OsStr, OsStr))                    # in no particular order

# the process
Env.cwd! : () => Try(Path.Path, [CwdUnavailable, ..])
Env.set_cwd! : Path.Path => Try({}, [InvalidCwd(IOErr), ..])
Env.exe_path! : () => Try(Path.Path, [ExePathUnavailable, ..])
Env.temp_dir! : () => Path.Path
Env.platform! : () => { arch : [X86, X64, ARM, AARCH64, OTHER(Str)], os : [LINUX, MACOS, WINDOWS, OTHER(Str)] }
```

### Stdin

```roc
Stdin.line! : () => Try(Str, [EndOfFile, StdinErr(IOErr), ..])
Stdin.bytes! : () => Try(List(U8), [EndOfFile, StdinErr(IOErr), ..])   # at most 4,096 bytes a call
Stdin.read_to_end! : () => Try(List(U8), [StdinErr(IOErr), ..])
```

### Stdout

```roc
Stdout.line! : Str => Try({}, [StdoutErr(IOErr), ..])
Stdout.write! : Str => Try({}, [StdoutErr(IOErr), ..])
Stdout.write_bytes! : List(U8) => Try({}, [StdoutErr(IOErr), ..])
```

### Stderr

```roc
Stderr.line! : Str => Try({}, [StderrErr(IOErr), ..])
Stderr.write! : Str => Try({}, [StderrErr(IOErr), ..])
Stderr.write_bytes! : List(U8) => Try({}, [StderrErr(IOErr), ..])
```

### Utc

```roc
Utc.now! : () => U128                                     # nanoseconds since the epoch; 0 before it
Utc.to_millis_since_epoch : U128 -> U128
Utc.from_millis_since_epoch : U128 -> U128
Utc.to_nanos_since_epoch : U128 -> U128
Utc.from_nanos_since_epoch : U128 -> U128
Utc.delta_as_nanos : U128, U128 -> U128                   # absolute difference
Utc.delta_as_millis : U128, U128 -> U128
Utc.to_iso_8601 : U128 -> Str                             # to the second
```

### Sleep

```roc
Sleep.millis! : U64 => {}
Sleep.seconds! : F64 => {}                                # truncated to milliseconds; negative or NaN returns at once
```

### Random

```roc
Random.seed_u64! : () => Try(U64, [RandomErr(IOErr), ..])
Random.seed_u32! : () => Try(U32, [RandomErr(IOErr), ..])
```

### Locale

```roc
Locale :: { raw : Str }
ParseErr : [Empty, EmptySubtag, InvalidCharacter, InvalidLanguage, MissingExtensionValue, SubtagTooLong]

# constructing
parse : Str -> Try(Locale, ParseErr)                      # a BCP 47 tag, "en-US"
from_quote : Str -> Try(Locale, [BadQuotedBytes(Str)])
get! : () => Try(Locale, [NotAvailable, ..])              # the first of all!
all! : () => List(Locale)                                 # LANGUAGE, then the first of LC_ALL/LC_MESSAGES/LANG; none under C/POSIX

# rendering and comparing
to_str : Locale -> Str                                    # the original spelling
to_inspect : Locale -> Str
is_eq : Locale, Locale -> Bool                            # ASCII case-insensitive
to_hash : Locale, Hasher -> Hasher

# encoding
parser_for : encoding -> (state -> Try({ value : Locale, rest : state }, err))
    where [
        encoding.parse_str : encoding, state -> Try({ value : Str, rest : state }, err),
        encoding.invalid_value : encoding, state -> err,
    ]
encoder_for : encoding -> (Locale, state -> Try(state, err))
    where [
        encoding.encode_str : Str, state -> Try(state, err),
    ]
```

### Url

An absolute `http` or `https` URL, stricter than a browser's parser.

```roc
Url :: { scheme : [Http, Https], host : Str, port : [None, Some(U16)], path : Str,
         query : [None, Some(Str)], fragment : [None, Some(Str)] }

ParseErr : [CredentialsNotAllowed, EmptyHost, InternationalHostUnsupported, InvalidCharacter(U8),
            InvalidHost(Str), InvalidIpv4(Str), InvalidIpv6(Str), InvalidPercentEncoding(U64),
            InvalidPort(Str), MissingAuthority, MissingScheme, PortOutOfRange(U64), UnsupportedScheme(Str)]

# constructing
parse : Str -> Try(Url, ParseErr)
from_quote : Str -> Try(Url, [BadQuotedBytes(Str)])

# reading
scheme : Url -> [Http, Https]
host : Url -> Str                                         # IPv6 without brackets
port : Url -> [None, Some(U16)]                           # None for 80 on Http and 443 on Https
path : Url -> Str                                         # percent-encoded, starts with "/"
query : Url -> [None, Some(Str)]                          # Some("") is a present, empty query
fragment : Url -> [None, Some(Str)]
query_pairs : Url -> List((Str, Str))                     # form-decoded, in order, duplicates kept

# changing
resolve : Url, Str -> Try(Url, ParseErr)                  # a relative reference or absolute http(s) URL; other schemes refused
append_path_segments : Url, List(Str) -> Url              # a "/" inside an item is encoded, and a "." or ".." item
append_query_param : Url, Str, Str -> Url                 # name, value
with_query : Url, [None, Some(Str)] -> Try(Url, ParseErr)
with_fragment : Url, [None, Some(Str)] -> Try(Url, ParseErr)
without_fragment : Url -> Url

# rendering and comparing
to_str : Url -> Str                                       # normalized
to_inspect : Url -> Str
is_eq : Url, Url -> Bool                                  # by to_str
to_hash : Url, Hasher -> Hasher

# encoding
parser_for : encoding -> (state -> Try({ value : Url, rest : state }, err))
    where [
        encoding.parse_str : encoding, state -> Try({ value : Str, rest : state }, err),
        encoding.invalid_value : encoding, state -> err,
    ]
encoder_for : encoding -> (Url, state -> Try(state, err))
    where [
        encoding.encode_str : Str, state -> Try(state, err),
    ]
```

## Overrides

Trantor supports overriding package components with alternative
implementations. In particular, the confined filesystem ships in
this package but is not wired by default:

```toml
[wiring]
fs = "fs-confined"
```

Swapping this in produces a binary that can only read a limited set of files.
Every path operation resolves beneath the root at the moment it is used, so a
directory swapped for a symlink cannot redirect it outside. A symlink can only
be created pointing at something that already exists inside the root, so a
confined app cannot leave links for unconfined programs to follow out of it.

It stays confined only while the world does not add `trantor-process`: a child
process is not bound by the filesystem policy, so a world that can start one
can reach anything the child can.

## Testing

```sh
trantor test .
```

Composes the package on its own driver and runs its `expect`s, both README apps
above, and the suites in `tests/`: a consumer made with `trantor new`, exit
statuses, non-UTF-8 arguments and variables, OS errors, paths, write modes and
open flags, copies and links, the fd handoff, stdin streams (one of them on a
terminal), a relative working directory, the raw layer without the shim, the
`[wiring]` override, the confined root under a concurrent symlink swap for
every path operation, the same app on both filesystems with its output diffed,
and a generated matrix of every operation against every spelling of a path,
also diffed between the two.
