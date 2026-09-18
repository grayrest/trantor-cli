app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Path exposing [Path]
import pf.IOErr exposing [IOErr]
import pf.File
import pf.Fs
import pf.Streams

## The same operations on the default and the confined filesystem. The script
## runs this app on both and requires identical output, so each line is an
## outcome that used to differ between them.
outcome : Try(a, [PathErr(IOErr), ..]) -> Str
outcome = |r| match r {
	Ok(_) => "ok"
	Err(PathErr(e)) => "err:${tag(e)}"
	Err(_) => "err:other"
}

raw : Try(a, [Io(IOErr)]) -> Str
raw = |r| match r {
	Ok(_) => "ok"
	Err(Io(e)) => "err:${tag(e)}"
}

## `Other`'s message differs by OS and backend wording; its kind is the contract.
tag : IOErr -> Str
tag = |e| match e {
	Other(_) => "Other"
	_ => Str.inspect(e)
}

abs! : Str => List(U8)
abs! = |name| {
	cwd = Env.cwd!() ?? Path.utf8(".")
	Str.to_utf8("${Path.display(cwd)}/${name}")
}

bool : Try(Bool, [PathErr(IOErr), ..]) -> Str
bool = |r| match r {
	Ok(b) => Str.inspect(b)
	Err(PathErr(e)) => "err:${tag(e)}"
	Err(_) => "err:other"
}

number : Try(U64, [PathErr(IOErr), ..]) -> Str
number = |r| match r {
	Ok(n) => n.to_str()
	Err(PathErr(e)) => "err:${tag(e)}"
	Err(_) => "err:other"
}

kind! : Str => Str
kind! = |name| match Path.type!(Path.utf8(name)) {
	Ok(k) => Str.inspect(k)
	Err(PathErr(e)) => "err:${tag(e)}"
	Err(_) => "err:other"
}

here! : () => List(U8)
here! = || Str.to_utf8(Path.display(Env.cwd!() ?? Path.utf8(".")))

root! : () => Fs.Descriptor
root! = || Fs.preopens!({}).first() ?? crash("no preopen")

## With two arguments, the root spelled through a link to one of its
## ancestors instead (see `alias!`).
main! : List(OsStr) => Try({}, _)
main! = |args| match (List.get(args, 1), List.get(args, 2)) {
	(Ok(inside), Ok(outside)) => alias!(OsStr.display(inside), OsStr.display(outside))
	_ => agree!()
}

## The root as `<link>/c`, where the link leads to the root's parent, as `/tmp`
## leads to `/private`: confined, only the canonical spelling used to be
## inside. `outside` is a file beside the root, through the same link.
alias! : Str, Str => Try({}, _)
alias! = |inside, outside| {
	lines = [
		"alias-read ${outcome(Path.read_utf8!(Path.utf8("${inside}/keep.txt")))}",
		"alias-write ${outcome(Path.write_utf8!(Path.utf8("${inside}/alias-new.txt"), "new"))}",
		"alias-missing ${outcome(Path.read_utf8!(Path.utf8("${inside}/nothing-here")))}",
		"alias-escape ${outcome(Path.read_utf8!(Path.utf8("${inside}/../p/keep.txt")))}",
		"alias-outside ${outcome(Path.read_utf8!(Path.utf8(outside)))}",
	]
	Stdout.line!(Str.join_with(lines, "\n"))
}

agree! : () => Try({}, _)
agree! = || {
	lines = [
		# A trailing / on a path that is not a directory.
		"write-slash ${outcome(Path.write_bytes!(Path.utf8("out/"), [1]))}",
		"copy-slash ${outcome(Path.copy!(Path.utf8("keep.txt"), Path.utf8("nf2/")))}",
		"rename-slash ${outcome(Path.rename!(Path.utf8("ren.txt"), Path.utf8("k3/")))}",
		"open-slash ${raw(Fs.open_at!(root!(), abs!("keep.txt/"), {}))}",
		"delete-link-slash ${outcome(Path.delete!(Path.utf8("filelink/")))}",
		# A missing source copied onto an existing file: the source is reported.
		"copy-missing ${outcome(Path.copy!(Path.utf8("missing.txt"), Path.utf8("keep.txt")))}",
		"copy-dir ${outcome(Path.copy!(Path.utf8("adir"), Path.utf8("dircopy")))}",
		"copy-setuid ${outcome(Path.copy!(Path.utf8("setuid.sh"), Path.utf8("setuid-copy.sh")))}",
		"copy-old ${outcome(Path.copy!(Path.utf8("old.txt"), Path.utf8("old-copy.txt")))}",
		# A trailing /. on a file, a link or a missing name.
		"write-dot ${outcome(Path.write_bytes!(Path.utf8("keep.txt/."), [1]))}",
		"truncate-dot ${raw(Fs.open_at!(root!(), abs!("keep.txt/."), { write: True, truncate: True }))}",
		"write-new-dot ${outcome(Path.write_bytes!(Path.utf8("newf/."), [1]))}",
		"unlink-link-dot ${outcome(Path.delete!(Path.utf8("filelink/.")))}",
		"symlink-dot ${raw(Fs.symlink_at!(root!(), Str.to_utf8("keep.txt"), abs!("newlink/.")))}",
		"copy-dot ${outcome(Path.copy!(Path.utf8("keep.txt"), Path.utf8("cs2/.")))}",
		"mkdir-dot ${outcome(Path.create_dir!(Path.utf8("nd/.")))}",
		# A link to a directory, named as a directory, is followed.
		"type-dirlink ${kind!("dirlink")}",
		"type-dirlink-slash ${kind!("dirlink/")}",
		"type-dirlink-dot ${kind!("dirlink/.")}",
		"hash-dirlink-slash ${raw(Fs.metadata_hash_at!(root!(), abs!("dirlink/"), { follow_symlinks: False }))}",
		"rename-link-slash ${outcome(Path.rename!(Path.utf8("sub/q/"), Path.utf8("q2")))}",
		"open-create-slash ${raw(Fs.open_at!(root!(), abs!("oc/"), { write: True, create: True }))}",
		# A FIFO source is refused, not waited on for a writer.
		"copy-fifo ${outcome(Path.copy!(Path.utf8("fifo"), Path.utf8("fifo-copy")))}",
		# A directory copy carries the source's bits, never a link's.
		"copy-dir-private ${raw(Fs.copy_dir_at!(root!(), abs!("private"), root!(), abs!("private-copy")))}",
		"copy-dir-readonly ${raw(Fs.copy_dir_at!(root!(), abs!("readonly"), root!(), abs!("readonly-copy")))}",
		"copy-dir-setgid ${raw(Fs.copy_dir_at!(root!(), abs!("shared"), root!(), abs!("shared-copy")))}",
		"copy-dir-link ${raw(Fs.copy_dir_at!(root!(), abs!("dirlink"), root!(), abs!("dirlink-copy")))}",
		"copy-dir-file ${raw(Fs.copy_dir_at!(root!(), abs!("keep.txt"), root!(), abs!("keep-copy")))}",
		"copy-dir-exists ${raw(Fs.copy_dir_at!(root!(), abs!("private"), root!(), abs!("adir")))}",
		# Metadata is what the link leads to, as basic-cli reads it.
		"size-file ${number(Path.size_in_bytes!(Path.utf8("big.txt")))}",
		"size-link ${number(Path.size_in_bytes!(Path.utf8("biglink")))}",
		"readable-link ${bool(Path.is_readable!(Path.utf8("shutlink")))}",
		"writable-link ${bool(Path.is_writable!(Path.utf8("rolink")))}",
		# Executable means what a link leads to.
		"exec-dangling ${bool(Path.is_executable!(Path.utf8("dangling")))}",
		"exec-link-noexec ${bool(Path.is_executable!(Path.utf8("noexec-link")))}",
		"exec-link-exec ${bool(Path.is_executable!(Path.utf8("setuid-link")))}",
		# A directory named with a trailing slash is the directory; through a
		# link, it is refused rather than removing where the link leads.
		"delete-empty-slash ${outcome(Path.delete_empty!(Path.utf8("empty/")))}",
		"delete-all-slash ${outcome(Path.delete_all!(Path.utf8("tree/")))}",
		"delete-empty-link-slash ${outcome(Path.delete_empty!(Path.utf8("emptylink/")))}",
		"delete-all-link-slash ${outcome(Path.delete_all!(Path.utf8("treelink/")))}",
		"mkdir-dangling-slash ${outcome(Path.create_dir!(Path.utf8("dangling/")))}",
		"copy-dir-link-slash ${raw(Fs.copy_dir_at!(root!(), abs!("dirlink/"), root!(), abs!("cd1")))}",
		"copy-dir-onto-dangling-slash ${raw(Fs.copy_dir_at!(root!(), abs!("private"), root!(), abs!("dangling/")))}",
		"copy-dir-onto-filelink-slash ${raw(Fs.copy_dir_at!(root!(), abs!("private"), root!(), abs!("filelink/")))}",
		"copy-dir-new-slash ${raw(Fs.copy_dir_at!(root!(), abs!("private"), root!(), abs!("cd2/")))}",
		"open-create-dir-slash ${raw(Fs.open_at!(root!(), abs!("adir/"), { write: True, create: True }))}",
		# create_all! follows the same directory-name rules as create_dir!.
		"mkdir-all-dangling-slash ${outcome(Path.create_all!(Path.utf8("dangling/")))}",
		"mkdir-all-filelink-slash ${outcome(Path.create_all!(Path.utf8("filelink/")))}",
		"mkdir-all-file-slash ${outcome(Path.create_all!(Path.utf8("keep.txt/")))}",
		# mkdir -p is idempotent, whatever the spelling.
		"mkdir-all-existing-slash ${outcome(Path.create_all!(Path.utf8("adir/")))}",
		"mkdir-all-dirlink-slash ${outcome(Path.create_all!(Path.utf8("dirlink/")))}",
		"mkdir-all-deep-again ${outcome(Path.create_all!(Path.utf8("adir/")))}",
		# A rename guard reports the stat's own error, not the spelling.
		"rename-unreadable-slash ${outcome(Path.rename!(Path.utf8("shut/d/"), Path.utf8("moved")))}",
		"rename-missing-slash ${outcome(Path.rename!(Path.utf8("gone/"), Path.utf8("moved")))}",
		# A named mode reaches the OS, masked by the umask (022 here).
		"open-mode ${raw(Fs.open_at!(root!(), abs!("private.txt"), { write: True, create: True, exclusive: True, mode: 0o600 }))}",
		"mkdir-mode ${raw(Fs.create_dir_at!(root!(), abs!("private-dir"), 0o700))}",
		# A directory descriptor has no byte stream.
		"read-dir-stream ${match Fs.open_at!(root!(), abs!("adir"), { directory: True }) {
			Ok(d) => raw(Fs.read_via_stream!(d))
			Err(_) => "open-failed"
		}}",
		# A name ending in `..` is its parent: removing one is refused on both,
		# and creating there answers for the directory that is already at it.
		"delete-all-dotdot ${outcome(Path.delete_all!(Path.utf8("adir/..")))}",
		"delete-empty-dotdot ${outcome(Path.delete_empty!(Path.utf8("adir/..")))}",
		"symlink-dotdot ${raw(Fs.symlink_at!(root!(), Str.to_utf8("keep.txt"), abs!("adir/..")))}",
		"write-dotdot ${outcome(Path.write_bytes!(Path.utf8("adir/.."), [1]))}",
		"symlink-missing-dotdot ${raw(Fs.symlink_at!(root!(), Str.to_utf8("keep.txt"), abs!("gone/..")))}",
		# The root itself, named without a slash.
		"root-write ${raw(Fs.write_file_at!(root!(), here!(), [1]))}",
		"root-copy-onto ${raw(Fs.copy_file_at!(root!(), abs!("keep.txt"), root!(), here!()))}",
		"root-symlink-at ${raw(Fs.symlink_at!(root!(), Str.to_utf8("keep.txt"), here!()))}",
		# A file's descriptor is not a directory to resolve paths against.
		"file-base ${match File.open_reader!(Path.utf8("keep.txt")) {
			Ok(reader) => raw(Fs.read_file_at!(reader.descriptor(), Str.to_utf8("keep.txt")))
			Err(_) => "open-failed"
		}}",
		# An empty path names nothing, through every layer: it named the cwd
		# (shim) or the descriptor's directory (raw).
		"read-empty ${outcome(Path.read_bytes!(Path.utf8("")))}",
		"write-empty ${outcome(Path.write_bytes!(Path.utf8(""), [1]))}",
		"list-empty ${outcome(Path.list!(Path.utf8("")))}",
		"type-empty ${kind!("")}",
		"raw-list-empty ${raw(Fs.read_dir_at!(root!(), []))}",
		"raw-stat-empty ${raw(Fs.stat_at!(root!(), [], { follow_symlinks: True }))}",
		"raw-open-dir-empty ${raw(Fs.open_at!(root!(), [], { directory: True }))}",
		"delete-all-empty ${outcome(Path.delete_all!(Path.utf8("")))}",
		# A recursive removal of a name ending in `.` is refused before it
		# deletes anything; it emptied the directory, through a link too.
		"delete-all-trailing-dot ${outcome(Path.delete_all!(Path.utf8("dottree/.")))}",
		"delete-all-dot-slash ${outcome(Path.delete_all!(Path.utf8("./dottree/./")))}",
		"delete-all-link-dot ${outcome(Path.delete_all!(Path.utf8("dotlink/.")))}",
		"delete-empty-trailing-dot ${outcome(Path.delete_empty!(Path.utf8("dotempty/.")))}",
		"delete-all-bare-dot ${outcome(Path.delete_all!(Path.utf8(".")))}",
	]
	Stdout.line!(Str.join_with(lines, "\n"))
}
