#!/usr/bin/env bash
# Tests for release_assets.sh.
#   bash release_assets_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# shellcheck source=release_assets.sh
. "$HERE/release_assets.sh"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# The installer selects beta by a "beta" substring in its own name.
case "$(lower "$VELLOC_STABLE_ASSET_NAME")" in
  *beta*) fail "stable asset name contains beta" ;;
  *) pass "stable asset name does not select beta" ;;
esac
case "$(lower "$VELLOC_BETA_ASSET_NAME")" in
  *beta*) pass "beta asset name selects beta" ;;
  *) fail "beta asset name lacks beta" ;;
esac

# The setup dir sits beside the workspace unless overridden.
got="$(VELLOC_SETUP_DIR='' velloc_setup_dir /d/project/velloc)"
if [ "$got" = "/d/project/VellocSetup" ]; then
  pass "default setup dir is beside the workspace"
else
  fail "default setup dir is $got"
fi
got="$(VELLOC_SETUP_DIR=/e/out velloc_setup_dir /d/project/velloc)"
if [ "$got" = "/e/out" ]; then
  pass "VELLOC_SETUP_DIR overrides the setup dir"
else
  fail "override gave $got"
fi

# The installer moves out of the build dir; the beta asset is a byte copy.
mkdir -p "$TMP/installer" "$TMP/setup"
built="$TMP/installer/Velloc Code Setup.exe"
printf 'signed installer bytes' >"$built"
printf 'stale' >"$TMP/setup/$VELLOC_BETA_ASSET_NAME"
if velloc_place_release_assets "$built" "$TMP/setup" >/dev/null; then
  pass "placing succeeds"
else
  fail "placing failed"
fi
if [ -e "$built" ]; then
  fail "installer left in the build dir"
else
  pass "build dir no longer holds the installer"
fi
for name in "$VELLOC_STABLE_ASSET_NAME" "$VELLOC_BETA_ASSET_NAME"; do
  if [ "$(cat "$TMP/setup/$name" 2>/dev/null)" = "signed installer bytes" ]; then
    pass "$name holds the installer's bytes"
  else
    fail "$name does not hold the installer's bytes"
  fi
done

# A missing setup dir is created.
printf 'x' >"$built"
if velloc_place_release_assets "$built" "$TMP/new/setup" >/dev/null &&
    [ -f "$TMP/new/setup/$VELLOC_STABLE_ASSET_NAME" ]; then
  pass "missing setup dir is created"
else
  fail "missing setup dir not created"
fi

# A missing installer fails and writes nothing.
mkdir -p "$TMP/empty"
if velloc_place_release_assets "$TMP/missing.exe" "$TMP/empty" 2>/dev/null; then
  fail "missing installer accepted"
else
  pass "missing installer rejected"
fi
if [ -e "$TMP/empty/$VELLOC_STABLE_ASSET_NAME" ]; then
  fail "asset written without an installer"
else
  pass "nothing written without an installer"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
