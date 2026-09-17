//! `copy_file_at!`: one copy for both backends (D-S2-36). A backend only
//! opens the two files; everything after moves between open handles, so
//! timestamps, permission bits, error order and messages are the same whether
//! the root is confined or not.
//!
//! Not `std::fs::copy` unconfined: on APFS it clones, keeping timestamps and
//! xattrs, and drops setuid, which the confined copy did not. Not cap-std's
//! `Dir::copy` confined: on macOS it resolves the destination path itself with
//! `fclonefileat`, and raced against a swapped directory 108 of 2000 copies
//! landed outside the root.
use crate::Target;
use std::os::unix::fs::PermissionsExt;

/// setuid, setgid and sticky: not carried to a copy.
const SPECIAL_BITS: u32 = 0o7000;
/// Owner read, write and search: a copied directory always has them, so the
/// tree copy can create its children.
const OWNER_ALL: u32 = 0o700;

pub(crate) fn copy_file(from: &Target, to: &Target) -> std::io::Result<()> {
    let mut src = open_source(from)?;
    let meta = src.metadata()?;
    if !meta.is_file() {
        // A directory says so by kind; a FIFO, socket or device has no kind of
        // its own in `IOErr`, so it is `Other` with the reason.
        return Err(if meta.is_dir() {
            std::io::Error::new(std::io::ErrorKind::IsADirectory, "the copy source is a directory")
        } else {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "the copy source is not a regular file")
        });
    }
    let mode = meta.permissions().mode() & !SPECIAL_BITS & 0o7777;
    // `create_new`: an existing destination is refused atomically, on both backends.
    let mut dst = create_destination(to, mode)?;
    // The open's mode passed through the umask; the copy's must not.
    let copied = std::io::copy(&mut src, &mut dst).and_then(|_| dst.set_permissions(std::fs::Permissions::from_mode(mode)));
    if copied.is_err() {
        // A partial file would make the retry fail with AlreadyExists.
        remove_if_same(to, &dst);
    }
    copied
}

/// `O_NONBLOCK`, so opening a FIFO returns at once and reaches the regular-file
/// check: a blocking open waited for a writer, and the copy hung for good. It
/// changes nothing for a regular file.
fn open_source(from: &Target) -> std::io::Result<std::fs::File> {
    match from {
        Target::Ambient(p) => {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(p)
        }
        Target::Beneath(h, p) => {
            use cap_std::fs::OpenOptionsExt;
            let mut o = cap_std::fs::OpenOptions::new();
            o.read(true).custom_flags(libc::O_NONBLOCK);
            h.open_with(p, &o).map(|f| f.into_std())
        }
    }
}

fn create_destination(to: &Target, mode: u32) -> std::io::Result<std::fs::File> {
    match to {
        Target::Ambient(p) => {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new().write(true).create_new(true).mode(mode).open(p)
        }
        Target::Beneath(h, p) => {
            use cap_std::fs::OpenOptionsExt;
            let mut o = cap_std::fs::OpenOptions::new();
            o.write(true).create_new(true).mode(mode);
            // Exclusive creation over an existing directory is `EEXIST` to the
            // kernel; cap-std answers `IsADirectory` for the root itself.
            h.open_with(p, &o).map(|f| f.into_std()).map_err(|e| {
                if e.kind() == std::io::ErrorKind::IsADirectory { std::io::Error::new(std::io::ErrorKind::AlreadyExists, e.to_string()) } else { e }
            })
        }
    }
}

/// Removes the partial copy only if the name still holds the file this copy
/// created. By name alone, a directory swapped in meanwhile had a different
/// file of that name deleted. Narrows the window; does not close it.
fn remove_if_same(to: &Target, created: &std::fs::File) {
    use std::os::unix::fs::MetadataExt;
    let Ok(ours) = created.metadata() else { return };
    let _ = match to {
        Target::Ambient(p) => match std::fs::symlink_metadata(p) {
            Ok(m) if (m.dev(), m.ino()) == (ours.dev(), ours.ino()) => std::fs::remove_file(p),
            _ => Ok(()),
        },
        Target::Beneath(h, p) => match h.symlink_metadata(p) {
            Ok(m) if (cap_std::fs::MetadataExt::dev(&m), cap_std::fs::MetadataExt::ino(&m)) == (ours.dev(), ours.ino()) => h.remove_file(p),
            _ => Ok(()),
        },
    };
}

/// A directory with the source directory's permission bits (D-S2-39). A tree
/// copy made each directory through `create_dir_at!`, under the umask: a 0700
/// directory copied as 0755 and exposed the files inside it.
///
/// The source is read as `stat_at!` reads it, so `link/` is the directory the
/// link leads to on both backends. The destination is made and opened under
/// its name without trailing slashes: `O_NOFOLLOW` does not stop a follow
/// through `name/`, so a link swapped in after the mkdir would have had its
/// target's mode changed.
pub(crate) fn copy_dir(from: &Target, to: Target) -> std::io::Result<()> {
    let (is_dir, source_mode) = crate::ops::metadata_as_named(from)?;
    if !is_dir {
        return Err(std::io::Error::new(std::io::ErrorKind::NotADirectory, "the directory copy source is not a directory"));
    }
    let mode = (source_mode & 0o777 & !SPECIAL_BITS) | OWNER_ALL;
    let to = crate::ops::new_directory_name(to)?;
    make_owner_only(&to)?;
    // Set after the mkdir, so the umask does not apply to it.
    let chmod = open_made(&to).and_then(|made| made.set_permissions(std::fs::Permissions::from_mode(mode)));
    if chmod.is_err() {
        // Nothing is inside it yet; left behind, a retry would be AlreadyExists.
        let _ = match &to {
            Target::Ambient(p) => std::fs::remove_dir(p),
            Target::Beneath(h, p) => h.remove_dir(p),
        };
    }
    chmod
}

fn make_owner_only(to: &Target) -> std::io::Result<()> {
    make_dir(to, OWNER_ALL)
}

/// `mkdir` with a mode, which the umask masks as it does for `mkdir(2)`.
pub(crate) fn make_dir(to: &Target, mode: u32) -> std::io::Result<()> {
    match to {
        Target::Ambient(p) => {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new().mode(mode).create(p)
        }
        Target::Beneath(h, p) => {
            use cap_std::fs::DirBuilderExt;
            let mut b = cap_std::fs::DirBuilder::new();
            b.mode(mode);
            h.create_dir_with(p, &b)
        }
    }
}

/// Opens the directory just made without following a link, so the mode is set
/// on it even if the name is swapped. Fails, and the caller removes the
/// directory, where a umask took the owner's read bit.
fn open_made(to: &Target) -> std::io::Result<std::fs::File> {
    match to {
        Target::Ambient(p) => {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW).open(p)
        }
        Target::Beneath(h, p) => cap_fs_ext::DirExt::open_dir_nofollow(*h, p).map(|d| d.into_std_file()),
    }
}
