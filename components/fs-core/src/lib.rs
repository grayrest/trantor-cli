//! fs-core (P9 shared substrate, rlib, NO no_mangle): the roc:filesystem op
//! bodies, the root policy, and the `exports!` macro that a thin staticlib
//! (fs-unconfined / fs-confined) invokes to emit its hosted symbols under
//! its own prefix. Capability model (P4): every op is relative to a Descriptor;
//! the ONLY policy difference between the two components is `Root`.
//!
//! Owned-argument rule (B0): every hosted fn releases its Descriptor via
//! `resource::with` and `.decref`s every list arg.
use core::mem::ManuallyDrop;
use trantor_abi as abi;
use abi::*;
// The fs macro expands in fs-unconfined/fs-confined and names these through
// $crate, so they have to be public here.
pub use abi::{RocBox, RocList};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

pub use paste;

mod copy;

/// The one policy knob: where the preopen points, and whether escapes are
/// refused. Build it with `Root::unconfined` or `Root::confined`.
pub struct Root {
    pub base: PathBuf,
    /// `Some` for a confined root: a directory HANDLE on `base`, not a string.
    beneath: Option<cap_std::fs::Dir>,
}

impl Root {
    /// Ambient authority over `base` — absolute paths anywhere are fine.
    pub fn unconfined(base: PathBuf) -> Self {
        Root { base, beneath: None }
    }

    /// Nothing outside `base`, enforced at the moment each path is used.
    ///
    /// This used to be a string check: canonicalize the candidate, test
    /// `starts_with(base)`, then hand the ORIGINAL path to `std::fs`. Check and
    /// use resolved the path twice, and anything that could swap a directory
    /// component for a symlink between the two escaped. Measured with a
    /// swapper flipping `sub` between a real directory and a link to outside,
    /// against 20,000 reads of `sub/secret.txt` per run: 192, 970 and 323 of
    /// them returned the OUTSIDE file's contents.
    ///
    /// The tempting fix — hand the canonical path to the syscall instead —
    /// breaks every operation that must act on a link rather than its target:
    /// measured, `delete!` on a symlink then deleted the file it pointed at.
    pub fn confined(base: PathBuf) -> Self {
        let dir = cap_std::fs::Dir::open_ambient_dir(&base, cap_std::ambient_authority())
            .expect("open the confined root");
        Root { base, beneath: Some(dir) }
    }
}

/// The Descriptor resource payload.
pub enum Desc {
    Dir(PathBuf),
    File(std::fs::File),
}

/// The directory a descriptor resolves paths against. A file has none: it used
/// to answer `.`, so an `*_at!` call given a `File.Writer`'s descriptor read
/// and wrote relative to the process cwd, not even the userland one.
fn dir_of(d: &Desc) -> std::io::Result<PathBuf> {
    match d {
        Desc::Dir(p) => Ok(p.clone()),
        Desc::File(_) => Err(std::io::Error::new(std::io::ErrorKind::NotADirectory, "a file descriptor is not a directory to resolve paths against")),
    }
}

/// What a resolved path is, and so how an operation must act on it.
pub enum Target<'a> {
    /// Unconfined: an ambient path for `std::fs`.
    Ambient(PathBuf),
    /// Confined: a path RELATIVE to the root handle, for cap-std. Never
    /// absolute and never resolved here — cap-std walks it from the fd.
    Beneath(&'a cap_std::fs::Dir, PathBuf),
}

/// The path FsOps sends is absolute (it joins the userland cwd). cap-std wants
/// one relative to the root handle. This only has to produce a plausible
/// relative path: it is NOT the confinement. A wrong answer here resolves to
/// something inside the root or fails in cap-std — it cannot escape, because
/// cap-std refuses `..` past the handle, absolute components, and symlinks
/// that leave it, all at use time.
fn relative_to_root(base: &Path, cand: &Path) -> std::io::Result<PathBuf> {
    let outside = || std::io::Error::new(std::io::ErrorKind::PermissionDenied, "outside preopen");
    let rel = match cand.strip_prefix(base) {
        Ok(r) => r.to_path_buf(),
        Err(_) => {
            // The same directory under another spelling (/tmp vs /private/tmp).
            // Canonicalizing only the base missed the other direction: a root
            // at /private/tmp/x refused `/tmp/x/f`, which names a file inside.
            let cb = base.canonicalize()?;
            match cand.strip_prefix(&cb) {
                Ok(r) => r.to_path_buf(),
                Err(_) => ancestor_resolved(cand).as_deref().and_then(|p| p.strip_prefix(&cb).ok()).map(Path::to_path_buf).ok_or_else(outside)?,
            }
        }
    };
    let rel = if rel.as_os_str().is_empty() { PathBuf::from(".") } else { rel };
    // strip_prefix rebuilds the path from components, dropping a trailing `/`
    // or `/.`, and each changes what the kernel does: `out/` and `out/.` must
    // be directories, `out` need not be. Measured, `keep.txt/.` confined wrote
    // over `keep.txt` where the kernel answers NotADirectory. Put it back, so
    // both backends act on the same name.
    let mut spelled = rel.into_os_string();
    spelled.push(trailing_spelling(cand.as_os_str().as_bytes()));
    Ok(PathBuf::from(spelled))
}

/// `cand` with its deepest existing PROPER ancestor canonicalized and the rest
/// reattached as spelled, or `None` if no ancestor resolves.
///
/// The last component is never resolved: the operation may create it, and a
/// symlink there must stay the link (canonicalizing it made `delete!` act on
/// the target). What follows the ancestor is not resolved either, `..`
/// included: it goes to cap-std as spelled, which walks it from the root handle
/// and refuses it if it leaves. Resolving it lexically here could turn a path
/// that climbs out through a link into one that looks inside.
fn ancestor_resolved(cand: &Path) -> Option<PathBuf> {
    let parts: Vec<std::path::Component> = cand.components().collect();
    (1..parts.len()).rev().find_map(|k| {
        let ancestor: PathBuf = parts[..k].iter().collect();
        let mut resolved = ancestor.canonicalize().ok()?;
        resolved.extend(&parts[k..]);
        Some(resolved)
    })
}

/// The tail components rebuilding drops: `/.` if the path ends in a `.`
/// component (the kernel treats `a/./` like `a/.`), `/` if it ends in a slash,
/// otherwise nothing.
fn trailing_spelling(path: &[u8]) -> &'static str {
    let mut rest = path;
    let mut dot = false;
    let mut slash = false;
    loop {
        if let Some(r) = rest.strip_suffix(b"/") {
            slash = true;
            rest = r;
        } else if let Some(r) = rest.strip_suffix(b"/.") {
            dot = true;
            rest = r;
        } else {
            break;
        }
    }
    if dot { "/." } else if slash { "/" } else { "" }
}

/// A path ending in `/` or `/.` names a directory, whatever its last real
/// component is.
/// Whether the last component is `..`, however it is spelled. A trailing `.`
/// is not included: it names the directory the path already names, which
/// `names_directory` handles, and a bare `.` is how the root itself is spelled
/// beneath the root.
fn ends_in_parent(p: &Path) -> bool {
    let mut b = p.as_os_str().as_bytes();
    while let Some(rest) = b.strip_suffix(b"/") {
        b = rest;
    }
    b.ends_with(b"/..")
}

/// A bare `.` (the root itself, beneath it) is not included: the plain path
/// for the same name has no trailing spelling, so the OS's answer stands on
/// both backends.
pub(crate) fn names_directory(p: &Path) -> bool {
    let b = p.as_os_str().as_bytes();
    b.ends_with(b"/") || b.ends_with(b"/.")
}

/// `p` without the trailing slashes, when it ends in slashes and not `/.`, so
/// an operation acts on the name itself and a no-follow flag applies to it.
/// `None` for any other spelling.
pub(crate) fn slashes_stripped(p: &Path) -> Option<PathBuf> {
    let b = p.as_os_str().as_bytes();
    let trimmed = b.strip_suffix(b"/")?;
    let mut end = trimmed.len();
    while end > 0 && trimmed[end - 1] == b'/' {
        end -= 1;
    }
    let name = &trimmed[..end];
    if name.is_empty() || name.ends_with(b"/.") || name == b"." || name.ends_with(b"/..") || name == b".." {
        return None;
    }
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(name)))
}

impl<'a> Target<'a> {
    /// The same target under another path on the same backend.
    pub(crate) fn with_path(&self, p: PathBuf) -> Target<'a> {
        match self {
            Target::Ambient(_) => Target::Ambient(p),
            Target::Beneath(h, _) => Target::Beneath(h, p),
        }
    }
    pub(crate) fn path(&self) -> &Path {
        match self {
            Target::Ambient(p) => p,
            Target::Beneath(_, p) => p,
        }
    }
}

/// Resolve `rel` (raw bytes) against a directory descriptor under the root
/// policy.
///
/// An empty path names nothing. `dir.join("")` is `dir` itself, so an empty
/// path used to act on the directory: `Path.delete_all!(Path.utf8(""))` removed
/// the working directory (confined: emptied the root), and `read_dir_at!(root,
/// [])` listed `/`. The kernel answers ENOENT for "", and so does this, on
/// both backends and for every operation.
pub fn resolve<'a>(root: &'a Root, dir: &Path, rel: &[u8]) -> std::io::Result<Target<'a>> {
    if rel.is_empty() {
        return Err(std::io::Error::new(std::io::ErrorKind::NotFound, "an empty path names nothing"));
    }
    let p = Path::new(std::ffi::OsStr::from_bytes(rel));
    let cand = if p.is_absolute() { p.to_path_buf() } else { dir.join(p) };
    match &root.beneath {
        None => Ok(Target::Ambient(cand)),
        Some(d) => Ok(Target::Beneath(d, relative_to_root(&root.base, &cand)?)),
    }
}

// ---- error twins (glue emits one IOErr per reach path; both are the same 10 variants) ----
macro_rules! ioerr_ctor {
    ($name:ident, $ty:ident, $pl:ident, $tag:ident) => {
        pub fn $name(e: &std::io::Error) -> $ty {
            let tag = sync_io_core::ioerr_tag!(e, $tag);
            if let $tag::Other = tag {
                $ty { payload: $pl { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag }
            } else {
                $ty { payload: unsafe { core::mem::zeroed() }, tag }
            }
        }
    };
}
ioerr_ctor!(ioerr, IOErr, IOErrPayload, IOErrTag);
ioerr_ctor!(fs_ioerr, FsIOErr, FsIOErrPayload, FsIOErrTag);

fn bytes(l: &RocListWith<u8, false>) -> Vec<u8> {
    l.as_slice().to_vec()
}

// ---- op bodies ----
pub mod ops {
    use super::*;

    /// `Fs.preopens! : {} => List(Descriptor)`. One root today; a list because
    /// that is the shape wasi:filesystem/preopens has and the shape a second
    /// preopen would need.
    pub fn preopens(r: &Root) -> RocList<RocBox> {
        let h = abi::host();
        let items = [abi::resource::new(Desc::Dir(r.base.clone()))];
        unsafe { RocList::from_slice(&items, h) }
    }

    /// `Fs.OpenFlags`; its glue name is a hash of the record shape.
    pub type OpenFlags = AnonStructA38ac8acc52dafef;

    /// A directory descriptor names its directory by path, as a preopen does,
    /// so the `*_at!` operations resolve against it under the same root policy.
    /// The open itself is what proves it is a directory reachable from here.
    fn open_dir(r: &Root, tg: Target, follow: bool) -> std::io::Result<Desc> {
        use std::os::unix::fs::OpenOptionsExt;
        match tg {
            Target::Ambient(p) => {
                let nofollow = if follow { 0 } else { libc::O_NOFOLLOW };
                std::fs::OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY | nofollow).open(&p)?;
                Ok(Desc::Dir(p))
            }
            Target::Beneath(h, p) => {
                if follow { h.open_dir(&p)?; } else { cap_fs_ext::DirExt::open_dir_nofollow(h, &p)?; }
                Ok(Desc::Dir(r.base.join(p)))
            }
        }
    }

    fn open_file(tg: Target, f: &OpenFlags) -> std::io::Result<Desc> {
        match tg {
            Target::Ambient(p) => {
                use std::os::unix::fs::OpenOptionsExt;
                let mut o = std::fs::OpenOptions::new();
                o.read(f.read).write(f.write).truncate(f.truncate).append(f.append).mode(f.mode);
                if f.exclusive { o.create_new(true); } else { o.create(f.create); }
                if !f.follow_symlinks { o.custom_flags(libc::O_NOFOLLOW); }
                o.open(p).map(Desc::File)
            }
            Target::Beneath(h, p) => {
                use cap_fs_ext::{FollowSymlinks, OpenOptionsFollowExt};
                use cap_std::fs::OpenOptionsExt as ModeExt;
                let mut o = cap_std::fs::OpenOptions::new();
                o.read(f.read).write(f.write).truncate(f.truncate).append(f.append);
                ModeExt::mode(&mut o, f.mode);
                if f.exclusive { o.create_new(true); } else { o.create(f.create); }
                if !f.follow_symlinks { o.follow(FollowSymlinks::No); }
                h.open_with(p, &o).map(|f| Desc::File(f.into_std()))
            }
        }
    }

    /// Creating a file at a directory name answers `NotFound` from the kernel
    /// and `Other(EINVAL)` from cap-std; both answer this instead.
    fn open_non_directory(tg: Target, f: &OpenFlags) -> std::io::Result<Desc> {
        if (f.create || f.exclusive) && names_directory(tg.path()) {
            // What the kernel says for an existing directory, with or without
            // the slash.
            return Err(if metadata_followed(&tg).is_ok_and(|m| m.0) { is_a_directory_name() } else { directory_name() });
        }
        open_file(tg, f)
    }

    fn is_a_directory_name() -> std::io::Error {
        std::io::Error::new(std::io::ErrorKind::IsADirectory, "a file cannot be created over a directory")
    }

    pub fn open_with_flags_at(r: &Root, d: *mut u64, path: RocListWith<u8, false>, flags: OpenFlags) -> FsOpenWithFlagsAtResult {
        let res = with_path(r, d, path, |tg| if flags.directory { open_dir(r, tg, flags.follow_symlinks) } else { open_non_directory(tg, &flags) });
        match res {
            Ok(desc) => FsOpenWithFlagsAtResult { payload: FsOpenWithFlagsAtResultPayload { ok: ManuallyDrop::new(abi::resource::new(desc) as *mut u64) }, tag: FsOpenWithFlagsAtResultTag::Ok },
            Err(e) => FsOpenWithFlagsAtResult { payload: FsOpenWithFlagsAtResultPayload { err: ManuallyDrop::new(fs_ioerr(&e)) }, tag: FsOpenWithFlagsAtResultTag::Err },
        }
    }

    /// The stream owns a duplicate of the descriptor's open file, so a failed
    /// clone (no fds left) is this call's error: it used to mint a stream whose
    /// first read answered it, blaming the read for the open's failure.
    pub fn read_via_stream(_r: &Root, d: *mut u64) -> FsReadViaStreamResult {
        use std::os::fd::AsRawFd;
        match cloned_file(d) {
            Ok(f) => {
                let fd = f.as_raw_fd();
                FsReadViaStreamResult { payload: FsReadViaStreamResultPayload { ok: ManuallyDrop::new(sync_io_core::input_stream_fd(Box::new(f), fd) as *mut u64) }, tag: FsReadViaStreamResultTag::Ok }
            }
            Err(e) => FsReadViaStreamResult { payload: FsReadViaStreamResultPayload { err: ManuallyDrop::new(ioerr(&e)) }, tag: FsReadViaStreamResultTag::Err },
        }
    }

    fn is_a_directory() -> std::io::Error {
        std::io::Error::new(std::io::ErrorKind::IsADirectory, "a directory descriptor has no byte stream")
    }

    /// A second handle on the descriptor's open file, for a stream to own: the
    /// stream outlives the hosted call, the borrowed descriptor does not.
    fn cloned_file(d: *mut u64) -> std::io::Result<std::fs::File> {
        unsafe {
            abi::resource::with(d as RocBox, |x: &mut Desc| match x {
                Desc::File(f) => f.try_clone(),
                Desc::Dir(_) => Err(is_a_directory()),
            })
        }
    }

    /// `None` for a stream whose writes a child handed its fd would not
    /// reproduce, so `FdHandoff` answers `NotAFile` for it.
    fn stream_result(res: std::io::Result<(Box<dyn std::io::Write>, Option<std::os::fd::RawFd>)>) -> FsWriteViaStreamResult {
        match res {
            Ok((w, Some(fd))) => FsWriteViaStreamResult { payload: FsWriteViaStreamResultPayload { ok: ManuallyDrop::new(sync_io_core::output_stream_fd(w, fd) as *mut u64) }, tag: FsWriteViaStreamResultTag::Ok },
            Ok((w, None)) => FsWriteViaStreamResult { payload: FsWriteViaStreamResultPayload { ok: ManuallyDrop::new(sync_io_core::output_stream(w) as *mut u64) }, tag: FsWriteViaStreamResultTag::Ok },
            Err(e) => FsWriteViaStreamResult { payload: FsWriteViaStreamResultPayload { err: ManuallyDrop::new(ioerr(&e)) }, tag: FsWriteViaStreamResultTag::Err },
        }
    }

    /// Writes move the open file's cursor, which every stream on the descriptor
    /// and any child handed it share; `offset` sets it once (D-S2-23). A private
    /// `pwrite` offset let a child handed the descriptor (`FdHandoff`) write at
    /// offset 0, over what the stream had written.
    pub fn write_via_stream(_r: &Root, d: *mut u64, offset: u64) -> FsWriteViaStreamResult {
        use std::os::fd::AsRawFd;
        stream_result(cloned_file(d).and_then(|mut file| {
            use std::io::Seek;
            // A pipe, FIFO or terminal has no position to set (D-S2-23).
            match file.seek(std::io::SeekFrom::Start(offset)) {
                Err(e) if e.raw_os_error() == Some(libc::ESPIPE) => {}
                other => { other?; }
            }
            let fd = file.as_raw_fd();
            Ok((Box::new(file) as Box<dyn std::io::Write>, Some(fd)))
        }))
    }

    /// Moves the shared cursor to the end before each write, for a descriptor
    /// not opened in append mode.
    struct EndWriter(std::fs::File);
    impl std::io::Write for EndWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            use std::io::Seek;
            // A pipe has no position: every write already lands at the end.
            match self.0.seek(std::io::SeekFrom::End(0)) {
                Err(e) if e.raw_os_error() == Some(libc::ESPIPE) => {}
                other => { other?; }
            }
            self.0.write(buf)
        }
        fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
    }

    /// A descriptor opened with `append: True` already puts every write at the
    /// end, atomically. Any other gets a seek to the end per write. This used
    /// to set `O_APPEND` on the clone, which shares the descriptor's open file:
    /// the descriptor, later offset streams and any child handed it all turned
    /// append-only for good (D-S2-27).
    pub fn append_via_stream(_r: &Root, d: *mut u64) -> FsWriteViaStreamResult {
        use std::os::fd::AsRawFd;
        stream_result(cloned_file(d).and_then(|file| {
            let fd = file.as_raw_fd();
            // SAFETY: F_GETFL on a descriptor this function owns for the call.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags < 0 {
                return Err(std::io::Error::last_os_error());
            }
            // A seek-to-end stream records no fd: a child writing to that fd
            // writes at the shared cursor, not the end (D-S2-31).
            if flags & libc::O_APPEND != 0 { Ok((Box::new(file) as Box<dyn std::io::Write>, Some(fd))) } else { Ok((Box::new(EndWriter(file)) as Box<dyn std::io::Write>, None)) }
        }))
    }

    /// A path ending in `/` or `/.` names a directory. Creating a file, link
    /// or copy there, or renaming a non-directory to or from such a name, is
    /// refused here on both backends: the kernel answers `NotFound` for some of
    /// these and cap-std `InvalidInput` for one and success for another.
    fn directory_name() -> std::io::Error {
        std::io::Error::new(std::io::ErrorKind::NotADirectory, "a path ending in / names a directory")
    }
    fn refuse_directory_name(tg: &Target) -> std::io::Result<()> {
        // `x/..` names an existing directory, so creating there is EEXIST to
        // the kernel; cap-std answered NotFound. Whichever it is, both say the
        // same thing: what the name leads to, or why it cannot be reached.
        if ends_in_parent(tg.path()) {
            return Err(match metadata_followed(tg) {
                Ok(_) => std::io::Error::new(std::io::ErrorKind::AlreadyExists, "a directory is already at that name"),
                Err(e) => e,
            });
        }
        if names_directory(tg.path()) { Err(directory_name()) } else { Ok(()) }
    }

    fn with_path<T>(r: &Root, d: *mut u64, path: RocListWith<u8, false>, f: impl FnOnce(Target) -> std::io::Result<T>) -> std::io::Result<T> {
        let rel = bytes(&path); unsafe { path.decref(abi::host()) };
        let dir = unsafe { abi::resource::with(d as RocBox, |x: &mut Desc| dir_of(x)) }?;
        resolve(r, &dir, &rel).and_then(f)
    }

    pub fn read_file_at(r: &Root, d: *mut u64, path: RocListWith<u8, false>) -> FsReadFileAtResult {
        match with_path(r, d, path, |tg| match tg {
            Target::Ambient(p) => std::fs::read(p),
            Target::Beneath(h, p) => h.read(p),
        }) {
            Ok(v) => FsReadFileAtResult { payload: FsReadFileAtResultPayload { ok: ManuallyDrop::new(unsafe { RocListWith::<u8, false>::from_slice(&v, abi::host()) }) }, tag: FsReadFileAtResultTag::Ok },
            Err(e) => FsReadFileAtResult { payload: FsReadFileAtResultPayload { err: ManuallyDrop::new(ioerr(&e)) }, tag: FsReadFileAtResultTag::Err },
        }
    }

    fn unit(res: std::io::Result<()>) -> FsWriteFileAtResult {
        match res {
            Ok(()) => FsWriteFileAtResult { payload: FsWriteFileAtResultPayload { ok: [] }, tag: FsWriteFileAtResultTag::Ok },
            Err(e) => FsWriteFileAtResult { payload: FsWriteFileAtResultPayload { err: ManuallyDrop::new(ioerr(&e)) }, tag: FsWriteFileAtResultTag::Err },
        }
    }
    fn dir_unit(res: std::io::Result<()>) -> FsCreateDirAtResult {
        match res {
            Ok(()) => FsCreateDirAtResult { payload: FsCreateDirAtResultPayload { ok: [] }, tag: FsCreateDirAtResultTag::Ok },
            Err(e) => FsCreateDirAtResult { payload: FsCreateDirAtResultPayload { err: ManuallyDrop::new(ioerr(&e)) }, tag: FsCreateDirAtResultTag::Err },
        }
    }

    pub fn write_file_at(r: &Root, d: *mut u64, path: RocListWith<u8, false>, data: RocListWith<u8, false>) -> FsWriteFileAtResult {
        let v = bytes(&data); unsafe { data.decref(abi::host()) };
        unit(with_path(r, d, path, |tg| {
            refuse_directory_name(&tg)?;
            match tg {
                Target::Ambient(p) => std::fs::write(p, &v),
                Target::Beneath(h, p) => h.write(p, &v),
            }
        }))
    }

    /// The `stat_at!` record; its glue name is a hash of the record shape.
    type StatRec = AnonStruct14a365fc424c6e1f;
    fn epoch_ns(t: std::io::Result<std::time::SystemTime>) -> u128 {
        t.ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_nanos()).unwrap_or(0)
    }

    /// The fields `stat_at!` reports, read out of whichever Metadata type the
    /// backend returned (std's and cap-std's are distinct types).
    struct Stat { kind: DirOrFileOrOtherOrSymLink, size: u64, mode: u32, readonly: bool, accessed: u128, modified: u128, created: u128 }

    fn kind_of(is_dir: bool, is_file: bool, is_symlink: bool) -> DirOrFileOrOtherOrSymLink {
        if is_dir { DirOrFileOrOtherOrSymLink::Dir }
        else if is_file { DirOrFileOrOtherOrSymLink::File }
        else if is_symlink { DirOrFileOrOtherOrSymLink::SymLink }
        else { DirOrFileOrOtherOrSymLink::Other }
    }

    /// (is a directory, mode), following links.
    pub(crate) fn metadata_followed(tg: &Target) -> std::io::Result<(bool, u32)> {
        match tg {
            Target::Ambient(p) => std::fs::metadata(p).map(|m| (m.is_dir(), m.permissions().mode())),
            Target::Beneath(h, p) => h.metadata(p).map(|m| (m.is_dir(), cap_std::fs::PermissionsExt::mode(&m.permissions()))),
        }
    }

    /// (is a directory, mode) as `beneath_lstat` sees it: a link is a link,
    /// unless the name ends in `/` or `/.`, on both backends.
    pub(crate) fn metadata_as_named(tg: &Target) -> std::io::Result<(bool, u32)> {
        match tg {
            Target::Ambient(p) => std::fs::symlink_metadata(p).map(|m| (m.is_dir(), m.permissions().mode())),
            Target::Beneath(h, p) => beneath_lstat(h, p).map(|m| (m.is_dir(), cap_std::fs::PermissionsExt::mode(&m.permissions()))),
        }
    }

    /// Metadata that reports a link as a link, except where the name ends in
    /// `/` or `/.`: the kernel's `lstat` follows a link there, and cap-std's
    /// `symlink_metadata` answers `NotADirectory`, so beneath the root that
    /// spelling follows explicitly. The follow is still resolved by cap-std.
    pub(crate) fn beneath_lstat(h: &cap_std::fs::Dir, p: &Path) -> std::io::Result<cap_std::fs::Metadata> {
        if names_directory(p) { h.metadata(p) } else { h.symlink_metadata(p) }
    }

    /// Without `follow`, `symlink_metadata` on both backends: a link reports as
    /// a link.
    fn stat_of(tg: Target, follow: bool) -> std::io::Result<Stat> {
        match tg {
            Target::Ambient(p) => {
                let m = if follow { std::fs::metadata(p) } else { std::fs::symlink_metadata(p) }?;
                let ft = m.file_type();
                Ok(Stat {
                    kind: kind_of(ft.is_dir(), ft.is_file(), ft.is_symlink()),
                    size: m.len(),
                    mode: m.permissions().mode(),
                    readonly: m.permissions().readonly(),
                    accessed: epoch_ns(m.accessed()),
                    modified: epoch_ns(m.modified()),
                    created: epoch_ns(m.created()),
                })
            }
            Target::Beneath(h, p) => {
                let m = if follow { h.metadata(&p) } else { beneath_lstat(h, &p) }?;
                let ft = m.file_type();
                Ok(Stat {
                    kind: kind_of(ft.is_dir(), ft.is_file(), ft.is_symlink()),
                    size: m.len(),
                    mode: cap_std::fs::PermissionsExt::mode(&m.permissions()),
                    readonly: m.permissions().readonly(),
                    accessed: epoch_ns(m.accessed().map(|t| t.into_std())),
                    modified: epoch_ns(m.modified().map(|t| t.into_std())),
                    created: epoch_ns(m.created().map(|t| t.into_std())),
                })
            }
        }
    }

    /// `metadata_hash_at!`'s and `stat_at!`'s flags record, and the hash
    /// result; glue names them by shape.
    pub type HashFlags = AnonStructA87cda150656e1c4;
    type HashValue = AnonStruct9ddd559897dcea60;

    /// WASI's `metadata-hash-at`: equal for two paths exactly when they are the
    /// same object, without handing out device and inode numbers (D-S2-25).
    /// Two SipHash passes over (device, inode) with fixed keys, so it is stable
    /// for the life of the process.
    pub fn metadata_hash_at(r: &Root, d: *mut u64, path: RocListWith<u8, false>, flags: HashFlags) -> FsMetadataHashAtResult {
        let identity = with_path(r, d, path, |tg| match tg {
            Target::Ambient(p) => {
                use std::os::unix::fs::MetadataExt;
                let m = if flags.follow_symlinks { std::fs::metadata(p) } else { std::fs::symlink_metadata(p) }?;
                Ok((m.dev(), m.ino()))
            }
            Target::Beneath(h, p) => {
                use cap_std::fs::MetadataExt;
                let m = if flags.follow_symlinks { h.metadata(p) } else { beneath_lstat(h, &p) }?;
                Ok((m.dev(), m.ino()))
            }
        });
        match identity {
            Ok(id) => {
                let half = |salt: u64| {
                    use std::hash::{Hash, Hasher};
                    let mut hasher = std::hash::DefaultHasher::new();
                    (id, salt).hash(&mut hasher);
                    hasher.finish()
                };
                FsMetadataHashAtResult { payload: FsMetadataHashAtResultPayload { ok: ManuallyDrop::new(HashValue { lower: half(0), upper: half(1) }) }, tag: FsMetadataHashAtResultTag::Ok }
            }
            Err(e) => FsMetadataHashAtResult { payload: FsMetadataHashAtResultPayload { err: ManuallyDrop::new(ioerr(&e)) }, tag: FsMetadataHashAtResultTag::Err },
        }
    }

    pub fn stat_at(r: &Root, d: *mut u64, path: RocListWith<u8, false>, flags: HashFlags) -> FsStatAtResult {
        match with_path(r, d, path, |tg| stat_of(tg, flags.follow_symlinks)) {
            Ok(s) => {
                let rec = StatRec {
                    accessed_ns: s.accessed,
                    modified_ns: s.modified,
                    created_ns: s.created,
                    size: s.size,
                    executable: s.mode & 0o111 != 0,
                    kind: s.kind,
                    readable: s.mode & 0o444 != 0,
                    writable: !s.readonly,
                };
                FsStatAtResult { payload: FsStatAtResultPayload { ok: ManuallyDrop::new(rec) }, tag: FsStatAtResultTag::Ok }
            }
            Err(e) => FsStatAtResult { payload: FsStatAtResultPayload { err: ManuallyDrop::new(ioerr(&e)) }, tag: FsStatAtResultTag::Err },
        }
    }

    /// `read_dir_at!`'s entry record; its glue name is a hash of the shape.
    type EntryRec = AnonStructDa53049d8805a639;

    /// `file_type()` on a directory entry does not follow a symlink on either
    /// backend, so a link reports as a link.
    pub fn read_dir_at(r: &Root, d: *mut u64, path: RocListWith<u8, false>) -> FsReadDirAtResult {
        let res = with_path(r, d, path, |tg| {
            let mut entries: Vec<(Vec<u8>, DirOrFileOrOtherOrSymLink)> = match tg {
                Target::Ambient(p) => std::fs::read_dir(p)?
                    .map(|e| e.and_then(|e| e.file_type().map(|t| (e.file_name().as_bytes().to_vec(), kind_of(t.is_dir(), t.is_file(), t.is_symlink())))))
                    .collect::<std::io::Result<_>>()?,
                Target::Beneath(h, p) => h.read_dir(p)?
                    .map(|e| e.and_then(|e| e.file_type().map(|t| (e.file_name().as_bytes().to_vec(), kind_of(t.is_dir(), t.is_file(), t.is_symlink())))))
                    .collect::<std::io::Result<_>>()?,
            };
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Ok(entries)
        });
        match res {
            Ok(entries) => {
                let h = abi::host();
                let items: Vec<EntryRec> = entries.iter().map(|(name, kind)| EntryRec { name: unsafe { RocListWith::<u8, false>::from_slice(name, h) }, kind: *kind }).collect();
                FsReadDirAtResult { payload: FsReadDirAtResultPayload { ok: ManuallyDrop::new(unsafe { RocList::from_slice(&items, h) }) }, tag: FsReadDirAtResultTag::Ok }
            }
            Err(e) => FsReadDirAtResult { payload: FsReadDirAtResultPayload { err: ManuallyDrop::new(ioerr(&e)) }, tag: FsReadDirAtResultTag::Err },
        }
    }

    /// One-path operations whose std and cap-std spellings share a name.
    macro_rules! both {
        ($tg:expr, $op:ident) => {
            match $tg {
                Target::Ambient(p) => std::fs::$op(p),
                Target::Beneath(h, p) => h.$op(p),
            }
        };
    }
    pub fn create_dir_at(r: &Root, d: *mut u64, p: RocListWith<u8, false>, mode: u32) -> FsCreateDirAtResult {
        dir_unit(with_path(r, d, p, |tg| {
            let tg = new_directory_name(tg)?;
            crate::copy::make_dir(&tg, mode)
        }))
    }
    /// `mkdir -p`: a directory already there is success, `dir/` included, and
    /// the kernel follows that spelling, so `dirlink/` is too. Anything else at
    /// the name is `AlreadyExists`, which is what stops `dangling/` making the
    /// link's missing target outside the tree.
    pub fn create_dir_all_at(r: &Root, d: *mut u64, p: RocListWith<u8, false>) -> FsCreateDirAtResult {
        dir_unit(with_path(r, d, p, |tg| {
            if slashes_stripped(tg.path()).is_some() && metadata_followed(&tg).is_ok_and(|m| m.0) {
                return Ok(());
            }
            let tg = new_directory_name(tg)?;
            both!(tg, create_dir_all)
        }))
    }
    pub fn remove_dir_at(r: &Root, d: *mut u64, p: RocListWith<u8, false>) -> FsCreateDirAtResult { dir_unit(with_path(r, d, p, |tg| { let tg = existing_directory_name(tg)?; both!(tg, remove_dir) })) }
    pub fn remove_dir_all_at(r: &Root, d: *mut u64, p: RocListWith<u8, false>) -> FsCreateDirAtResult {
        dir_unit(with_path(r, d, p, |tg| {
            refuse_trailing_dot(&tg)?;
            let tg = existing_directory_name(tg)?;
            both!(tg, remove_dir_all)
        }))
    }

    /// A recursive removal of a name ending in `.` (`adir/.`, `./adir/./`, the
    /// cwd as `.`) emptied the directory and only then failed, when the final
    /// `rmdir` answered EINVAL for the `.` — through `dirlink/.` it emptied the
    /// directory the link leads to. The name cannot be removed, so refuse it
    /// before deleting anything, as `ends_in_parent` does for `..`. A bare `.`
    /// is the root named plainly beneath it, which stays removable by name.
    /// `remove_dir_at` needs none of this: its single `rmdir` refuses first.
    fn refuse_trailing_dot(tg: &Target) -> std::io::Result<()> {
        let mut b = tg.path().as_os_str().as_bytes();
        while let Some(rest) = b.strip_suffix(b"/") {
            b = rest;
        }
        if b.ends_with(b"/.") {
            return Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "a directory named through . cannot be removed"));
        }
        Ok(())
    }

    /// A directory that must not exist yet, then its own error where the name
    /// says one thing and the kernel another.
    ///
    /// A directory to remove, named `dir/`: the name without the slash, which
    /// must be a real directory. cap-std answered EINVAL to `remove_dir("dir/")`
    /// (so confined `delete_all!("tree/")` emptied the tree and then failed),
    /// and the macOS kernel removed the directory a link named `link/` leads
    /// to; Linux answers `NotADirectory` for a link, and so do both now.
    fn existing_directory_name(tg: Target) -> std::io::Result<Target> {
        // `rmdir(2)` refuses `..` as the last component (EINVAL), but a
        // recursive removal spelled that way is not a syscall: unconfined it
        // emptied and removed the PARENT, where cap-std answered NotFound.
        // Both refuse it now, since no caller means "delete my parent" by it.
        if ends_in_parent(tg.path()) {
            return Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "a directory named through .. cannot be removed"));
        }
        let Some(name) = slashes_stripped(tg.path()) else { return Ok(tg) };
        let named = tg.with_path(name);
        match metadata_as_named(&named) {
            Ok((true, _)) => Ok(named),
            Ok((false, _)) => Err(directory_name()),
            Err(e) => Err(e),
        }
    }

    /// A directory to create, named `dir/`: anything already at the name, a
    /// dangling link included, is `AlreadyExists`. The macOS kernel made the
    /// missing target of `dangling/`, where Linux and cap-std refuse.
    pub(crate) fn new_directory_name(tg: Target) -> std::io::Result<Target> {
        let Some(name) = slashes_stripped(tg.path()) else { return Ok(tg) };
        let named = tg.with_path(name);
        let exists = match &named {
            Target::Ambient(p) => std::fs::symlink_metadata(p).map(|_| ()),
            Target::Beneath(h, p) => h.symlink_metadata(p).map(|_| ()),
        };
        match exists {
            Ok(_) => Err(std::io::Error::new(std::io::ErrorKind::AlreadyExists, "something already exists at the directory name")),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(named),
            Err(e) => Err(e),
        }
    }
    /// On a symlink this removes the LINK, on both backends.
    pub fn unlink_at(r: &Root, d: *mut u64, p: RocListWith<u8, false>) -> FsWriteFileAtResult { unit(with_path(r, d, p, |tg| both!(tg, remove_file))) }

    fn two(r: &Root, d: *mut u64, a: RocListWith<u8, false>, b: RocListWith<u8, false>, f: impl FnOnce(Target, Target) -> std::io::Result<()>) -> FsWriteFileAtResult {
        let ra = bytes(&a); unsafe { a.decref(abi::host()) };
        let rb = bytes(&b); unsafe { b.decref(abi::host()) };
        let dir = unsafe { abi::resource::with(d as RocBox, |x: &mut Desc| dir_of(x)) };
        unit(dir.and_then(|dir| resolve(r, &dir, &ra).and_then(|pa| resolve(r, &dir, &rb).and_then(|pb| f(pa, pb)))))
    }
    /// Both ends must be on the same backend; `resolve` guarantees it, since a
    /// Root is one or the other.
    fn mixed() -> std::io::Error {
        std::io::Error::new(std::io::ErrorKind::Unsupported, "paths resolved under different roots")
    }
    pub fn rename_at(r: &Root, d: *mut u64, a: RocListWith<u8, false>, b: RocListWith<u8, false>) -> FsWriteFileAtResult {
        two(r, d, a, b, |a, b| match (a, b) {
            (Target::Ambient(a), Target::Ambient(b)) => {
                let a = renamed_source(Target::Ambient(a), names_directory(&b))?;
                match a { Target::Ambient(a) => std::fs::rename(a, b), _ => Err(mixed()) }
            }
            (Target::Beneath(h, a), Target::Beneath(_, b)) => {
                let a = renamed_source(Target::Beneath(h, a), names_directory(&b))?;
                match a {
                    Target::Beneath(_, a) => {
                        link_stays_inside(h, &a, &b)?;
                        h.rename(a, h, b)
                    }
                    _ => Err(mixed()),
                }
            }
            _ => Err(mixed()),
        })
    }
    /// The source of a rename where either name ends in `/` or `/.`: it must
    /// be a directory. A stat that fails answers with its own error, since a
    /// refusal or a missing name reported as `NotADirectory` names the wrong
    /// cause.
    fn renamed_source(a: Target, destination_names_directory: bool) -> std::io::Result<Target> {
        if !names_directory(a.path()) && !destination_names_directory {
            return Ok(a);
        }
        match metadata_as_named(&a) {
            Ok((true, _)) => Ok(a),
            Ok((false, _)) => Err(directory_name()),
            Err(e) => Err(e),
        }
    }

    pub fn link_at(r: &Root, d: *mut u64, a: RocListWith<u8, false>, b: RocListWith<u8, false>) -> FsWriteFileAtResult {
        two(r, d, a, b, |a, b| match (a, b) {
            (_, b) if names_directory(b.path()) => Err(directory_name()),
            (Target::Ambient(a), Target::Ambient(b)) => std::fs::hard_link(a, b),
            (Target::Beneath(h, a), Target::Beneath(_, b)) => {
                link_stays_inside(h, &a, &b)?;
                h.hard_link(a, h, b)
            }
            _ => Err(mixed()),
        })
    }

    /// A relative symlink's target resolves from wherever the link sits, so
    /// moving or hard-linking one to another directory re-aims it: `a/l -> ..`
    /// is the root, `l -> ..` its parent. Beneath the root such a move must
    /// leave the target existing inside (D-S2-24). An absolute link, or one
    /// staying in its directory, points where it did, so it is not checked; the
    /// parents are compared as spelled, so an alias is checked. Not a symlink:
    /// nothing to check. A directory holding relative links is not checked.
    fn link_stays_inside(h: &cap_std::fs::Dir, from: &Path, to: &Path) -> std::io::Result<()> {
        let is_symlink = matches!(h.symlink_metadata(from), Ok(m) if m.file_type().is_symlink());
        if !is_symlink {
            return Ok(());
        }
        let contents = h.read_link_contents(from)?;
        if contents.is_absolute() || from.parent() == to.parent() {
            return Ok(());
        }
        // The source exists, so a missing target is not NotFound.
        target_inside(h, to, &contents).map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::PermissionDenied, "the moved symlink's target would not exist inside the root")
        })
    }

    /// The target a link at `link` would reach, resolved beneath the root.
    fn target_inside(h: &cap_std::fs::Dir, link: &Path, contents: &Path) -> std::io::Result<()> {
        let from = link.parent().unwrap_or_else(|| Path::new("."));
        h.metadata(from.join(contents)).map(|_| ())
    }

    pub fn copy_file_at(r: &Root, sd: *mut u64, sp: RocListWith<u8, false>, dd: *mut u64, dp: RocListWith<u8, false>) -> FsWriteFileAtResult {
        let src_rel = bytes(&sp); unsafe { sp.decref(abi::host()) };
        let dst_rel = bytes(&dp); unsafe { dp.decref(abi::host()) };
        let src_dir = unsafe { abi::resource::with(sd as RocBox, |x: &mut Desc| dir_of(x)) };
        let dst_dir = unsafe { abi::resource::with(dd as RocBox, |x: &mut Desc| dir_of(x)) };
        unit(src_dir.and_then(|src_dir| dst_dir.and_then(|dst_dir| {
            let from = resolve(r, &src_dir, &src_rel)?;
            let to = resolve(r, &dst_dir, &dst_rel)?;
            refuse_directory_name(&to)?;
            crate::copy::copy_file(&from, &to)
        })))
    }

    pub fn copy_dir_at(r: &Root, sd: *mut u64, sp: RocListWith<u8, false>, dd: *mut u64, dp: RocListWith<u8, false>) -> FsWriteFileAtResult {
        let src_rel = bytes(&sp); unsafe { sp.decref(abi::host()) };
        let dst_rel = bytes(&dp); unsafe { dp.decref(abi::host()) };
        let src_dir = unsafe { abi::resource::with(sd as RocBox, |x: &mut Desc| dir_of(x)) };
        let dst_dir = unsafe { abi::resource::with(dd as RocBox, |x: &mut Desc| dir_of(x)) };
        unit(src_dir.and_then(|src_dir| dst_dir.and_then(|dst_dir| {
            let from = resolve(r, &src_dir, &src_rel)?;
            let to = resolve(r, &dst_dir, &dst_rel)?;
            crate::copy::copy_dir(&from, to)
        })))
    }

    pub fn readlink_at(r: &Root, d: *mut u64, path: RocListWith<u8, false>) -> FsReadFileAtResult {
        match with_path(r, d, path, |tg| match tg {
            Target::Ambient(p) => std::fs::read_link(p),
            Target::Beneath(h, p) => h.read_link_contents(p),
        }) {
            Ok(v) => FsReadFileAtResult { payload: FsReadFileAtResultPayload { ok: ManuallyDrop::new(unsafe { RocListWith::<u8, false>::from_slice(v.as_os_str().as_bytes(), abi::host()) }) }, tag: FsReadFileAtResultTag::Ok },
            Err(e) => FsReadFileAtResult { payload: FsReadFileAtResultPayload { err: ManuallyDrop::new(ioerr(&e)) }, tag: FsReadFileAtResultTag::Err },
        }
    }

    /// The target is link contents. Unconfined it is stored as given.
    ///
    /// Beneath the root it must name something that exists inside the root,
    /// resolved from the link's own directory the way a later follow will
    /// resolve it, links included. Refusing only when a confined FOLLOW escapes
    /// protects the confined app, not the unconfined programs (a shell, an
    /// editor, a backup) that would follow a planted link to `~/.ssh` later.
    /// An absolute target is refused, since cap-std refuses absolute paths.
    /// `rename_at`/`link_at` re-check a symlink they move. Not airtight:
    /// renaming a directory that holds relative links is not checked, and the
    /// target can change between check and create.
    pub fn symlink_at(r: &Root, d: *mut u64, target: RocListWith<u8, false>, link: RocListWith<u8, false>) -> FsWriteFileAtResult {
        let contents = PathBuf::from(std::ffi::OsStr::from_bytes(&bytes(&target))); unsafe { target.decref(abi::host()) };
        unit(with_path(r, d, link, |tg| {
            refuse_directory_name(&tg)?;
            match tg {
                Target::Ambient(p) => std::os::unix::fs::symlink(&contents, p),
                Target::Beneath(h, p) => {
                    target_inside(h, &p, &contents)?;
                    h.symlink_contents(&contents, p)
                }
            }
        }))
    }
}

/// Emit the hosted symbols for a root policy under `$prefix`
/// (`trantor__<prefix>__<op>`). Invoked once per thin staticlib.
#[macro_export]
macro_rules! exports {
    ($prefix:ident, $root:expr) => {
        $crate::paste::paste! {
            static ROOT: std::sync::OnceLock<$crate::Root> = std::sync::OnceLock::new();
            fn root() -> &'static $crate::Root { ROOT.get_or_init(|| $root) }
            use trantor_abi::*;
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __preopens>]() -> $crate::RocList<$crate::RocBox> { $crate::ops::preopens(root()) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __open_with_flags_at>](d: *mut u64, p: RocListWith<u8, false>, f: $crate::ops::OpenFlags) -> FsOpenWithFlagsAtResult { $crate::ops::open_with_flags_at(root(), d, p, f) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __read_via_stream>](d: *mut u64) -> FsReadViaStreamResult { $crate::ops::read_via_stream(root(), d) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __write_via_stream>](d: *mut u64, o: u64) -> FsWriteViaStreamResult { $crate::ops::write_via_stream(root(), d, o) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __append_via_stream>](d: *mut u64) -> FsWriteViaStreamResult { $crate::ops::append_via_stream(root(), d) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __read_file_at>](d: *mut u64, p: RocListWith<u8, false>) -> FsReadFileAtResult { $crate::ops::read_file_at(root(), d, p) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __write_file_at>](d: *mut u64, p: RocListWith<u8, false>, b: RocListWith<u8, false>) -> FsWriteFileAtResult { $crate::ops::write_file_at(root(), d, p, b) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __metadata_hash_at>](d: *mut u64, p: RocListWith<u8, false>, f: $crate::ops::HashFlags) -> FsMetadataHashAtResult { $crate::ops::metadata_hash_at(root(), d, p, f) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __stat_at>](d: *mut u64, p: RocListWith<u8, false>, f: $crate::ops::HashFlags) -> FsStatAtResult { $crate::ops::stat_at(root(), d, p, f) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __read_dir_at>](d: *mut u64, p: RocListWith<u8, false>) -> FsReadDirAtResult { $crate::ops::read_dir_at(root(), d, p) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __create_dir_at>](d: *mut u64, p: RocListWith<u8, false>, m: u32) -> FsCreateDirAtResult { $crate::ops::create_dir_at(root(), d, p, m) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __create_dir_all_at>](d: *mut u64, p: RocListWith<u8, false>) -> FsCreateDirAtResult { $crate::ops::create_dir_all_at(root(), d, p) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __remove_dir_at>](d: *mut u64, p: RocListWith<u8, false>) -> FsCreateDirAtResult { $crate::ops::remove_dir_at(root(), d, p) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __remove_dir_all_at>](d: *mut u64, p: RocListWith<u8, false>) -> FsCreateDirAtResult { $crate::ops::remove_dir_all_at(root(), d, p) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __unlink_at>](d: *mut u64, p: RocListWith<u8, false>) -> FsWriteFileAtResult { $crate::ops::unlink_at(root(), d, p) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __rename_at>](d: *mut u64, a: RocListWith<u8, false>, b: RocListWith<u8, false>) -> FsWriteFileAtResult { $crate::ops::rename_at(root(), d, a, b) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __copy_file_at>](sd: *mut u64, sp: RocListWith<u8, false>, dd: *mut u64, dp: RocListWith<u8, false>) -> FsWriteFileAtResult { $crate::ops::copy_file_at(root(), sd, sp, dd, dp) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __copy_dir_at>](sd: *mut u64, sp: RocListWith<u8, false>, dd: *mut u64, dp: RocListWith<u8, false>) -> FsWriteFileAtResult { $crate::ops::copy_dir_at(root(), sd, sp, dd, dp) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __readlink_at>](d: *mut u64, p: RocListWith<u8, false>) -> FsReadFileAtResult { $crate::ops::readlink_at(root(), d, p) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __symlink_at>](d: *mut u64, t: RocListWith<u8, false>, l: RocListWith<u8, false>) -> FsWriteFileAtResult { $crate::ops::symlink_at(root(), d, t, l) }
            #[unsafe(no_mangle)] pub extern "C-unwind" fn [<trantor__ $prefix __link_at>](d: *mut u64, a: RocListWith<u8, false>, b: RocListWith<u8, false>) -> FsWriteFileAtResult { $crate::ops::link_at(root(), d, a, b) }
        }
    };
}
