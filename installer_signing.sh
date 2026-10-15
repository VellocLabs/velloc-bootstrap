# Code signing for the Windows installer, via Azure Trusted Signing
# (Artifact Signing). Sourced by build.sh; installer_signing_test.sh
# exercises it against a stub signtool.
#
# ON by default: every package and reinstall is signed, and a missing or
# incomplete configuration fails the build rather than shipping unsigned.
# Opt out per run with `build.sh package --no-sign`, or VELLOC_SIGN=0 in the
# environment / in signing.local.env.
#
# Configuration (environment, or signing.local.env in the workspace root —
# gitignored; copy signing.example.env):
#   VELLOC_SIGN_ENDPOINT   e.g. https://eus.codesigning.azure.net
#   VELLOC_SIGN_ACCOUNT    Trusted Signing account name
#   VELLOC_SIGN_PROFILE    certificate profile name
#   VELLOC_SIGN_DLIB       path to Azure.CodeSigning.Dlib.dll (x64)
#   VELLOC_SIGNTOOL        optional; default = newest Windows Kits x64 signtool
#   VELLOC_SIGN_TIMESTAMP  optional; default http://timestamp.acs.microsoft.com
# Authentication is the dlib's DefaultAzureCredential: `az login` once
# (or AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_CLIENT_SECRET).

VELLOC_SIGN_METADATA=""
VELLOC_SIGN_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

velloc_sign_load_config() {
  local config="${VELLOC_SIGN_CONFIG:-$WORKSPACE_DIR/signing.local.env}"
  if [ -f "$config" ]; then
    # The environment outranks the file for the on/off switch, so
    # `VELLOC_SIGN=0 ./build.sh` works with a copied example (VELLOC_SIGN=1).
    local env_sign="${VELLOC_SIGN-}" env_sign_set="${VELLOC_SIGN+x}"
    # shellcheck disable=SC1090
    . "$config"
    if [ -n "$env_sign_set" ]; then
      VELLOC_SIGN="$env_sign"
    fi
  fi
}

velloc_sign_enabled() {
  [ "${VELLOC_SIGN:-1}" = "1" ]
}

velloc_sign_win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    echo "$1"
  fi
}

velloc_sign_find_signtool() {
  if [ -n "${VELLOC_SIGNTOOL:-}" ]; then
    echo "$VELLOC_SIGNTOOL"
    return 0
  fi
  local found=""
  local candidate
  shopt -s nullglob
  # Version directories sort lexically in the right order (10.0.22621.0 <
  # 10.0.26100.0), so the last match is the newest SDK.
  for candidate in "/c/Program Files (x86)/Windows Kits/10/bin/"*/x64/signtool.exe; do
    found="$candidate"
  done
  shopt -u nullglob
  if [ -z "$found" ]; then
    return 1
  fi
  echo "$found"
}

# Fails loudly — and before any long build starts — when signing is on but
# not fully configured. A package that silently comes out unsigned is the
# failure this exists to stop.
velloc_sign_check_config() {
  local missing=()
  local name
  for name in VELLOC_SIGN_ENDPOINT VELLOC_SIGN_ACCOUNT VELLOC_SIGN_PROFILE VELLOC_SIGN_DLIB; do
    if [ -z "${!name:-}" ]; then
      missing+=("$name")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: signing is on but not configured; missing: ${missing[*]}"
    echo "       Set them in the environment or in signing.local.env (see signing.example.env)."
    return 1
  fi
  if [ ! -f "$VELLOC_SIGN_DLIB" ]; then
    echo "ERROR: VELLOC_SIGN_DLIB not found: $VELLOC_SIGN_DLIB"
    return 1
  fi
  local signtool=""
  if ! signtool="$(velloc_sign_find_signtool)" || [ ! -f "$signtool" ]; then
    echo "ERROR: signtool.exe not found. Install the Windows SDK or set VELLOC_SIGNTOOL."
    return 1
  fi
  VELLOC_SIGNTOOL="$signtool"

  local out_dir="${VELLOC_SIGN_WORK_DIR:-$OUT_BASE/signing}"
  mkdir -p "$out_dir"
  VELLOC_SIGN_METADATA="$out_dir/metadata.json"
  cat >"$VELLOC_SIGN_METADATA" <<EOF
{
  "Endpoint": "$VELLOC_SIGN_ENDPOINT",
  "CodeSigningAccountName": "$VELLOC_SIGN_ACCOUNT",
  "CertificateProfileName": "$VELLOC_SIGN_PROFILE"
}
EOF
  echo "==> Signing ON: $VELLOC_SIGN_ACCOUNT / $VELLOC_SIGN_PROFILE"
}

# Signs one file, then verifies it against the Windows trust policy.
velloc_sign_file() {
  local file="$1"
  if [ -z "$VELLOC_SIGN_METADATA" ]; then
    echo "ERROR: velloc_sign_file called before velloc_sign_check_config."
    return 1
  fi
  if [ ! -f "$file" ]; then
    echo "ERROR: file to sign not found: $file"
    return 1
  fi
  local timestamp="${VELLOC_SIGN_TIMESTAMP:-http://timestamp.acs.microsoft.com}"
  local file_win dlib_win metadata_win
  file_win="$(velloc_sign_win_path "$file")"
  dlib_win="$(velloc_sign_win_path "$VELLOC_SIGN_DLIB")"
  metadata_win="$(velloc_sign_win_path "$VELLOC_SIGN_METADATA")"

  echo "==> signtool sign $file_win"
  MSYS2_ARG_CONV_EXCL="*" "$VELLOC_SIGNTOOL" sign /v /debug /fd SHA256 \
    /tr "$timestamp" /td SHA256 \
    /dlib "$dlib_win" /dmdf "$metadata_win" \
    "$file_win" || {
    echo "ERROR: signing failed for $file_win"
    return 1
  }
  MSYS2_ARG_CONV_EXCL="*" "$VELLOC_SIGNTOOL" verify /pa "$file_win" || {
    echo "ERROR: signature verification failed for $file_win"
    return 1
  }
}

# Lists the payload binaries — every .exe/.dll that chrome.release packs into
# chrome.7z and that exists in the build output — one absolute path per line.
# chrome.release is the installer's own manifest, so the signed set cannot
# drift from the shipped set. Paths in it are relative to the out dir.
velloc_sign_list_payload() {
  local release_file="$1"
  local out_dir="$2"
  local line rel
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*|'['*) continue ;;
    esac
    rel="${line%%:*}"
    rel="${rel//'\'//}"
    case "$rel" in
      *.exe|*.EXE|*.dll|*.DLL) ;;
      *) continue ;;
    esac
    if [ -f "$out_dir/$rel" ]; then
      echo "$out_dir/$rel"
    fi
  done <"$release_file"
}

# True when the file already carries a valid Authenticode signature — ours
# from an earlier run, or a vendor's (Widevine, d3dcompiler_47, dxcompiler).
velloc_sign_is_signed() {
  local file_win
  file_win="$(velloc_sign_win_path "$1")"
  MSYS2_ARG_CONV_EXCL="*" "$VELLOC_SIGNTOOL" verify /pa /q "$file_win" >/dev/null 2>&1
}

# Signs every unsigned payload binary plus setup.exe (packed separately as
# setup.ex_). Run after building mini_installer, then velloc_sign_repack —
# never a second ninja run: siso sees the signed binaries as modified outputs
# and relinks them, stripping the signatures before they are packed.
velloc_sign_payload() {
  local release_file="$1"
  local out_dir="$2"
  local files=()
  local file
  while IFS= read -r file; do
    files+=("$file")
  done < <(velloc_sign_list_payload "$release_file" "$out_dir")
  if [ -f "$out_dir/setup.exe" ]; then
    files+=("$out_dir/setup.exe")
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    echo "ERROR: no payload binaries found in $out_dir (manifest $release_file)."
    return 1
  fi
  local signed=0 skipped=0
  for file in "${files[@]}"; do
    if velloc_sign_is_signed "$file"; then
      skipped=$((skipped + 1))
      continue
    fi
    velloc_sign_file "$file" || return 1
    signed=$((signed + 1))
  done
  echo "==> Payload: signed $signed, already signed $skipped"
}

# Prints the mini_installer_archive action's command, read from the out dir's
# ninja files with its '$:' / '$ ' escapes undone — the exact create_installer_archive.py call the
# build makes, so a repack cannot drift from what ninja would pack.
velloc_sign_archive_command() {
  local out_dir="$1"
  local cmd
  cmd="$(grep -h -A1 '^rule __chrome_installer_mini_installer_mini_installer_archive___'     "$out_dir"/*.ninja 2>/dev/null | sed -n 's/^  command = //p' | head -n 1)"
  if [ -z "$cmd" ]; then
    echo "ERROR: mini_installer_archive rule not found in $out_dir/*.ninja." >&2
    return 1
  fi
  cmd="${cmd//'$:'/:}"
  cmd="${cmd//'$ '/ }"
  printf '%s
' "$cmd"
}

# The archive staging dir (--staging_dir of the archive command, relative to
# the out dir) plus the temp_installer_archive/ the script packs from.
velloc_sign_staging_dir() {
  local out_dir="$1" cmd rest
  cmd="$(velloc_sign_archive_command "$out_dir")" || return 1
  rest="${cmd#*--staging_dir }"
  if [ "$rest" = "$cmd" ]; then
    echo "ERROR: archive command has no --staging_dir." >&2
    return 1
  fi
  echo "$out_dir/${rest%% *}/temp_installer_archive"
}

# Re-packs the signed payload without ninja: re-runs the archive action
# (chrome.7z, chrome.packed.7z, setup.ex_ from the now-signed binaries) and
# swaps the new archives into the already-linked mini_installer.exe.
velloc_sign_repack() {
  local out_dir="$1"
  local cmd python
  cmd="$(velloc_sign_archive_command "$out_dir")" || return 1
  python="${cmd%% *}"
  echo "==> Repack signed payload: create_installer_archive.py"
  ( cd "$out_dir" && eval "$cmd" ) || {
    echo "ERROR: create_installer_archive.py failed."
    return 1
  }
  echo "==> Repack signed payload: mini_installer.exe resources"
  "$python" "$VELLOC_SIGN_HERE/installer_update_resources.py"     "$(velloc_sign_win_path "$out_dir/mini_installer.exe")"     "B7=chrome.packed.7z=$(velloc_sign_win_path "$out_dir/chrome.packed.7z")"     "BL=setup.ex_=$(velloc_sign_win_path "$out_dir/setup.ex_")" || {
    echo "ERROR: replacing the mini_installer.exe payload failed."
    return 1
  }
}

# Proves the packed payload is signed: every .exe/.dll the archive was staged
# from, plus setup.exe, must verify. Runs after velloc_sign_repack, so an
# unsigned binary here is exactly an unsigned binary in the installer.
velloc_sign_verify_packed() {
  local out_dir="$1"
  local staging file bad=0 count=0
  staging="$(velloc_sign_staging_dir "$out_dir")" || return 1
  if [ ! -d "$staging" ]; then
    echo "ERROR: archive staging dir not found: $staging"
    return 1
  fi
  while IFS= read -r file; do
    count=$((count + 1))
    if ! velloc_sign_is_signed "$file"; then
      echo "ERROR: packed but unsigned: $file"
      bad=$((bad + 1))
    fi
  done < <(find "$staging" "$out_dir/setup.exe" -type f \( -iname '*.exe' -o -iname '*.dll' \))
  if [ "$count" -eq 0 ]; then
    echo "ERROR: no packed binaries found under $staging."
    return 1
  fi
  if [ "$bad" -ne 0 ]; then
    echo "ERROR: $bad of $count packed binaries are unsigned."
    return 1
  fi
  echo "==> Packed payload: $count binaries, all signed"
}

# The NSIS wrapper unpacks its own plug-in DLLs (nsDialogs.dll for the MUI
# pages, System.dll, ...) into $PLUGINSDIR at run time, and the stock ones in
# NSIS's Plugins dir are unsigned — Store policy 10.2.9 wants every PE file of
# the installer signed. Copies the plug-in dir to dest_dir and signs each
# unsigned copy; makensis then packs from dest_dir (`!addplugindir`, which
# outranks the stock dir). A copy is kept while it is newer than its source,
# so a re-run re-signs nothing and an NSIS upgrade is picked up. Prints
# dest_dir.
velloc_sign_nsis_plugins() {
  local src_dir="$1"
  local dest_dir="$2"
  local src name dest count=0 signed=0
  if [ ! -d "$src_dir" ]; then
    echo "ERROR: NSIS plug-in dir not found: $src_dir" >&2
    return 1
  fi
  mkdir -p "$dest_dir" || return 1
  for src in "$src_dir"/*.dll; do
    [ -f "$src" ] || continue
    count=$((count + 1))
    name="$(basename "$src")"
    dest="$dest_dir/$name"
    if [ ! -f "$dest" ] || [ "$src" -nt "$dest" ]; then
      cp -f "$src" "$dest" || return 1
    fi
    if velloc_sign_is_signed "$dest"; then
      continue
    fi
    velloc_sign_file "$dest" >&2 || return 1
    signed=$((signed + 1))
  done
  if [ "$count" -eq 0 ]; then
    echo "ERROR: no plug-in DLLs in $src_dir." >&2
    return 1
  fi
  echo "==> NSIS plug-ins: $count, signed $signed now" >&2
  echo "$dest_dir"
}

# 7-Zip, which reads an NSIS installer's packed files: VELLOC_7Z, else 7z on
# PATH, else the default install dir.
velloc_sign_find_7z() {
  local candidate
  for candidate in "${VELLOC_7Z:-}" "$(command -v 7z 2>/dev/null)" \
    "/c/Program Files/7-Zip/7z.exe" "C:/Program Files/7-Zip/7z.exe"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "ERROR: 7-Zip not found (set VELLOC_7Z); it is needed to prove the installer's packed binaries are signed." >&2
  return 1
}

# Proves the finished installer ships no unsigned PE file: unpacks every
# .exe/.dll it carries ($PLUGINSDIR's plug-ins, mini_installer.exe) and
# verifies each. The installer itself is verified by velloc_sign_file.
velloc_sign_verify_nsis_output() {
  local installer="$1"
  local sevenzip work file bad=0 count=0
  sevenzip="$(velloc_sign_find_7z)" || return 1
  work="$(mktemp -d)" || return 1
  MSYS2_ARG_CONV_EXCL="*" "$sevenzip" e -y -o"$(velloc_sign_win_path "$work")" \
    "$(velloc_sign_win_path "$installer")" '*.dll' '*.exe' -r >/dev/null || {
    echo "ERROR: could not unpack $installer."
    rm -rf "$work"
    return 1
  }
  while IFS= read -r file; do
    count=$((count + 1))
    if ! velloc_sign_is_signed "$file"; then
      echo "ERROR: installer carries an unsigned binary: $(basename "$file")"
      bad=$((bad + 1))
    fi
  done < <(find "$work" -type f \( -iname '*.exe' -o -iname '*.dll' \))
  rm -rf "$work"
  if [ "$count" -eq 0 ]; then
    echo "ERROR: no binaries found inside $installer."
    return 1
  fi
  if [ "$bad" -ne 0 ]; then
    echo "ERROR: $bad of $count binaries inside the installer are unsigned."
    return 1
  fi
  echo "==> Installer contents: $count binaries, all signed"
}
