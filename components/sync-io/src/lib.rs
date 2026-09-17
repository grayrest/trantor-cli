//! roc:sync-io/streams host: the hosted read!/write! symbols over the stream
//! resources minted by sync-io-core. Blocking (P12). Every hosted arg is OWNED
//! (glue contract, B0): the stream handle is released via `resource::with`,
//! and list args are `.decref`'d — no Drop exists on bare RocListWith.
use core::mem::ManuallyDrop;
use trantor_abi as abi;
use abi::{RocBox, RocListWith, RocStr,
    StreamsReadResult as ReadR, StreamsReadResultPayload as ReadP, StreamsReadResultTag as ReadT,
    StreamsWriteResult as WriteR, StreamsWriteResultPayload as WriteP, StreamsWriteResultTag as WriteT,
    StreamsIOErr, StreamsIOErrPayload, StreamsIOErrTag, IOErr, IOErrPayload, IOErrTag,
    FdHandoffOutputFdResult as FdR, FdHandoffOutputFdResultPayload as FdP, FdHandoffOutputFdResultTag as FdT,
    IoOrNotAFile, IoOrNotAFilePayload, IoOrNotAFileTag, FdHandoffIOErr, FdHandoffIOErrPayload, FdHandoffIOErrTag};
use std::io::{Read, Write};
use sync_io_core::{Handoff, Input, Output};

/// The most one `Streams.read!` will allocate, however large its `max`.
const READ_CHUNK_MAX: u64 = 1 << 20;

fn read_err(e: &std::io::Error) -> ReadR {
    let tag = sync_io_core::ioerr_tag!(e, StreamsIOErrTag);
    let err = if let StreamsIOErrTag::Other = tag {
        StreamsIOErr { payload: StreamsIOErrPayload { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag }
    } else {
        StreamsIOErr { payload: unsafe { core::mem::zeroed() }, tag }
    };
    ReadR { payload: ReadP { err: ManuallyDrop::new(err) }, tag: ReadT::Err }
}
fn write_err(e: &std::io::Error) -> WriteR {
    let tag = sync_io_core::ioerr_tag!(e, IOErrTag);
    let err = if let IOErrTag::Other = tag {
        IOErr { payload: IOErrPayload { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag }
    } else {
        IOErr { payload: unsafe { core::mem::zeroed() }, tag }
    };
    WriteR { payload: WriteP { err: ManuallyDrop::new(err) }, tag: WriteT::Err }
}

/// `Streams.read! : InputStream, U64 => Try(List(U8), [StreamErr(IOErr)])`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sync_io__read(s: *mut u64, max: u64) -> ReadR {
    // Owned handle: `with` borrows then releases (B0 rule).
    let outcome: std::io::Result<Vec<u8>> = unsafe {
        abi::resource::with(s as RocBox, |inp: &mut Input| {
            // Clamped: `max` is an app-supplied U64 and this used to allocate
            // all of it up front, so `read!(stdin, 18e18)` aborted the process
            // with a capacity overflow and `read!(stdin, 1e11)` reserved 100GB
            // to return three bytes. The leaf reads "up to `max`", which a
            // short read already satisfies — one `read` returns what is
            // available regardless.
            let mut buf = vec![0u8; max.min(READ_CHUNK_MAX) as usize];
            let n = inp.0.read(&mut buf)?;
            buf.truncate(n);
            Ok(buf)
        })
    };
    match outcome {
        Ok(bytes) => {
            let list = unsafe { RocListWith::<u8, false>::from_slice(&bytes, abi::host()) };
            ReadR { payload: ReadP { ok: ManuallyDrop::new(list) }, tag: ReadT::Ok }
        }
        Err(e) => read_err(&e),
    }
}

/// `Streams.read_until! : InputStream, U8, U64 => Try(List(U8), [StreamErr(IOErr)])`
/// Buffered read up to and including `delim`, capped at `max` bytes (the cap
/// bounds a delimiter-less stream). Empty list = end of stream.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sync_io__read_until(s: *mut u64, delim: u8, max: u64) -> ReadR {
    let outcome: std::io::Result<Vec<u8>> = unsafe {
        abi::resource::with(s as RocBox, |inp: &mut Input| {
            let mut buf = Vec::new();
            std::io::BufRead::read_until(&mut inp.0.by_ref().take(max), delim, &mut buf)?;
            Ok(buf)
        })
    };
    match outcome {
        Ok(bytes) => {
            let list = unsafe { RocListWith::<u8, false>::from_slice(&bytes, abi::host()) };
            ReadR { payload: ReadP { ok: ManuallyDrop::new(list) }, tag: ReadT::Ok }
        }
        Err(e) => read_err(&e),
    }
}

/// `Streams.write! : OutputStream, List(U8) => Try({}, [StreamErr(IOErr)])`
/// Flushes after every write: the process exits through Roc's runtime, not
/// Rust's `main`, so a line-buffered stdout would drop a trailing partial line.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sync_io__write(s: *mut u64, bytes: RocListWith<u8, false>) -> WriteR {
    let outcome: std::io::Result<()> = unsafe {
        abi::resource::with(s as RocBox, |out: &mut Output| out.0.write_all(bytes.as_slice()).and_then(|_| out.0.flush()))
    };
    // Owned list arg: release it (no Drop on RocListWith).
    unsafe { bytes.decref(abi::host()) };
    match outcome {
        Ok(()) => WriteR { payload: WriteP { ok: [] }, tag: WriteT::Ok },
        Err(e) => write_err(&e),
    }
}

/// The lowest fd a duplicate may take. In an app started with stdin closed, a
/// duplicate numbered 0 would be closed by a spawn setting up the child's stdin
/// before it was dup'd onto stdout.
const FIRST_NON_STDIO_FD: i32 = 3;

/// A close-on-exec duplicate of the stream's descriptor, owned by whoever
/// receives the number.
///
/// Called INSIDE the resource borrow: `resource::with` releases the handle when
/// the closure returns, and a stream minted for this one call is dropped then,
/// closing the descriptor a later dup would have copied.
fn dup_owned(handoff: &Handoff) -> FdR {
    match handoff {
        Handoff::Fd(fd) => {
            // SAFETY: F_DUPFD_CLOEXEC on a descriptor the live resource still holds.
            let n = unsafe { libc::fcntl(*fd, libc::F_DUPFD_CLOEXEC, FIRST_NON_STDIO_FD) };
            if n >= 0 { FdR { payload: FdP { ok: ManuallyDrop::new(n) }, tag: FdT::Ok } } else { handoff_io(&std::io::Error::last_os_error()) }
        }
        Handoff::NotAFile => FdR { payload: FdP { err: ManuallyDrop::new(IoOrNotAFile { payload: unsafe { core::mem::zeroed() }, tag: IoOrNotAFileTag::NotAFile }) }, tag: FdT::Err },
    }
}

fn handoff_io(e: &std::io::Error) -> FdR {
    let tag = sync_io_core::ioerr_tag!(e, FdHandoffIOErrTag);
    let err = if let FdHandoffIOErrTag::Other = tag {
        FdHandoffIOErr { payload: FdHandoffIOErrPayload { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag }
    } else {
        FdHandoffIOErr { payload: unsafe { core::mem::zeroed() }, tag }
    };
    FdR { payload: FdP { err: ManuallyDrop::new(IoOrNotAFile { payload: IoOrNotAFilePayload { io: ManuallyDrop::new(err) }, tag: IoOrNotAFileTag::Io }) }, tag: FdT::Err }
}

/// `FdHandoff.output_fd! : Streams.OutputStream => Try(I32, [NotAFile, Io(IOErr)])`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sync_io__output_fd(s: *mut u64) -> FdR {
    unsafe { abi::resource::with(s as RocBox, |out: &mut Output| dup_owned(&out.1)) }
}

/// `FdHandoff.input_fd! : Streams.InputStream => Try(I32, [NotAFile, Io(IOErr)])`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sync_io__input_fd(s: *mut u64) -> FdR {
    unsafe { abi::resource::with(s as RocBox, |inp: &mut Input| dup_owned(&inp.1)) }
}

/// `FdHandoff.close_fd! : I32 => {}`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sync_io__close_fd(fd: i32) {
    // SAFETY: the number came from `output_fd!`/`input_fd!`, which handed its
    // ownership to the caller, and the caller is giving it back.
    unsafe { libc::close(fd) };
}
