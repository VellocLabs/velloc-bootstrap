# Places the built installer as the two release assets, in VELLOC_SETUP_DIR
# (default: VellocSetup beside the workspace, where release_tag.py publish
# reads them). Sourced by build.sh; tested by release_assets_test.sh.
#
# One build serves both channels: a file name containing "beta" (any case)
# makes the installer select the beta runtime channel (G-3). The beta asset
# is a byte copy, so a signed installer stays signed.

VELLOC_STABLE_ASSET_NAME="VellocSetup.exe"
VELLOC_BETA_ASSET_NAME="VellocSetup-beta.exe"

# velloc_setup_dir <workspace dir>
velloc_setup_dir() {
  if [ -n "${VELLOC_SETUP_DIR:-}" ]; then
    echo "$VELLOC_SETUP_DIR"
  else
    echo "$(dirname "$1")/VellocSetup"
  fi
}

# velloc_place_release_assets <built installer> <setup dir>
# Moves the installer to <setup dir>/VellocSetup.exe and copies it to
# <setup dir>/VellocSetup-beta.exe, replacing older assets.
velloc_place_release_assets() {
  local installer="$1" setup_dir="$2"
  if [ ! -f "$installer" ]; then
    echo "ERROR: no installer at $installer." >&2
    return 1
  fi
  mkdir -p "$setup_dir" || return 1
  local stable="$setup_dir/$VELLOC_STABLE_ASSET_NAME"
  local beta="$setup_dir/$VELLOC_BETA_ASSET_NAME"
  mv -f "$installer" "$stable" || return 1
  cp -f "$stable" "$beta" || return 1
  echo "==> Release assets: $stable (stable), $beta (beta)"
}
