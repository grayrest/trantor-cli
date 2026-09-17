# Both surfaces are in the offer, and only the intended one of each. The hosted
# modules are the ones an interface names; if exports ever loses them the
# package silently becomes shim-only, and only the raw-layer suite would notice.
set -euo pipefail
python3 surfaces.py "$PKG"
