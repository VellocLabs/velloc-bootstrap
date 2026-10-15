#!/usr/bin/env bash
# Tests for installer_signing.sh against a stub signtool.
#   bash installer_signing_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# Stub signtool: records each invocation's argv, one line per call; exits
# with $STUB_EXIT (default 0).
STUB="$TMP/signtool.sh"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
# `verify /pa /q <file>` is the "already signed?" probe: signed only when the
# file is named in $STUB_SIGNED.
if [ "$1" = verify ] && [ "$3" = /q ]; then
  grep -qxF "$4" "${STUB_SIGNED:-/dev/null}" 2>/dev/null && exit 0
  # Files unpacked into a temp dir are named by basename alone.
  grep -qxF "$(basename "${4//\\//}")" "${STUB_SIGNED_NAMES:-/dev/null}" 2>/dev/null
  exit $?
fi
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$STUB"
export STUB_LOG="$TMP/calls.log"
touch "$TMP/Azure.CodeSigning.Dlib.dll" "$TMP/Setup.exe"

# Each case runs in a fresh subshell with a clean signing environment.
run_case() {
  (
    unset VELLOC_SIGN VELLOC_SIGN_ENDPOINT VELLOC_SIGN_ACCOUNT VELLOC_SIGN_PROFILE \
      VELLOC_SIGN_DLIB VELLOC_SIGNTOOL VELLOC_SIGN_TIMESTAMP VELLOC_SIGN_CONFIG
    WORKSPACE_DIR="$TMP/workspace"
    OUT_BASE="$TMP/out"
    VELLOC_SIGN_WORK_DIR="$TMP/signing"
    # shellcheck source=installer_signing.sh
    . "$HERE/installer_signing.sh"
    "$@"
  )
}

configure() {
  VELLOC_SIGN_ENDPOINT=https://eus.codesigning.azure.net
  VELLOC_SIGN_ACCOUNT=velloc-signing
  VELLOC_SIGN_PROFILE=velloc-public
  VELLOC_SIGN_DLIB="$TMP/Azure.CodeSigning.Dlib.dll"
  VELLOC_SIGNTOOL="$STUB"
}

# 1. Signing is on unless opted out — a signed package is the default.
case_default_on() { velloc_sign_enabled; }
run_case case_default_on && pass "signing on by default" || fail "signing on by default"

case_off() { VELLOC_SIGN=0; ! velloc_sign_enabled; }
run_case case_off && pass "VELLOC_SIGN=0 turns signing off" || fail "VELLOC_SIGN=0 turns signing off"

# 2. The local config file is sourced and can flip the switch.
case_config_file() {
  VELLOC_SIGN_CONFIG="$TMP/signing.local.env"
  printf 'VELLOC_SIGN=1\nVELLOC_SIGN_ACCOUNT=from-file\n' >"$VELLOC_SIGN_CONFIG"
  velloc_sign_load_config
  velloc_sign_enabled && [ "$VELLOC_SIGN_ACCOUNT" = from-file ]
}
run_case case_config_file && pass "signing.local.env is loaded" || fail "signing.local.env is loaded"

case_env_beats_config() {
  VELLOC_SIGN=1
  VELLOC_SIGN_CONFIG="$TMP/signing.local.env"
  printf 'VELLOC_SIGN=0
VELLOC_SIGN_ACCOUNT=from-file
' >"$VELLOC_SIGN_CONFIG"
  velloc_sign_load_config
  velloc_sign_enabled && [ "$VELLOC_SIGN_ACCOUNT" = from-file ]
}
run_case case_env_beats_config && pass "env VELLOC_SIGN outranks the file" || fail "env VELLOC_SIGN outranks the file"

case_config_absent() { velloc_sign_load_config; velloc_sign_enabled; }
run_case case_config_absent && pass "missing config file is not an error" || fail "missing config file is not an error"

# 3. Incomplete configuration fails loudly and names what is missing.
case_missing() {
  VELLOC_SIGN_ACCOUNT=velloc-signing
  local out
  if out="$(velloc_sign_check_config)"; then return 1; fi
  [[ "$out" == *VELLOC_SIGN_ENDPOINT* && "$out" == *VELLOC_SIGN_PROFILE* \
    && "$out" == *VELLOC_SIGN_DLIB* && "$out" != *"missing: VELLOC_SIGN_ACCOUNT"* ]]
}
run_case case_missing && pass "missing settings are reported" || fail "missing settings are reported"

case_missing_dlib() {
  configure
  VELLOC_SIGN_DLIB="$TMP/nope.dll"
  ! velloc_sign_check_config >/dev/null
}
run_case case_missing_dlib && pass "absent dlib fails" || fail "absent dlib fails"

case_missing_signtool() {
  configure
  VELLOC_SIGNTOOL="$TMP/no-signtool.exe"
  ! velloc_sign_check_config >/dev/null
}
run_case case_missing_signtool && pass "absent signtool fails" || fail "absent signtool fails"

# 4. A complete configuration writes the dlib metadata file.
case_metadata() {
  configure
  velloc_sign_check_config >/dev/null || return 1
  grep -q '"Endpoint": "https://eus.codesigning.azure.net"' "$VELLOC_SIGN_METADATA" \
    && grep -q '"CodeSigningAccountName": "velloc-signing"' "$VELLOC_SIGN_METADATA" \
    && grep -q '"CertificateProfileName": "velloc-public"' "$VELLOC_SIGN_METADATA"
}
run_case case_metadata && pass "metadata.json written" || fail "metadata.json written"

# 5. Signing calls signtool sign through the dlib, then verifies.
case_sign() {
  configure
  rm -f "$STUB_LOG"
  velloc_sign_check_config >/dev/null || return 1
  velloc_sign_file "$TMP/Setup.exe" >/dev/null || return 1
  [ "$(wc -l <"$STUB_LOG")" -eq 2 ] || return 1
  local sign verify
  sign="$(sed -n 1p "$STUB_LOG")"
  verify="$(sed -n 2p "$STUB_LOG")"
  [[ "$sign" == "sign "* && "$sign" == *"/fd SHA256"* && "$sign" == *"/td SHA256"* \
    && "$sign" == *"/tr http://timestamp.acs.microsoft.com"* \
    && "$sign" == *"/dlib "*Azure.CodeSigning.Dlib.dll* \
    && "$sign" == *"/dmdf "*metadata.json* && "$sign" == *Setup.exe ]] || return 1
  [[ "$verify" == "verify /pa "*Setup.exe ]]
}
run_case case_sign && pass "sign then verify" || fail "sign then verify"

case_timestamp_override() {
  configure
  VELLOC_SIGN_TIMESTAMP=http://ts.example
  rm -f "$STUB_LOG"
  velloc_sign_check_config >/dev/null && velloc_sign_file "$TMP/Setup.exe" >/dev/null || return 1
  grep -q '/tr http://ts.example' "$STUB_LOG"
}
run_case case_timestamp_override && pass "timestamp override" || fail "timestamp override"

# 6. A signtool failure propagates — no silently unsigned package.
case_sign_fails() {
  configure
  velloc_sign_check_config >/dev/null || return 1
  ! STUB_EXIT=1 velloc_sign_file "$TMP/Setup.exe" >/dev/null
}
run_case case_sign_fails && pass "signtool failure propagates" || fail "signtool failure propagates"

case_sign_unconfigured() { ! velloc_sign_file "$TMP/Setup.exe" >/dev/null; }
run_case case_sign_unconfigured && pass "sign before check fails" || fail "sign before check fails"

case_sign_missing_file() {
  configure
  velloc_sign_check_config >/dev/null || return 1
  ! velloc_sign_file "$TMP/absent.exe" >/dev/null
}
run_case case_sign_missing_file && pass "missing target fails" || fail "missing target fails"

# 7. Payload: the signed set is chrome.release's .exe/.dll entries that exist.
make_payload_fixture() {
  PAYLOAD_OUT="$TMP/payload_out"
  rm -rf "$PAYLOAD_OUT"
  mkdir -p "$PAYLOAD_OUT/WidevineCdm/_platform_specific/win_x64"
  touch "$PAYLOAD_OUT/chrome.exe" "$PAYLOAD_OUT/chrome.dll" "$PAYLOAD_OUT/chrome_elf.dll" \
    "$PAYLOAD_OUT/resources.pak" "$PAYLOAD_OUT/setup.exe" \
    "$PAYLOAD_OUT/WidevineCdm/_platform_specific/win_x64/widevinecdm.dll"
  RELEASE="$TMP/chrome.release"
  printf '%s\r\n' \
    '# comment: chrome.exe: %(ChromeDir)s\' \
    '[GENERAL]' \
    'chrome.exe: %(ChromeDir)s\' \
    'chrome.dll: %(VersionDir)s\' \
    'chrome_elf.dll: %(VersionDir)s\' \
    'not_built.dll: %(VersionDir)s\' \
    'resources.pak: %(VersionDir)s\' \
    'WidevineCdm\_platform_specific\win_x64\widevinecdm.dll: %(VersionDir)s\WidevineCdm\' \
    'WidevineCdm\_platform_specific\win_x64\widevinecdm.dll.sig: %(VersionDir)s\WidevineCdm\' \
    '' \
    '[HIDPI]' \
    'chrome_100_percent.pak: %(VersionDir)s\' >"$RELEASE"
}

case_list_payload() {
  make_payload_fixture
  local got expected
  got="$(velloc_sign_list_payload "$RELEASE" "$PAYLOAD_OUT")"
  expected="$PAYLOAD_OUT/chrome.exe
$PAYLOAD_OUT/chrome.dll
$PAYLOAD_OUT/chrome_elf.dll
$PAYLOAD_OUT/WidevineCdm/_platform_specific/win_x64/widevinecdm.dll"
  [ "$got" = "$expected" ] || { echo "got: $got"; return 1; }
}
run_case case_list_payload && pass "payload list from chrome.release" || fail "payload list from chrome.release"

# Signs every unsigned payload binary plus setup.exe; skips already-signed
# ones (a vendor's, or ours from a previous run).
case_sign_payload() {
  make_payload_fixture
  configure
  velloc_sign_check_config >/dev/null || return 1
  export STUB_SIGNED="$TMP/already_signed.txt"
  velloc_sign_win_path "$PAYLOAD_OUT/WidevineCdm/_platform_specific/win_x64/widevinecdm.dll" >"$STUB_SIGNED"
  rm -f "$STUB_LOG"
  local out
  out="$(velloc_sign_payload "$RELEASE" "$PAYLOAD_OUT")" || { echo "$out"; return 1; }
  [[ "$out" == *"signed 4, already signed 1"* ]] || { echo "$out"; return 1; }
  local f
  for f in chrome.exe chrome.dll chrome_elf.dll setup.exe; do
    grep -q "^sign .*$f\$" "$STUB_LOG" || { echo "not signed: $f"; return 1; }
  done
  ! grep -q '^sign .*widevinecdm.dll$' "$STUB_LOG"
}
run_case case_sign_payload && pass "payload signed, signed ones skipped" || fail "payload signed, signed ones skipped"

case_sign_payload_fails() {
  make_payload_fixture
  configure
  velloc_sign_check_config >/dev/null || return 1
  ! STUB_EXIT=1 velloc_sign_payload "$RELEASE" "$PAYLOAD_OUT" >/dev/null
}
run_case case_sign_payload_fails && pass "payload signing failure propagates" || fail "payload signing failure propagates"

case_sign_payload_empty() {
  configure
  velloc_sign_check_config >/dev/null || return 1
  mkdir -p "$TMP/empty_out"
  printf 'chrome.dll: %%(VersionDir)s\\\n' >"$TMP/empty.release"
  ! velloc_sign_payload "$TMP/empty.release" "$TMP/empty_out" >/dev/null
}
run_case case_sign_payload_empty && pass "empty payload fails" || fail "empty payload fails"

# 8. Re-pack without ninja. The archive command comes from the out dir's
# ninja files, unescaped.
make_ninja_fixture() {
  NINJA_OUT="$TMP/ninja_out"
  rm -rf "$NINJA_OUT"
  mkdir -p "$NINJA_OUT/gen/mi/temp_installer_archive/Chrome-bin/1.0"
  FAKE_PY="$TMP/fake_python.sh"
  cat >"$FAKE_PY" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$PWD"): $*" >>"$FAKE_PY_LOG"
exit "${FAKE_PY_EXIT:-0}"
EOF
  chmod +x "$FAKE_PY"
  export FAKE_PY_LOG="$TMP/fake_py.log"
  rm -f "$FAKE_PY_LOG"
  printf '%s\n' \
    'rule __other_rule' \
    '  command = nope' \
    'rule __chrome_installer_mini_installer_mini_installer_archive___build_toolchain_win_win_clang_x64__rule' \
    "  command = $FAKE_PY archive.py --build_dir . --staging_dir gen/mi --drive D\$:/x" \
    '  description = ACTION' >"$NINJA_OUT/toolchain.ninja"
}

case_archive_command() {
  make_ninja_fixture
  local got
  got="$(velloc_sign_archive_command "$NINJA_OUT")" || return 1
  [ "$got" = "$FAKE_PY archive.py --build_dir . --staging_dir gen/mi --drive D:/x" ] || { echo "got: $got"; return 1; }
  [ "$(velloc_sign_staging_dir "$NINJA_OUT")" = "$NINJA_OUT/gen/mi/temp_installer_archive" ]
}
run_case case_archive_command && pass "archive command read from ninja" || fail "archive command read from ninja"

case_archive_command_missing() {
  mkdir -p "$TMP/no_ninja"
  ! velloc_sign_archive_command "$TMP/no_ninja" 2>/dev/null
}
run_case case_archive_command_missing && pass "missing archive rule fails" || fail "missing archive rule fails"

# Runs the archive action in the out dir, then swaps both archives into
# mini_installer.exe — and never touches ninja.
case_repack() {
  make_ninja_fixture
  velloc_sign_repack "$NINJA_OUT" >/dev/null || return 1
  local first second
  first="$(sed -n 1p "$FAKE_PY_LOG")"
  second="$(sed -n 2p "$FAKE_PY_LOG")"
  [[ "$first" == "ninja_out: archive.py --build_dir . --staging_dir gen/mi"* ]] || { echo "1: $first"; return 1; }
  [[ "$second" == *"installer_update_resources.py "*"mini_installer.exe B7=chrome.packed.7z="*"chrome.packed.7z BL=setup.ex_="*"setup.ex_" ]] || { echo "2: $second"; return 1; }
  [ "$(wc -l <"$FAKE_PY_LOG")" -eq 2 ]
}
run_case case_repack && pass "repack runs archive then resource swap" || fail "repack runs archive then resource swap"

case_repack_fails() {
  make_ninja_fixture
  ! FAKE_PY_EXIT=1 velloc_sign_repack "$NINJA_OUT" >/dev/null
}
run_case case_repack_fails && pass "archive failure propagates" || fail "archive failure propagates"

# The guard that pins the shipped bug: a packed binary without a signature
# fails the package instead of shipping.
make_packed_fixture() {
  make_ninja_fixture
  local bin="$NINJA_OUT/gen/mi/temp_installer_archive/Chrome-bin"
  touch "$bin/chrome.exe" "$bin/1.0/chrome.dll" "$bin/1.0/resources.pak" "$NINJA_OUT/setup.exe"
  configure
  export STUB_SIGNED="$TMP/packed_signed.txt"
  : >"$STUB_SIGNED"
  local f
  for f in "$bin/chrome.exe" "$bin/1.0/chrome.dll" "$NINJA_OUT/setup.exe"; do
    velloc_sign_win_path "$f" >>"$STUB_SIGNED"
  done
}

case_verify_packed() {
  make_packed_fixture
  local out
  out="$(velloc_sign_verify_packed "$NINJA_OUT")" || { echo "$out"; return 1; }
  [[ "$out" == *"3 binaries, all signed"* ]] || { echo "$out"; return 1; }
}
run_case case_verify_packed && pass "signed packed payload passes" || fail "signed packed payload passes"

case_verify_packed_unsigned() {
  make_packed_fixture
  grep -v 'chrome.dll$' "$STUB_SIGNED" >"$STUB_SIGNED.tmp" && mv "$STUB_SIGNED.tmp" "$STUB_SIGNED"
  local out
  out="$(velloc_sign_verify_packed "$NINJA_OUT")" && { echo "$out"; return 1; }
  [[ "$out" == *"packed but unsigned: "*"chrome.dll"* ]] || { echo "$out"; return 1; }
}
run_case case_verify_packed_unsigned && pass "unsigned packed binary fails" || fail "unsigned packed binary fails"

# build.sh must not re-run ninja to repack: siso relinks the signed binaries.
case_build_wiring() {
  local body
  body="$(sed -n '/^build_velloc_mini_installer() {/,/^}/p' "$HERE/build.sh")"
  [[ "$body" == *"velloc_sign_repack"* && "$body" == *"velloc_sign_verify_packed"* ]] || return 1
  [ "$(grep -c 'autoninja' <<<"$body")" -le 2 ]
}
run_case case_build_wiring && pass "build.sh repacks without ninja" || fail "build.sh repacks without ninja"

# 9. The resource swap itself, against a real PE file.
python "$HERE/installer_update_resources_test.py" >/dev/null 2>&1 \
  && pass "installer_update_resources.py" || fail "installer_update_resources.py"

# The bundled rg.exe ships through the real chrome.release, so the payload
# signing must pick it up like chrome.dll (no separate signing step exists).
REAL_RELEASE="$HERE/src/chrome/installer/mini_installer/chrome.release"
if [ -f "$REAL_RELEASE" ]; then
  case_real_release_signs_rg() {
    local out="$TMP/real_out"
    mkdir -p "$out"
    touch "$out/rg.exe" "$out/chrome.dll"
    local got
    got="$(velloc_sign_list_payload "$REAL_RELEASE" "$out")"
    printf '%s\n' "$got" | grep -qxF "$out/rg.exe"
  }
  run_case case_real_release_signs_rg && pass "real chrome.release puts rg.exe in the signed payload" \
    || fail "real chrome.release puts rg.exe in the signed payload"
else
  echo "SKIP: real chrome.release ($REAL_RELEASE not present in this checkout)"
fi

# 10. The NSIS wrapper's own plug-in DLLs (unpacked into $PLUGINSDIR at run
# time) are signed copies — Store policy 10.2.9: every PE file signed.
make_plugin_fixture() {
  PLUGIN_SRC="$TMP/nsis/Plugins/x86-unicode"
  PLUGIN_DEST="$TMP/out/nsis-plugins/x86-unicode"
  rm -rf "$TMP/nsis" "$PLUGIN_DEST"
  mkdir -p "$PLUGIN_SRC"
  echo stock >"$PLUGIN_SRC/nsDialogs.dll"
  echo stock >"$PLUGIN_SRC/System.dll"
  echo text >"$PLUGIN_SRC/readme.txt"
  configure
  velloc_sign_check_config >/dev/null || return 1
  export STUB_SIGNED="$TMP/plugins_signed.txt"
  : >"$STUB_SIGNED"
}

case_nsis_plugins() {
  make_plugin_fixture || return 1
  rm -f "$STUB_LOG"
  local got
  got="$(velloc_sign_nsis_plugins "$PLUGIN_SRC" "$PLUGIN_DEST" 2>/dev/null)" || return 1
  [ "$got" = "$PLUGIN_DEST" ] || { echo "got: $got"; return 1; }
  [ -f "$PLUGIN_DEST/nsDialogs.dll" ] && [ -f "$PLUGIN_DEST/System.dll" ] \
    && [ ! -e "$PLUGIN_DEST/readme.txt" ] || return 1
  grep -q '^sign .*nsDialogs.dll$' "$STUB_LOG" && grep -q '^sign .*System.dll$' "$STUB_LOG" \
    || return 1
  # The stock dir is left as it was: only the copies are signed.
  ! grep -q "^sign .*$(basename "$TMP")/nsis/" "$STUB_LOG"
}
run_case case_nsis_plugins && pass "NSIS plug-ins copied and signed" || fail "NSIS plug-ins copied and signed"

# A re-run keeps the signed copies and signs nothing; an NSIS upgrade (a
# source newer than its copy) is copied and signed again.
case_nsis_plugins_rerun() {
  make_plugin_fixture || return 1
  velloc_sign_nsis_plugins "$PLUGIN_SRC" "$PLUGIN_DEST" >/dev/null 2>&1 || return 1
  echo signed >"$PLUGIN_DEST/System.dll"
  velloc_sign_win_path "$PLUGIN_DEST/System.dll" >>"$STUB_SIGNED"
  velloc_sign_win_path "$PLUGIN_DEST/nsDialogs.dll" >>"$STUB_SIGNED"
  touch -d '2000-01-01' "$PLUGIN_SRC/System.dll" "$PLUGIN_SRC/nsDialogs.dll"
  rm -f "$STUB_LOG"
  velloc_sign_nsis_plugins "$PLUGIN_SRC" "$PLUGIN_DEST" >/dev/null 2>&1 || return 1
  ! grep -q '^sign ' "$STUB_LOG" 2>/dev/null || return 1
  [ "$(cat "$PLUGIN_DEST/System.dll")" = signed ] || return 1
  touch -d '2099-01-01' "$PLUGIN_SRC/System.dll"
  velloc_sign_nsis_plugins "$PLUGIN_SRC" "$PLUGIN_DEST" >/dev/null 2>&1 || return 1
  [ "$(cat "$PLUGIN_DEST/System.dll")" = stock ]
}
run_case case_nsis_plugins_rerun && pass "NSIS plug-in copies kept; an upgrade is re-copied" \
  || fail "NSIS plug-in copies kept; an upgrade is re-copied"

case_nsis_plugins_fails() {
  make_plugin_fixture || return 1
  ! STUB_EXIT=1 velloc_sign_nsis_plugins "$PLUGIN_SRC" "$PLUGIN_DEST" >/dev/null 2>&1
}
run_case case_nsis_plugins_fails && pass "plug-in signing failure propagates" || fail "plug-in signing failure propagates"

case_nsis_plugins_missing() {
  configure
  ! velloc_sign_nsis_plugins "$TMP/no-nsis/Plugins/x86-unicode" "$TMP/out/p" >/dev/null 2>&1
}
run_case case_nsis_plugins_missing && pass "missing plug-in dir fails" || fail "missing plug-in dir fails"

# The finished installer is unpacked and every binary in it verified. A stub
# 7z "unpacks" the names in $STUB_7Z_FILES into its -o dir.
SEVENZIP_STUB="$TMP/7z.sh"
cat >"$SEVENZIP_STUB" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    -o*) dir="${arg#-o}" ;;
  esac
done
command -v cygpath >/dev/null 2>&1 && dir="$(cygpath -u "$dir")"
for name in $STUB_7Z_FILES; do echo x >"$dir/$name"; done
EOF
chmod +x "$SEVENZIP_STUB"

case_verify_nsis_output() {
  configure
  export VELLOC_7Z="$SEVENZIP_STUB" STUB_7Z_FILES="mini_installer.exe nsDialogs.dll System.dll"
  export STUB_SIGNED_NAMES="$TMP/signed_names.txt"
  printf '%s\n' mini_installer.exe nsDialogs.dll System.dll >"$STUB_SIGNED_NAMES"
  local out
  out="$(velloc_sign_verify_nsis_output "$TMP/Setup.exe")" || { echo "$out"; return 1; }
  [[ "$out" == *"3 binaries, all signed"* ]] || { echo "$out"; return 1; }
}
run_case case_verify_nsis_output && pass "signed installer contents pass" || fail "signed installer contents pass"

# The guard that pins the Store finding: a stock, unsigned plug-in inside the
# installer fails the package and is named.
case_verify_nsis_output_unsigned() {
  configure
  export VELLOC_7Z="$SEVENZIP_STUB" STUB_7Z_FILES="mini_installer.exe nsDialogs.dll System.dll"
  export STUB_SIGNED_NAMES="$TMP/signed_names.txt"
  printf '%s\n' mini_installer.exe System.dll >"$STUB_SIGNED_NAMES"
  local out
  out="$(velloc_sign_verify_nsis_output "$TMP/Setup.exe")" && { echo "$out"; return 1; }
  [[ "$out" == *"unsigned binary: nsDialogs.dll"* && "$out" == *"1 of 3"* ]] || { echo "$out"; return 1; }
}
run_case case_verify_nsis_output_unsigned && pass "unsigned plug-in inside the installer fails" \
  || fail "unsigned plug-in inside the installer fails"

case_verify_nsis_output_no_7z() {
  configure
  export VELLOC_7Z="$TMP/no-7z.exe" PATH="/usr/bin"
  velloc_sign_find_7z() { echo "ERROR: 7-Zip not found" >&2; return 1; }
  ! velloc_sign_verify_nsis_output "$TMP/Setup.exe" >/dev/null 2>&1
}
run_case case_verify_nsis_output_no_7z && pass "no 7-Zip fails the check" || fail "no 7-Zip fails the check"

case_nsis_build_wiring() {
  local body
  body="$(sed -n '/^build_velloc_nsis_installer() {/,/^}/p' "$HERE/build.sh")"
  [[ "$body" == *"velloc_sign_nsis_plugins"* && "$body" == *"-DVELLOC_NSIS_PLUGIN_DIR="* \
    && "$body" == *"velloc_sign_verify_nsis_output"* ]]
}
run_case case_nsis_build_wiring && pass "build.sh packs signed plug-ins and verifies the installer" \
  || fail "build.sh packs signed plug-ins and verifies the installer"

# The wrapper must take the define; and with a real makensis, a dir added by
# !addplugindir must outrank NSIS's stock plug-ins (else the signed copies
# would be ignored and the stock ones packed).
REAL_NSI="$HERE/src/custom_browser/installer/custom_browser_installer_wrapper.nsi"
if [ -f "$REAL_NSI" ]; then
  grep -qF '!addplugindir /x86-unicode "${VELLOC_NSIS_PLUGIN_DIR}"' "$REAL_NSI" \
    && pass "wrapper .nsi adds the signed plug-in dir" || fail "wrapper .nsi adds the signed plug-in dir"
else
  echo "SKIP: wrapper .nsi ($REAL_NSI not present in this checkout)"
fi
MAKENSIS="$(command -v makensis 2>/dev/null || true)"
[ -z "$MAKENSIS" ] && [ -f "/c/Program Files (x86)/NSIS/makensis.exe" ] && MAKENSIS="/c/Program Files (x86)/NSIS/makensis.exe"
REAL_7Z="$(command -v 7z 2>/dev/null || true)"
[ -z "$REAL_7Z" ] && [ -f "/c/Program Files/7-Zip/7z.exe" ] && REAL_7Z="/c/Program Files/7-Zip/7z.exe"
if [ -n "$MAKENSIS" ] && [ -n "$REAL_7Z" ] && command -v cygpath >/dev/null 2>&1; then
  case_addplugindir_outranks_stock() {
    local work="$TMP/plugindir" stock
    stock="$(dirname "$MAKENSIS")/Plugins/x86-unicode"
    mkdir -p "$work/plug"
    cp "$stock/nsDialogs.dll" "$stock/System.dll" "$work/plug/"
    printf 'VELLOCMARK' >>"$work/plug/nsDialogs.dll"
    printf 'VELLOCMARK' >>"$work/plug/System.dll"
    cat >"$work/t.nsi" <<'NSI'
!include "MUI2.nsh"
!ifdef VELLOC_NSIS_PLUGIN_DIR
  !addplugindir /x86-unicode "${VELLOC_NSIS_PLUGIN_DIR}"
!endif
OutFile "t.exe"
RequestExecutionLevel user
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_LANGUAGE "English"
Section
  System::Call 'kernel32::GetTickCount()i.r0'
SectionEnd
NSI
    ( cd "$work" && MSYS2_ARG_CONV_EXCL="*" "$MAKENSIS" /V1 \
      "-DVELLOC_NSIS_PLUGIN_DIR=$(cygpath -w "$work/plug")" t.nsi ) >/dev/null || return 1
    MSYS2_ARG_CONV_EXCL="*" "$REAL_7Z" e -y -o"$(cygpath -w "$work/x")" \
      "$(cygpath -w "$work/t.exe")" '*.dll' -r >/dev/null || return 1
    [ "$(tail -c 10 "$work/x/nsDialogs.dll")" = VELLOCMARK ] \
      && [ "$(tail -c 10 "$work/x/System.dll")" = VELLOCMARK ]
  }
  run_case case_addplugindir_outranks_stock && pass "makensis packs the !addplugindir copies, not the stock plug-ins" \
    || fail "makensis packs the !addplugindir copies, not the stock plug-ins"
else
  echo "SKIP: makensis + 7-Zip not both available (plug-in precedence not checked)"
fi

# 11. build.sh still parses with the wiring in place.
bash -n "$HERE/build.sh" && pass "build.sh parses" || fail "build.sh parses"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
