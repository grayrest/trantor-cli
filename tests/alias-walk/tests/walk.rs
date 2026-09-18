use alias_walk::alias::aliased_rest_by;
use std::path::{Path, PathBuf};

/// A filesystem where only `existing` paths canonicalize, each to itself
/// unless `alias` maps it elsewhere; it records every path it is asked about.
fn fake_fs<'a>(
    existing: &'a [&'a str],
    alias: (&'a str, &'a str),
    asked: &'a std::cell::RefCell<Vec<PathBuf>>,
) -> impl FnMut(&Path) -> std::io::Result<PathBuf> + 'a {
    move |p| {
        asked.borrow_mut().push(p.to_path_buf());
        let s = p.to_str().expect("test paths are UTF-8");
        if !existing.contains(&s) {
            return Err(std::io::Error::from(std::io::ErrorKind::NotFound));
        }
        Ok(PathBuf::from(if s == alias.0 { alias.1 } else { s }))
    }
}

#[test]
fn should_stop_at_the_first_prefix_that_does_not_exist() {
    let asked = std::cell::RefCell::new(Vec::new());
    let found = aliased_rest_by(
        Path::new("/out/missing/a/b/c/d"),
        Path::new("/private/tmp/root"),
        fake_fs(&["/", "/out"], ("", ""), &asked),
    );
    assert_eq!((found, asked.into_inner().len()), (None, 3));
}

#[test]
fn should_answer_the_rest_after_the_shortest_aliased_prefix() {
    let asked = std::cell::RefCell::new(Vec::new());
    let found = aliased_rest_by(
        Path::new("/tmp/root/sub/f"),
        Path::new("/private/tmp/root"),
        fake_fs(&["/", "/tmp", "/tmp/root", "/tmp/root/sub"], ("/tmp/root", "/private/tmp/root"), &asked),
    );
    assert_eq!(found, Some(PathBuf::from("sub/f")));
}
