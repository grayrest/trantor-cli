//! roc:random host: OS entropy seeds (/dev/urandom; no crate dep).
use core::mem::ManuallyDrop;
use trantor_abi as abi;
use abi::*;
use std::io::Read;

fn entropy(buf: &mut [u8]) -> std::io::Result<()> { std::fs::File::open("/dev/urandom")?.read_exact(buf) }

/// An `IOErr` for this crate's leaves. Glue emits one twin per reach path
/// (`seed_u64!`'s is `RandomHostIOErr`); both are the same 10 variants.
///
/// Both arms built `Other(e.to_string())` whatever the errno was, so a
/// /dev/urandom the process may not open reached Roc as `Other("Permission
/// denied (os error 13)")` and a missing one as `Other("No such file or
/// directory (os error 2)")`, never the `PermissionDenied` or `NotFound` an
/// app matches on. The mapping is `ioerr_tag!`, the one every other reach path
/// in the package goes through.
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
ioerr_ctor!(seed_u64_ioerr, RandomHostIOErr, RandomHostIOErrPayload, RandomHostIOErrTag);
ioerr_ctor!(seed_u32_ioerr, IOErr, IOErrPayload, IOErrTag);

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__random_host__seed_u64() -> RandomHostSeedU64Result {
    let mut b = [0u8; 8];
    match entropy(&mut b) {
        Ok(()) => RandomHostSeedU64Result { payload: RandomHostSeedU64ResultPayload { ok: ManuallyDrop::new(u64::from_le_bytes(b)) }, tag: RandomHostSeedU64ResultTag::Ok },
        Err(e) => RandomHostSeedU64Result { payload: RandomHostSeedU64ResultPayload { err: ManuallyDrop::new(seed_u64_ioerr(&e)) }, tag: RandomHostSeedU64ResultTag::Err },
    }
}
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__random_host__seed_u32() -> RandomHostSeedU32Result {
    let mut b = [0u8; 4];
    match entropy(&mut b) {
        Ok(()) => RandomHostSeedU32Result { payload: RandomHostSeedU32ResultPayload { ok: ManuallyDrop::new(u32::from_le_bytes(b)) }, tag: RandomHostSeedU32ResultTag::Ok },
        Err(e) => RandomHostSeedU32Result { payload: RandomHostSeedU32ResultPayload { err: ManuallyDrop::new(seed_u32_ioerr(&e)) }, tag: RandomHostSeedU32ResultTag::Err },
    }
}
