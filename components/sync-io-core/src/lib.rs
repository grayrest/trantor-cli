//! sync-io core (P9 shared substrate): the Stream trait and resource
//! constructors. Producers (filesystem, sockets, stdio, the test backings)
//! depend on this rlib to mint stream resources. It deliberately exports NO
//! `#[no_mangle]` symbols: cargo bundles an rlib into each dependent staticlib,
//! and a bundled no_mangle would be the H0c duplicate-symbol footgun. The
//! hosted read!/write! symbols live in the separate `sync-io` staticlib.
use trantor_abi as abi;
use abi::RocBox;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::RawFd;

/// The backing of an InputStream resource. Buffered so `read_until!` (line
/// reads for files, stdin and sockets alike) has one implementation; `read!`
/// drains the buffer first, so the two compose on one stream.
///
/// `Box<dyn BufRead>` rather than `BufReader<Box<dyn Read>>`, so a source that
/// is ALREADY buffered somewhere that outlives this handle can be stored as
/// itself. A stream resource is owned by the hosted call that receives it and
/// released when that call returns, which takes any buffer inside it along —
/// see `input_stream_buffered`.
///
/// The second field is what `FdHandoff` hands on for the stream.
pub struct Input(pub Box<dyn BufRead>, pub Handoff);
/// The backing of an OutputStream resource, with its handoff as `Input`'s.
pub struct Output(pub Box<dyn Write>, pub Handoff);

/// What `FdHandoff` can give another host for a stream.
pub enum Handoff {
    /// The OS descriptor the stream reads from or writes to, borrowed from the
    /// source and valid only while the resource lives.
    Fd(RawFd),
    /// No descriptor under the stream, or none a child could use as it.
    ///
    /// There is no third case: a stream that could not be made is the error of
    /// the call that would have made it (D-S2-48), not a stream that answers
    /// one, so nothing mints a handoff out of a failure any more.
    NotAFile,
}

/// Mint an InputStream resource (a refcounted Box(U64) handle, P5), adding a
/// buffer of its own. Only correct for a source whose reads are wholly
/// contained in one hosted call, or whose handle is minted once and kept.
pub fn input_stream(r: Box<dyn Read>) -> RocBox { abi::resource::new(Input(Box::new(BufReader::new(r)), Handoff::NotAFile)) }
/// `input_stream` over a source that reads from `fd`.
pub fn input_stream_fd(r: Box<dyn Read>, fd: RawFd) -> RocBox { abi::resource::new(Input(Box::new(BufReader::new(r)), Handoff::Fd(fd))) }

/// Mint an InputStream over a source that carries its own buffer.
///
/// This exists because the handle is the wrong place for the buffer when the
/// handle is short-lived. `Stdin.bytes!` minted one per call, and each new
/// `BufReader` pulled 8KB from the fd, returned 4096 bytes and was dropped
/// with the other 4096 still inside — measured as a read loop whose second
/// block began at offset 8192 instead of 4096. `std::io::Stdin` is itself a
/// process-global `BufRead`, so handing it over directly keeps the surplus
/// where the next call can reach it.
pub fn input_stream_buffered(r: Box<dyn BufRead>) -> RocBox { abi::resource::new(Input(r, Handoff::NotAFile)) }
/// `input_stream_buffered` over a source that reads from `fd`.
pub fn input_stream_buffered_fd(r: Box<dyn BufRead>, fd: RawFd) -> RocBox { abi::resource::new(Input(r, Handoff::Fd(fd))) }
/// Mint an OutputStream resource.
pub fn output_stream(w: Box<dyn Write>) -> RocBox { abi::resource::new(Output(w, Handoff::NotAFile)) }
/// Mint an OutputStream resource over a sink that writes to `fd`.
pub fn output_stream_fd(w: Box<dyn Write>, fd: RawFd) -> RocBox { abi::resource::new(Output(w, Handoff::Fd(fd))) }

/// The one `std::io::ErrorKind` -> `IOErr` tag mapping, for every reach path.
///
/// Glue emits a structurally identical `IOErr` per importing module — `IOErr`,
/// `StreamsIOErr`, `SubprocessIOErr`, `FsIOErr`, `SocketsIOErr` — so each host
/// wrote its own `match`, and each one drifted to a DIFFERENT subset. Measured
/// before this macro existed:
///
///     mapper                NotFound PermDen AlrExst BrkPipe Intrpt Unsupp IsADir NotADir OOM
///     fs-core                  yes     yes     yes     yes     yes    yes    -      -      -
///     sync-io read_err         yes     yes      -      yes     yes     -     -      -      -
///     sync-io write_err         -       -       -      yes     yes     -     -      -      -
///     subprocess               yes     yes      -       -       -      -     -      -      -
///     net sockets              yes     yes     yes     yes     yes     -     -      -      -
///
/// So the same OS error reached Roc as a named tag through one path and as
/// `Other("Is a directory (os error 21)")` through another, and the three
/// variants nothing ever built — IsADirectory, NotADirectory, OutOfMemory —
/// made every app arm matching them dead code.
///
/// Takes the tag ENUM because that is the only part that differs; the caller
/// builds its own struct, since the payload union names differ too.
#[macro_export]
macro_rules! ioerr_tag {
    ($e:expr, $tag:ident) => {{
        use std::io::ErrorKind as K;
        match $e.kind() {
            K::NotFound => $tag::NotFound,
            K::PermissionDenied => $tag::PermissionDenied,
            K::AlreadyExists => $tag::AlreadyExists,
            K::BrokenPipe => $tag::BrokenPipe,
            K::Interrupted => $tag::Interrupted,
            K::Unsupported => $tag::Unsupported,
            K::IsADirectory => $tag::IsADirectory,
            K::NotADirectory => $tag::NotADirectory,
            K::OutOfMemory => $tag::OutOfMemory,
            _ => $tag::Other,
        }
    }};
}
