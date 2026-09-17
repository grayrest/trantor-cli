//! Component `cell`: host-backed mutable state (D12). Fixture-minimal: one
//! process-global Str slot behind a Mutex. Proves a Roc shim can hold state
//! across calls through the host. Both boundaries extern "C-unwind" (H0d).
use trantor_abi as abi;
use abi::RocStr;
use std::sync::Mutex;

static SLOT: Mutex<String> = Mutex::new(String::new());

/// hosted `Cwd.set! : Str => {}`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cwd_host__set(value: RocStr) {
    *SLOT.lock().unwrap() = value.as_str().to_string();
    unsafe { value.decref(abi::host()); } // owned arg (B0): released after copying out
}

/// hosted `Cwd.get! : {} => Str`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__cwd_host__get() -> RocStr {
    RocStr::from_str(&SLOT.lock().unwrap(), abi::host())
}
