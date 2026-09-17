app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Env
import pf.Path exposing [Path]
import pf.File
import pf.Fs
import pf.Utc

## Every filesystem operation the confined root must hold, each raced against
## the swapper flipping `sub` between a directory and a link to outside. Each
## reports what it saw: the inside file, the outside file, or a refusal. A write
## cannot see where it landed, so writes report Inside on success and the
## script checks the outside directory for anything they left there.
Seen : [Inside, Outside, Refused]

Tally : { inside : U64, outside : U64, refused : U64 }

content : Try(Str, _) -> Seen
content = |r| match r {
	Ok(s) => if Str.contains(s, "OUTSIDE") { Outside } else { Inside }
	Err(_) => Refused
}

succeeded : Try(_, _) -> Seen
succeeded = |r| match r {
	Ok(_) => Inside
	Err(_) => Refused
}

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

read_file! : U64 => Seen
read_file! = |_| content(Path.read_utf8!(Path.utf8("sub/secret.txt")))

open_reader! : U64 => Seen
open_reader! = |_| match File.open_reader!(Path.utf8("sub/secret.txt")) {
	Ok(r) => content(r.read_line!().map_ok(Str.from_utf8_lossy))
	Err(_) => Refused
}

dir_descriptor! : U64 => Seen
dir_descriptor! = |_| match Fs.open_at!(root!(), abs!("sub"), { directory: True }) {
	Ok(d) => content(Fs.read_file_at!(d, Str.to_utf8("secret.txt")).map_ok(Str.from_utf8_lossy))
	Err(_) => Refused
}

list! : U64 => Seen
list! = |_| match Path.list!(Path.utf8("sub")) {
	Ok(paths) => if List.any(paths, |p| Str.ends_with(Path.display(p), "outside-only.txt")) { Outside } else { Inside }
	Err(_) => Refused
}

read_link! : U64 => Seen
read_link! = |_| content(Path.read_sym_link!(Path.utf8("sub/lnk")).map_ok(Path.display))

copy_from! : U64 => Seen
copy_from! = |_| {
	copied = Path.utf8("copied.txt")
	_ = Path.delete!(copied)
	match Path.copy!(Path.utf8("sub/secret.txt"), copied) {
		Ok({}) => content(Path.read_utf8!(copied))
		Err(_) => Refused
	}
}

## A fresh name each time, and nothing deleted: a delete that escaped would
## clean up the evidence of a copy that escaped.
copy_to! : U64 => Seen
copy_to! = |n| succeeded(Path.copy!(Path.utf8("secret-root.txt"), Path.utf8("sub/copied-in-${n.to_str()}")))

append! : U64 => Seen
append! = |_| succeeded(Path.append_utf8!(Path.utf8("sub/appended.txt"), "x"))

writer! : U64 => Seen
writer! = |_| match File.open_writer!(Path.utf8("sub/written.txt")) {
	Ok(w) => succeeded(w.write_utf8!("x"))
	Err(_) => Refused
}

sym_link! : U64 => Seen
sym_link! = |n| succeeded(Path.sym_link!(Path.utf8("secret.txt"), Path.utf8("sub/made-link-${n.to_str()}")))

## A fresh directory each time; the script checks nothing appeared outside.
copy_dir! : U64 => Seen
copy_dir! = |n| succeeded(Fs.copy_dir_at!(root!(), abs!("private-src"), root!(), abs!("sub/dir-copy-${n.to_str()}")))

## A followed stat reports the size of what it reached: the inside secret is
## seven bytes, the outside one eight.
stat_followed! : U64 => Seen
stat_followed! = |_| match Fs.stat_at!(root!(), abs!("sub/secret.txt"), { follow_symlinks: True }) {
	Ok(s) => if s.size == 8 { Outside } else { Inside }
	Err(_) => Refused
}

ops : List((Str, (U64 => Seen)))
ops = [
	("read", read_file!),
	("open_reader", open_reader!),
	("dir_descriptor", dir_descriptor!),
	("list", list!),
	("read_sym_link", read_link!),
	("copy_from", copy_from!),
	("copy_to", copy_to!),
	("append", append!),
	("open_writer", writer!),
	("sym_link", sym_link!),
	("copy_dir", copy_dir!),
	("stat_followed", stat_followed!),
]

count : Tally, Seen -> Tally
count = |t, seen| match seen {
	Inside => { ..t, inside: t.inside + 1 }
	Outside => { ..t, outside: t.outside + 1 }
	Refused => { ..t, refused: t.refused + 1 }
}

## Every operation races at least this many times.
min_attempts : U64
min_attempts = 2000

## After those, keeps racing for up to this long until it has both succeeded
## and been refused. The swapper is a separate process: on a loaded machine
## (the suites run in parallel) it can sit in one state for a whole block of
## attempts. Measured with every core busy, 2000 appends succeeded as few as 17
## times, and one suite run saw 0. The budget is time, not attempts, because
## what it has to outlast is a stall: 20,000 attempts did not outlast a 1.5 s
## one. It starts once the minimum is done, so an op whose 2000 attempts are
## slow under load still gets the whole budget. More attempts only give an
## escape more chances to show, so the escape check is no weaker for it.
control_budget_nanos : U128
control_budget_nanos = 10_000_000_000

## `op!` raced `min_attempts` times, then until both controls are nonzero or
## the budget runs out. Attempts are numbered from 1 so the ops that name files
## by attempt never reuse a name. `deadline` is `NotStarted` during the
## minimum.
race! : (U64 => Seen), U64, Tally, [NotStarted, At(U128)] => { tally : Tally, attempts : U64 }
race! = |op!, done, t, deadline| {
	controls_seen = t.inside > 0 and t.refused > 0
	if done < min_attempts {
		race!(op!, done + 1, count(t, op!(done + 1)), deadline)
	} else if controls_seen {
		{ tally: t, attempts: done }
	} else {
		match deadline {
			NotStarted => race!(op!, done, t, At(Utc.now!() + control_budget_nanos))
			At(end) =>
				if out_of_time!(end) {
					{ tally: t, attempts: done }
				} else {
					race!(op!, done + 1, count(t, op!(done + 1)), deadline)
				}
		}
	}
}

## `Utc.now!` reads 0 when the host clock fails; that ends the budget rather
## than extending it forever.
out_of_time! : U128 => Bool
out_of_time! = |end| {
	now = Utc.now!()
	now == 0 or now >= end
}

race_all! : List((Str, (U64 => Seen))), List(Str) => List(Str)
race_all! = |pending, done| match pending {
	[] => done
	[(name, op!), .. as rest] => {
		{ tally: t, attempts } = race!(op!, 0, { inside: 0, outside: 0, refused: 0 }, NotStarted)
		race_all!(rest, List.append(done, "${name} ${Str.inspect(t.inside)} ${Str.inspect(t.outside)} ${Str.inspect(t.refused)} ${Str.inspect(attempts)}"))
	}
}

## Under confinement a link is made only to something inside the root: an
## absolute or relative target outside it, and a dangling one, are refused at
## creation, and a link to a file inside is made and followed.
planted! : Str, Str => Str
planted! = |outside, outside_relative| {
	made! = |target, name| match Path.sym_link!(Path.utf8(target), Path.utf8(name)) {
		Ok({}) => "made"
		Err(_) => "refused"
	}
	absolute = made!("${outside}/secret.txt", "planted-abs")
	relative = made!("${outside_relative}/secret.txt", "planted-rel")
	dangling = made!("no-such-file", "planted-dangling")
	inside = made!("secret-root.txt", "planted-inside")
	followed = match content(Path.read_utf8!(Path.utf8("planted-inside"))) {
		Inside => "inside"
		Outside => "ESCAPED"
		Refused => "unreadable"
	}
	# A link that is valid where it was made, re-aimed by moving it: `a/l -> ..`
	# is the root, `l -> ..` would be its parent.
	moved = match Path.create_dir!(Path.utf8("a")) {
		Ok({}) => match made!("..", "a/l") {
			"made" => match Path.rename!(Path.utf8("a/l"), Path.utf8("l")) {
				Ok({}) => "MOVED"
				Err(_) => match Path.hard_link!(Path.utf8("a/l"), Path.utf8("l2")) {
					Ok({}) => "LINKED"
					Err(_) => "refused"
				}
			}
			_ => "notmade"
		}
		Err(_) => "nodir"
	}
	# A failed copy leaves nothing behind to make the retry AlreadyExists.
	copy_dir = match Path.copy!(Path.utf8("a"), Path.utf8("copied-dir")) {
		Ok({}) => "copied"
		Err(_) => match Path.exists!(Path.utf8("copied-dir")) {
			Ok(False) => "clean"
			_ => "LEFT"
		}
	}
	# Moves that cannot re-aim a link pass (D-S2-24): an absolute link and a
	# dangling one renamed in place, and a relative link moved to a directory
	# where its target still exists. A dangling one moved elsewhere does not.
	allowed = [
		Path.rename!(Path.utf8("abs-link"), Path.utf8("abs-link2")),
		Path.rename!(Path.utf8("dangling"), Path.utf8("dangling2")),
		Path.rename!(Path.utf8("m1/rel"), Path.utf8("m2/rel")),
	]
	allowed_all = if List.all(allowed, |r| Try.is_ok(r)) { "allowed" } else { "REFUSED" }
	dangling_moved = match Path.rename!(Path.utf8("dangling2"), Path.utf8("m1/dangling")) {
		Ok({}) => "MOVED"
		Err(PathErr(PermissionDenied)) => "denied"
		Err(_) => "other"
	}
	"${absolute},${relative},${dangling},${inside},${followed},${moved},${copy_dir},${allowed_all},${dangling_moved}"
}

main! : List(OsStr) => Try({}, _)
main! = |args| {
	outside = List.get(args, 1).map_ok(OsStr.display) ?? ""
	outside_relative = List.get(args, 2).map_ok(OsStr.display) ?? ""
	lines = race_all!(ops, [])
	Stdout.line!(Str.join_with(List.append(lines, "planted ${planted!(outside, outside_relative)}"), "\n"))
}
