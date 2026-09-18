//! The confined root's alias walk, apart from the rest of fs-core so that
//! `tests/alias-walk` can compile this same file and test it: `trantor test`
//! runs a package's `tests/` suites, not the unit tests inside a host crate.

use std::path::{Path, PathBuf};

/// `aliased_rest` with the canonicalize step passed in, so a test can count
/// how many prefixes the walk resolves.
pub fn aliased_rest_by(
    cand: &Path,
    canonical_base: &Path,
    mut canonicalize: impl FnMut(&Path) -> std::io::Result<PathBuf>,
) -> Option<PathBuf> {
    use std::path::Component;
    let parts: Vec<Component> = cand.components().collect();
    let plain = parts.iter().take_while(|c| matches!(c, Component::RootDir | Component::Normal(_))).count();
    (1..=plain)
        .map_while(|k| canonicalize(&parts[..k].iter().collect::<PathBuf>()).ok().map(|resolved| (k, resolved)))
        .find(|(_, resolved)| resolved == canonical_base)
        .map(|(k, _)| parts[k..].iter().collect())
}
