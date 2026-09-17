app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Path
import pf.IOErr exposing [IOErr]
import pf.Fs

## One name and one spelling, given as arguments, against every operation: the
## outcomes the two filesystems must agree on. The script runs this once per
## pair against a freshly made tree, because these operations change what they
## name — `rm-r` then `open-create` turned every entry into a plain file, and
## the 936 rows that produced all said `NotADirectory`.
operations : List(Str)
operations = ["read", "write", "append", "stat", "stat-follow", "list", "mkdir", "mkdir-all", "rmdir", "rm-r", "unlink", "open", "open-create", "open-dir", "copy-from", "copy-to", "copy-dir-from", "copy-dir-to", "rename-from", "rename-to", "link-from", "link-to", "symlink-at", "readlink", "hash", "hash-follow"]

main! : List(OsStr) => Try({}, _)
main! = |args| {
	# The subject, and the directory it lives in: everything this makes or
	# names sits beside it, so `<name>/..` is inside the root on both worlds.
	(path, base) = match (List.get(args, 1), List.get(args, 2)) {
		(Ok(one), Ok(two)) => (OsStr.display(one), OsStr.display(two))
		_ => crash("the subject path and its directory are the arguments")
	}
	Stdout.line!(Str.join_with(for_operations!(path, base, operations, 0, []), "\n"))
}

for_operations! : Str, Str, List(Str), U64, List(Str) => List(Str)
for_operations! = |path, base, remaining, counter, done| match remaining {
	[] => done
	[operation, .. as rest] => {
		line = "${operation} ${path} ${run!(operation, path, base, counter)}"
		for_operations!(path, base, rest, counter + 1, List.append(done, line))
	}
}

## `fresh` names something that does not exist yet, for the operations that
## make one.
run! : Str, Str, Str, U64 => Str
run! = |operation, path, base, counter| {
	subject = Path.utf8(path)
	fresh = Path.utf8("${base}/made-${counter.to_str()}")
	match operation {
		"read" => outcome(Path.read_bytes!(subject))
		"write" => outcome(Path.write_bytes!(subject, [1]))
		"append" => outcome(Path.append_bytes!(subject, [1]))
		"stat" => kind(Path.type!(subject))
		"stat-follow" => outcome(Path.size_in_bytes!(subject))
		"list" => outcome(Path.list!(subject))
		"mkdir" => outcome(Path.create_dir!(subject))
		"mkdir-all" => outcome(Path.create_all!(subject))
		"rmdir" => outcome(Path.delete_empty!(subject))
		"rm-r" => outcome(Path.delete_all!(subject))
		"unlink" => outcome(Path.delete!(subject))
		"open" => raw(Fs.open_at!(root!(), absolute!(path), {}))
		"open-create" => raw(Fs.open_at!(root!(), absolute!(path), { write: True, create: True }))
		"open-dir" => raw(Fs.open_at!(root!(), absolute!(path), { directory: True }))
		"copy-from" => outcome(Path.copy!(subject, fresh))
		"copy-to" => outcome(Path.copy!(Path.utf8("${base}/afile"), subject))
		"copy-dir-from" => raw(Fs.copy_dir_at!(root!(), absolute!(path), root!(), absolute!("${base}/made-${counter.to_str()}")))
		"copy-dir-to" => raw(Fs.copy_dir_at!(root!(), absolute!("${base}/adir"), root!(), absolute!(path)))
		"rename-from" => outcome(Path.rename!(subject, fresh))
		"rename-to" => outcome(Path.rename!(Path.utf8("${base}/movable-${counter.to_str()}"), subject))
		"link-from" => outcome(Path.hard_link!(subject, fresh))
		"link-to" => outcome(Path.hard_link!(Path.utf8("${base}/afile"), subject))
		"symlink-at" => outcome(Path.sym_link!(Path.utf8("afile"), subject))
		"readlink" => outcome(Path.read_sym_link!(subject))
		"hash" => raw(Fs.metadata_hash_at!(root!(), absolute!(path), { follow_symlinks: False }))
		"hash-follow" => raw(Fs.metadata_hash_at!(root!(), absolute!(path), { follow_symlinks: True }))
		_ => "unknown-operation"
	}
}

absolute! : Str => List(U8)
absolute! = |name| Str.to_utf8("${Path.display(Env.cwd!() ?? Path.utf8("."))}/${name}")

root! : () => Fs.Descriptor
root! = || Fs.preopens!({}).first() ?? crash("no preopen")

## `Other`'s wording differs by OS and backend; its kind is the contract.
outcome : Try(a, [PathErr(IOErr), ..]) -> Str
outcome = |r| match r {
	Ok(_) => "ok"
	Err(PathErr(Other(_))) => "err:Other"
	Err(PathErr(e)) => "err:${Str.inspect(e)}"
	Err(_) => "err:other"
}

raw : Try(a, [Io(IOErr)]) -> Str
raw = |r| match r {
	Ok(_) => "ok"
	Err(Io(Other(_))) => "err:Other"
	Err(Io(e)) => "err:${Str.inspect(e)}"
}

kind : Try([IsFile, IsDir, IsSymLink, IsOther], [PathErr(IOErr), ..]) -> Str
kind = |r| match r {
	Ok(k) => Str.inspect(k)
	Err(PathErr(Other(_))) => "err:Other"
	Err(PathErr(e)) => "err:${Str.inspect(e)}"
	Err(_) => "err:other"
}
