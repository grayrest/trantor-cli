//! roc:cli package host (P9: one crate per package): stdout/stderr/stdin,
//! environment, terminal. Streams are minted through sync-io-core. Blocking
//! (P12). Owned-argument rule (B0): the only refcounted arg is `var`'s name,
//! which is decref'd after use.
use core::mem::ManuallyDrop;
use trantor_abi as abi;
use abi::*;
use std::io::{BufRead, Read};
use std::os::fd::AsRawFd;
use std::sync::OnceLock;

// ---- streams: roc:cli/stdout, roc:cli/stderr, roc:cli/stdin ----

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__get_stdout() -> *mut u64 {
    sync_io_core::output_stream_fd(Box::new(std::io::stdout()), std::io::stdout().as_raw_fd()) as *mut u64
}
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__get_stderr() -> *mut u64 {
    sync_io_core::output_stream_fd(Box::new(std::io::stderr()), std::io::stderr().as_raw_fd()) as *mut u64
}
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__get_stdin() -> *mut u64 {
    // `stdin()` is already a process-global BufRead; wrapping it in a second
    // BufReader here meant every minted handle carried away whatever it had
    // read ahead when the hosted call released it.
    sync_io_core::input_stream_buffered_fd(Box::new(SharedStdin(None)), std::io::stdin().as_raw_fd()) as *mut u64
}

/// The process-global stdin buffer, locked only while a read uses it.
///
/// A handle used to hold a `StdinLock` for its whole life. That lock is a plain
/// mutex, not reentrant, so an app holding one stdin stream that took a second
/// (or called `Stdin.line!`) blocked forever on its next read.
///
/// `fill_buf` must return bytes that stay borrowed until `consume`, so it takes
/// the lock and keeps it; `consume`, and every other read, gives it back.
struct SharedStdin(Option<std::io::StdinLock<'static>>);

impl Read for SharedStdin {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0 = None;
        std::io::stdin().lock().read(buf)
    }
}

impl BufRead for SharedStdin {
    fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
        // The first fill decides; a second call would `read(2)` again at end of
        // input, so a terminal needed two Ctrl-Ds to end one `read_until!`.
        // Nothing is borrowed in either early return, so the lock goes now: a
        // failed or empty fill is not followed by `consume`.
        match self.0.get_or_insert_with(|| std::io::stdin().lock()).fill_buf().map(|b| b.is_empty()) {
            Err(e) => {
                self.0 = None;
                return Err(e);
            }
            Ok(true) => {
                self.0 = None;
                return Ok(&[]);
            }
            Ok(false) => {}
        }
        match &mut self.0 {
            Some(lock) => lock.fill_buf(),
            None => Ok(&[]),
        }
    }
    fn consume(&mut self, amount: usize) {
        if let Some(mut lock) = self.0.take() {
            lock.consume(amount);
        }
    }
}

/// The one mapping, as every other reach path uses: `Stdin.line!` named three
/// kinds and called the rest `Other`, so the same error read as `IsADirectory`
/// through a stream and as `Other("Is a directory…")` here — on the same fd and
/// the same buffer.
fn stdin_ioerr(e: &std::io::Error) -> CliInIOErr {
    let tag = sync_io_core::ioerr_tag!(e, CliInIOErrTag);
    if let CliInIOErrTag::Other = tag {
        CliInIOErr { payload: CliInIOErrPayload { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag }
    } else {
        CliInIOErr { payload: unsafe { core::mem::zeroed() }, tag }
    }
}

/// `CliIn.read_line! : {} => Try(Str, [EndOfFile, StdinErr(IOErr)])` —
/// std's global Stdin is already buffered, so consecutive calls lose nothing.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__read_line() -> CliInReadLineResult {
    let mut line = String::new();
    match std::io::stdin().lock().read_line(&mut line) {
        Ok(0) => CliInReadLineResult {
            payload: CliInReadLineResultPayload { err: ManuallyDrop::new(EndOfFileOrIo {
                payload: EndOfFileOrIoPayload { end_of_file: [] }, tag: EndOfFileOrIoTag::EndOfFile }) },
            tag: CliInReadLineResultTag::Err,
        },
        Ok(_) => {
            let trimmed = line.strip_suffix('\n').map(|s| s.strip_suffix('\r').unwrap_or(s)).unwrap_or(&line);
            CliInReadLineResult { payload: CliInReadLineResultPayload { ok: ManuallyDrop::new(RocStr::from_str(trimmed, abi::host())) }, tag: CliInReadLineResultTag::Ok }
        }
        Err(e) => CliInReadLineResult {
            payload: CliInReadLineResultPayload { err: ManuallyDrop::new(EndOfFileOrIo {
                payload: EndOfFileOrIoPayload { io: ManuallyDrop::new(stdin_ioerr(&e)) }, tag: EndOfFileOrIoTag::Io }) },
            tag: CliInReadLineResultTag::Err,
        },
    }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__read_to_end() -> CliInReadToEndResult {
    let mut buf = Vec::new();
    match std::io::stdin().lock().read_to_end(&mut buf) {
        Ok(_) => CliInReadToEndResult {
            payload: CliInReadToEndResultPayload { ok: ManuallyDrop::new(unsafe { RocListWith::<u8, false>::from_slice(&buf, abi::host()) }) },
            tag: CliInReadToEndResultTag::Ok,
        },
        Err(e) => {
            let tag = sync_io_core::ioerr_tag!(e, IOErrTag);
            let err = if let IOErrTag::Other = tag {
                IOErr { payload: IOErrPayload { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag }
            } else { IOErr { payload: unsafe { core::mem::zeroed() }, tag } };
            CliInReadToEndResult { payload: CliInReadToEndResultPayload { err: ManuallyDrop::new(err) }, tag: CliInReadToEndResultTag::Err }
        }
    }
}

// ---- roc:cli/environment ----

/// One `Native.OsStr`: `Utf8` when the bytes are valid UTF-8, the platform's
/// raw form otherwise.
///
/// The point of taking `OsStr` rather than `String` is that `std::env::args()`
/// and `std::env::vars()` PANIC on non-Unicode data — `unwrap()` on a
/// `Result::Err` inside std — and both are read unconditionally: `args` builds
/// `main!`'s parameter, so one such argument aborted every app before its code
/// ran, and `vars` aborted `Env.dict!()`.
#[cfg(unix)]
fn native(s: &std::ffi::OsStr) -> OsStr {
    use std::os::unix::ffi::OsStrExt;
    let h = abi::host();
    match s.to_str() {
        Some(text) => OsStr {
            payload: OsStrPayload { utf8: ManuallyDrop::new(RocStr::from_str(text, h)) },
            tag: OsStrTag::Utf8,
        },
        None => OsStr {
            payload: OsStrPayload {
                unix_bytes: ManuallyDrop::new(unsafe { RocListWith::<u8, false>::from_slice(s.as_bytes(), h) }),
            },
            tag: OsStrTag::UnixBytes,
        },
    }
}
/// Non-Unix has no `OsStrExt::as_bytes`; nothing in this tree builds for it
/// yet, and a lossy `Utf8` keeps the file compiling rather than silently
/// changing what a future Windows host should do (WindowsU16s).
#[cfg(not(unix))]
fn native(s: &std::ffi::OsStr) -> OsStr {
    OsStr {
        payload: OsStrPayload { utf8: ManuallyDrop::new(RocStr::from_str(&s.to_string_lossy(), abi::host())) },
        tag: OsStrTag::Utf8,
    }
}

/// The inverse of `native`: a Roc `OsStr` as an `OsString`.
#[cfg(unix)]
fn os_string(s: &OsStr) -> std::ffi::OsString {
    use std::os::unix::ffi::OsStringExt;
    unsafe {
        match s.tag {
            OsStrTag::Utf8 => std::ffi::OsString::from((*s.payload.utf8).as_str()),
            OsStrTag::UnixBytes => std::ffi::OsString::from_vec((*s.payload.unix_bytes).as_slice().to_vec()),
            OsStrTag::WindowsU16s => std::ffi::OsString::from(String::from_utf16_lossy((*s.payload.windows_u16s).as_slice())),
        }
    }
}
#[cfg(not(unix))]
fn os_string(s: &OsStr) -> std::ffi::OsString {
    unsafe {
        match s.tag {
            OsStrTag::Utf8 => std::ffi::OsString::from((*s.payload.utf8).as_str()),
            OsStrTag::UnixBytes => std::ffi::OsString::from(String::from_utf8_lossy((*s.payload.unix_bytes).as_slice()).into_owned()),
            OsStrTag::WindowsU16s => std::ffi::OsString::from(String::from_utf16_lossy((*s.payload.windows_u16s).as_slice())),
        }
    }
}

/// argv INCLUDING the program name: basic-cli hands `main!` argv[0], as does
/// WASI `cli/environment.get-arguments`.
fn args() -> &'static Vec<std::ffi::OsString> {
    static A: OnceLock<Vec<std::ffi::OsString>> = OnceLock::new();
    A.get_or_init(|| std::env::args_os().collect())
}
fn envs() -> &'static Vec<(std::ffi::OsString, std::ffi::OsString)> {
    static E: OnceLock<Vec<(std::ffi::OsString, std::ffi::OsString)>> = OnceLock::new();
    E.get_or_init(|| std::env::vars_os().collect())
}

/// `CliEnv.args! : {} => List(OsStr)`
///
/// `args_os()`, and the bytes survive. `std::env::args()` unwraps an `Err` for
/// a non-Unicode argument and this is read unconditionally to build `main!`'s
/// parameter, so one such argument used to abort every app before its code
/// ran; a lossy conversion fixed the crash but threw the bytes away. Now that
/// the leaf and `main!` name the same `OsStr`, neither is necessary.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__args() -> RocList<OsStr> {
    let h = abi::host();
    let items: Vec<OsStr> = args().iter().map(|a| native(a)).collect();
    unsafe { RocList::from_slice(&items, h) }
}

/// `CliEnv.env! : {} => List({ name : Native.OsStr, value : Native.OsStr })`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__env() -> RocList<AnonStruct57d79b2a50ffd7e7> {
    let h = abi::host();
    let items: Vec<AnonStruct57d79b2a50ffd7e7> = envs()
        .iter()
        .map(|(n, v)| AnonStruct57d79b2a50ffd7e7 { name: native(n), value: native(v) })
        .collect();
    unsafe { RocList::from_slice(&items, h) }
}

/// `CliEnv.var! : OsStr => Try(OsStr, [VarNotFound(OsStr), Io(IOErr)])`
///
/// `var_os`, not `var`. `std::env::var` returns `Err(NotUnicode)` for a value
/// that is not UTF-8, and this mapped EVERY error to `VarNotFound` — so a
/// variable that was set, with a value the caller could have used, was
/// reported exactly like one that was never set. Now only genuinely absent is
/// absent, and the value crosses as it is.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__var(name: OsStr) -> CliEnvVarResult {
    let key = os_string(&name);
    unsafe { name.decref(abi::host()) }; // owned arg (B0 rule)
    if let Err(e) = valid_env_key(&key) {
        return CliEnvVarResult {
            payload: CliEnvVarResultPayload { err: ManuallyDrop::new(IoOrVarNotFound {
                payload: IoOrVarNotFoundPayload { io: ManuallyDrop::new(var_ioerr(&e)) },
                tag: IoOrVarNotFoundTag::Io }) },
            tag: CliEnvVarResultTag::Err,
        };
    }
    match std::env::var_os(&key) {
        Some(v) => CliEnvVarResult { payload: CliEnvVarResultPayload { ok: ManuallyDrop::new(native(&v)) }, tag: CliEnvVarResultTag::Ok },
        None => CliEnvVarResult {
            payload: CliEnvVarResultPayload { err: ManuallyDrop::new(IoOrVarNotFound {
                payload: IoOrVarNotFoundPayload { var_not_found: ManuallyDrop::new(native(&key)) },
                tag: IoOrVarNotFoundTag::VarNotFound }) },
            tag: CliEnvVarResultTag::Err,
        },
    }
}

/// A name the environment can hold. An entry is `name=value`, so a name
/// holding `=` matched a different entry (`A=B` read variable `A`'s value when
/// it began `B`), and a NUL ends the name early. The check and its wording are
/// basic-cli 0.21's `validate_env_key`, so the shim's `Env.var!` answers what
/// basic-cli's does: `EnvErr(Other(..))`.
fn valid_env_key(key: &std::ffi::OsStr) -> std::io::Result<()> {
    let bytes = key.as_encoded_bytes();
    if bytes.is_empty() || bytes.contains(&0) || bytes.contains(&b'=') {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "environment variable names cannot be empty or contain nul bytes or '='"));
    }
    Ok(())
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__platform() -> AnonStructBca0d23b5d625934 {
    let arch = match std::env::consts::ARCH {
        "aarch64" => AARCH64OrARMOrOTHEROrX64OrX86 { payload: AARCH64OrARMOrOTHEROrX64OrX86Payload { aarch64: [] }, tag: AARCH64OrARMOrOTHEROrX64OrX86Tag::AARCH64 },
        "x86_64" => AARCH64OrARMOrOTHEROrX64OrX86 { payload: AARCH64OrARMOrOTHEROrX64OrX86Payload { x64: [] }, tag: AARCH64OrARMOrOTHEROrX64OrX86Tag::X64 },
        "x86" => AARCH64OrARMOrOTHEROrX64OrX86 { payload: AARCH64OrARMOrOTHEROrX64OrX86Payload { x86: [] }, tag: AARCH64OrARMOrOTHEROrX64OrX86Tag::X86 },
        "arm" => AARCH64OrARMOrOTHEROrX64OrX86 { payload: AARCH64OrARMOrOTHEROrX64OrX86Payload { arm: [] }, tag: AARCH64OrARMOrOTHEROrX64OrX86Tag::ARM },
        other => AARCH64OrARMOrOTHEROrX64OrX86 { payload: AARCH64OrARMOrOTHEROrX64OrX86Payload { other: ManuallyDrop::new(RocStr::from_str(other, abi::host())) }, tag: AARCH64OrARMOrOTHEROrX64OrX86Tag::OTHER },
    };
    let os = match std::env::consts::OS {
        "macos" => LINUXOrMACOSOrOTHEROrWINDOWS { payload: LINUXOrMACOSOrOTHEROrWINDOWSPayload { macos: [] }, tag: LINUXOrMACOSOrOTHEROrWINDOWSTag::MACOS },
        "linux" => LINUXOrMACOSOrOTHEROrWINDOWS { payload: LINUXOrMACOSOrOTHEROrWINDOWSPayload { linux: [] }, tag: LINUXOrMACOSOrOTHEROrWINDOWSTag::LINUX },
        "windows" => LINUXOrMACOSOrOTHEROrWINDOWS { payload: LINUXOrMACOSOrOTHEROrWINDOWSPayload { windows: [] }, tag: LINUXOrMACOSOrOTHEROrWINDOWSTag::WINDOWS },
        other => LINUXOrMACOSOrOTHEROrWINDOWS { payload: LINUXOrMACOSOrOTHEROrWINDOWSPayload { other: ManuallyDrop::new(RocStr::from_str(other, abi::host())) }, tag: LINUXOrMACOSOrOTHEROrWINDOWSTag::OTHER },
    };
    AnonStructBca0d23b5d625934 { arch, os }
}


// ---- process cwd / exe path / temp dir, as OsStr ----
//
// These were `Str`: `to_string_lossy`, and `""` when the OS call failed. A
// non-UTF-8 directory lost its bytes, and a deleted cwd read as `""`, which
// the path layer joined relative paths onto.

/// An `IOErr` for this crate's env leaves. Glue emits one twin per reach path
/// (`var!`'s is `CliEnvIOErr`); both are the same 10 variants.
macro_rules! ioerr_ctor {
    ($name:ident, $ty:ident, $pl:ident, $tag:ident) => {
        fn $name(e: &std::io::Error) -> $ty {
            let tag = sync_io_core::ioerr_tag!(e, $tag);
            if let $tag::Other = tag {
                $ty { payload: $pl { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag }
            } else {
                $ty { payload: unsafe { core::mem::zeroed() }, tag }
            }
        }
    };
}
ioerr_ctor!(env_ioerr, IOErr, IOErrPayload, IOErrTag);
ioerr_ctor!(var_ioerr, CliEnvIOErr, CliEnvIOErrPayload, CliEnvIOErrTag);

fn path_result(r: std::io::Result<std::path::PathBuf>) -> CliEnvCwdResult {
    match r {
        Ok(p) => CliEnvCwdResult { payload: CliEnvCwdResultPayload { ok: ManuallyDrop::new(native(p.as_os_str())) }, tag: CliEnvCwdResultTag::Ok },
        Err(e) => CliEnvCwdResult { payload: CliEnvCwdResultPayload { err: ManuallyDrop::new(env_ioerr(&e)) }, tag: CliEnvCwdResultTag::Err },
    }
}

/// `CliEnv.cwd! : {} => Try(OsStr, [Io(IOErr)])`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__cwd() -> CliEnvCwdResult { path_result(std::env::current_dir()) }
/// `CliEnv.exe_path! : {} => Try(OsStr, [Io(IOErr)])`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__exe_path() -> CliEnvCwdResult { path_result(std::env::current_exe()) }
/// `CliEnv.temp_dir! : {} => OsStr`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__temp_dir() -> OsStr { native(std::env::temp_dir().as_os_str()) }

/// `CliExit.exit! : I32 => {}` — does not return.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cli_host__exit(code: i32) -> ! {
    std::process::exit(code)
}
