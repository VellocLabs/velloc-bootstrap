#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPOT_TOOLS_DIR="$WORKSPACE_DIR/depot_tools"
ARGS_DIR="$WORKSPACE_DIR/args"
SRC_DIR="$WORKSPACE_DIR/src"
OUT_BASE="$SRC_DIR/out"

if [ ! -d "$ARGS_DIR" ]; then
  echo "ERROR: args/ not found in workspace root."
  exit 1
fi

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: src/ not found. Run ./bootstrap.sh to sync."
  exit 1
fi

if [ -d "$DEPOT_TOOLS_DIR" ]; then
  export PATH="$DEPOT_TOOLS_DIR:$PATH"
fi

NSIS_DIR_WIN='C:\Program Files (x86)\NSIS'
NSIS_DIRS=(
  "$NSIS_DIR_WIN"
  "/c/Program Files (x86)/NSIS"
  "/mnt/c/Program Files (x86)/NSIS"
  "C:/Program Files (x86)/NSIS"
)
if command -v cygpath >/dev/null 2>&1; then
  NSIS_DIRS=(
    "$(cygpath -u "$NSIS_DIR_WIN")"
    "${NSIS_DIRS[@]}"
  )
fi
for nsis_dir in "${NSIS_DIRS[@]}"; do
  if [ -n "$nsis_dir" ] && [ -d "$nsis_dir" ]; then
    export PATH="$nsis_dir:$PATH"
    break
  fi
done

if ! command -v autoninja >/dev/null 2>&1; then
  echo "ERROR: autoninja not found in PATH."
  exit 1
fi

# Pre-start the sccache daemon. Each `sccache clang-cl ...` invocation
# checks whether a server is alive on port 4226 and spawns one if not.
# When dozens of compile workers launch in parallel at -j 15, two of
# them can race the "spawn" step and the loser dies with WSAEADDRINUSE
# (os error 10048), failing that compile step and aborting siso.
# Starting the daemon up-front avoids the race; the command is a no-op
# if a server is already healthy.
if command -v sccache >/dev/null 2>&1; then
  sccache --start-server >/dev/null 2>&1 || true
fi

# Redirect siso's own glog files off C:\Users\...\AppData\Local\Temp.
# A single long build can emit ~1.8 GiB of WARNING logs (one record per
# input-state mismatch), and historically a dozen accumulated runs
# filled the C: drive, after which siso would FATAL with "not enough
# space" mid-compile. siso is just a Go binary using glog, so the
# standard GLOG_log_dir env var moves the destination. We keep the
# logs alongside the build output, which lives on a roomy drive.
SISO_LOG_DIR="$OUT_BASE/siso-logs"
mkdir -p "$SISO_LOG_DIR"
export GLOG_log_dir="$SISO_LOG_DIR"

ensure_gn_available() {
  if ! command -v gn >/dev/null 2>&1; then
    echo "ERROR: gn not found in PATH."
    exit 1
  fi

  local gn_bin=""
  local candidates=(
    "$SRC_DIR/buildtools/win/gn.exe"
    "$SRC_DIR/buildtools/win/gn/gn.exe"
  )

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      gn_bin="$candidate"
      break
    fi
  done

  if [ -z "$gn_bin" ]; then
    if command -v gclient >/dev/null 2>&1; then
      echo "==> gn binary missing; running gclient runhooks"
      (cd "$WORKSPACE_DIR" && gclient runhooks)
    else
      echo "ERROR: gn binary missing and gclient not found in PATH."
      exit 1
    fi
  fi

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      return 0
    fi
  done

  echo "ERROR: gn binary still missing after runhooks. Try ./bootstrap.sh then re-run build."
  exit 1
}

shopt -s nullglob
arg_files=()
for f in "$ARGS_DIR"/*; do
  [ -f "$f" ] || continue
  arg_files+=("$(basename "$f")")
done
shopt -u nullglob

if [ "${#arg_files[@]}" -eq 0 ]; then
  echo "ERROR: no args files found in $ARGS_DIR."
  exit 1
fi

arg_names=()
for f in "${arg_files[@]}"; do
  base="${f%.*}"
  arg_names+=("$base")
done

default_index=0
for i in "${!arg_names[@]}"; do
  if [ "${arg_names[$i]}" = "Debug" ]; then
    default_index=$i
    break
  fi
done
default_choice=$((default_index + 1))
last_choice=$default_choice
last_arg_choice=$default_choice
last_mini_action=4
VELLOC_MINI_INSTALLER_PATH=""
VELLOC_SETUP_EXE=""
VELLOC_NSIS_INSTALLER_PATH=""

ensure_gn_available

# shellcheck source=installer_signing.sh
. "$WORKSPACE_DIR/installer_signing.sh"
velloc_sign_load_config

ensure_makensis_available() {
  if command -v makensis >/dev/null 2>&1; then
    return 0
  fi
  if command -v makensis.exe >/dev/null 2>&1; then
    return 0
  fi

  echo "ERROR: makensis not found in PATH. Install NSIS or add makensis to PATH."
  exit 1
}

to_windows_path() {
  local input="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$input"
  else
    echo "$input"
  fi
}

ensure_gn_gen() {
  local out_dir="$1"
  if [ ! -f "$out_dir/build.ninja" ]; then
    echo "==> gn gen $out_dir"
    (
      cd "$SRC_DIR"
      gn gen "$out_dir"
    )
  fi
}

# Copy args.gn into the out dir only when content actually differs.
# Bare `cp -f` updates mtime even if content is unchanged, which trips ninja's
# build.ninja regen rule (args.gn is one of its inputs). gn gen then re-runs,
# which re-evaluates ~9000 BUILD.gn files, re-runs every exec_script, and
# re-stamps many generated headers. Even with restat, the cascading restat
# churn turns a no-op build into a long one — and any side effect that lands
# new content into a widely-included header (e.g. buildflags.h) cascades into
# a multi-thousand-file rebuild.
sync_args_gn() {
  local src="$1"
  local dst="$2"
  if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
    cp -f "$src" "$dst"
    echo "==> args.gn updated (content changed) -> $dst"
  fi
}

build_chrome() {
  local idx="$1"
  local name="${arg_names[$idx]}"
  local file="${arg_files[$idx]}"
  local out_dir="$OUT_BASE/$name"
  # Use a relative -C and cwd=$SRC_DIR so siso/ninja key their cache by
  # the same canonical build-dir path that the VS Code task uses
  # (.vscode/tasks.json runs from inside src/ with -C out/<name>). MSYS
  # otherwise rewrites the absolute POSIX path into mixed-separator
  # form (C:\...\src/out/Debug) which siso buckets separately
  # from the all-backslash form, invalidating every cached action.
  local rel_out="out/$name"

  mkdir -p "$out_dir"
  sync_args_gn "$ARGS_DIR/$file" "$out_dir/args.gn"

  ensure_gn_gen "$out_dir"

  echo "==> autoninja -C $rel_out chrome -j 15  (cwd=$SRC_DIR)"
  ( cd "$SRC_DIR" && autoninja -C "$rel_out" chrome -j 15 )
}

find_arg_index_by_name() {
  local target="$1"
  for i in "${!arg_names[@]}"; do
    if [ "${arg_names[$i]}" = "$target" ]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

build_mini_installer() {
  echo "==> Select args for mini_installer"
  for i in "${!arg_files[@]}"; do
    printf "%2d) %s\n" $((i + 1)) "${arg_files[$i]}"
  done

  read -r -p "Select args [1-${#arg_files[@]}] (default: $last_arg_choice): " choice
  if [ -z "$choice" ] || ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#arg_files[@]}" ]; then
    choice=$last_arg_choice
    local default_idx=$((choice - 1))
    echo "Invalid choice; defaulting to ${arg_files[$default_idx]}."
  else
    last_arg_choice=$choice
  fi

  local idx=$((choice - 1))
  local file="${arg_files[$idx]}"
  local name="${arg_names[$idx]}"
  local out_dir="$OUT_BASE/$name"
  # See build_chrome() for why we go relative + subshell-cd.
  local rel_out="out/$name"

  mkdir -p "$out_dir"
  sync_args_gn "$ARGS_DIR/$file" "$out_dir/args.gn"

  ensure_gn_gen "$out_dir"

  echo "==> autoninja -C $rel_out mini_installer -j 15  (cwd=$SRC_DIR)"
  ( cd "$SRC_DIR" && autoninja -C "$rel_out" mini_installer -j 15 )

  local mini_installer_path=""
  if ! mini_installer_path="$(resolve_mini_installer_path "$out_dir")"; then
    return
  fi

  local mini_dir=""
  mini_dir="$(cd "$(dirname "$mini_installer_path")" && pwd)"
  local setup_exe="$mini_dir/setup.exe"
  if [ ! -f "$setup_exe" ]; then
    echo "ERROR: setup.exe not found alongside mini_installer.exe in $mini_dir."
    return
  fi

  echo "==> Post-build actions:"
  echo " 1) uninstall + installer"
  echo " 2) installer"
  echo " 3) uninstall"
  echo " 4) exit"

  read -r -p "Select option [1-4] (default: $last_mini_action): " action
  if [ -z "$action" ] || ! [[ "$action" =~ ^[0-9]+$ ]] || [ "$action" -lt 1 ] || [ "$action" -gt 4 ]; then
    action=$last_mini_action
    echo "Invalid choice; defaulting to last selection."
  else
    last_mini_action=$action
  fi

  case "$action" in
    1)
      if run_setup_uninstall "$setup_exe"; then
        run_mini_installer "$mini_installer_path"
      else
        echo "Skipping installer because uninstall failed."
      fi
      ;;
    2)
      run_mini_installer "$mini_installer_path" || true
      ;;
    3)
      run_setup_uninstall "$setup_exe" || true
      ;;
    4)
      echo "Returning to main menu."
      ;;
  esac
}

build_velloc_mini_installer() {
  local idx=""
  if ! idx="$(find_arg_index_by_name "Velloc")"; then
    echo "ERROR: Velloc args not found in $ARGS_DIR."
    return 1
  fi

  local file="${arg_files[$idx]}"
  local name="${arg_names[$idx]}"
  local out_dir="$OUT_BASE/$name"
  # See build_chrome() for why we go relative + subshell-cd.
  local rel_out="out/$name"

  mkdir -p "$out_dir"
  sync_args_gn "$ARGS_DIR/$file" "$out_dir/args.gn"

  ensure_gn_gen "$out_dir"

  echo "==> autoninja -C $rel_out mini_installer -j 15  (cwd=$SRC_DIR)"
  ( cd "$SRC_DIR" && autoninja -C "$rel_out" mini_installer -j 15 )

  # Sign what the installer ships (chrome.exe, chrome.dll, setup.exe, ...),
  # then re-pack it without ninja: siso treats the signed binaries as
  # modified outputs and relinks them, which would pack unsigned copies.
  if velloc_sign_enabled; then
    velloc_sign_payload "$SRC_DIR/chrome/installer/mini_installer/chrome.release" "$out_dir" || return 1
    velloc_sign_repack "$out_dir" || return 1
    velloc_sign_verify_packed "$out_dir" || return 1
  fi

  local mini_installer_path=""
  if ! mini_installer_path="$(resolve_mini_installer_path "$out_dir")"; then
    return 1
  fi

  local mini_dir=""
  mini_dir="$(cd "$(dirname "$mini_installer_path")" && pwd)"
  local setup_exe="$mini_dir/setup.exe"
  if [ ! -f "$setup_exe" ]; then
    echo "ERROR: setup.exe not found alongside mini_installer.exe in $mini_dir."
    return 1
  fi

  VELLOC_MINI_INSTALLER_PATH="$mini_installer_path"
  VELLOC_SETUP_EXE="$setup_exe"

  # The NSIS wrapper embeds mini_installer.exe and runs it on the user's
  # machine, so it is signed before makensis packs it.
  if velloc_sign_enabled; then
    velloc_sign_file "$mini_installer_path"
  fi
}

build_velloc_nsis_installer() {
  local mini_installer_path="$1"
  local nsis_dir="$SRC_DIR/custom_browser/installer"
  local nsis_script="$nsis_dir/custom_browser_installer_wrapper.nsi"
  local nsis_script_win=""
  local master_prefs="$nsis_dir/master_preferences"
  # The display name (branding.json display_name, BRANDING PRODUCT_FULLNAME);
  # the install directory and registry keys stay "Velloc".
  local product_name="Velloc Code"
  local output_path="$nsis_dir/${product_name} Setup.exe"

  if [ ! -f "$nsis_script" ]; then
    echo "ERROR: NSIS script not found at $nsis_script."
    return 1
  fi
  if [ ! -f "$master_prefs" ]; then
    echo "ERROR: master_preferences not found at $master_prefs."
    return 1
  fi

  ensure_makensis_available

  local mini_installer_win=""
  local master_prefs_win=""
  mini_installer_win="$(to_windows_path "$mini_installer_path")"
  master_prefs_win="$(to_windows_path "$master_prefs")"
  nsis_script_win="$(to_windows_path "$nsis_script")"

  # The installer unpacks NSIS's own plug-in DLLs at run time; pack signed
  # copies of them (Store policy 10.2.9: every PE file signed).
  local plugin_defines=()
  if velloc_sign_enabled; then
    local makensis_dir="" plugin_dir=""
    makensis_dir="$(dirname "$(command -v makensis || command -v makensis.exe)")"
    plugin_dir="$(velloc_sign_nsis_plugins "$makensis_dir/Plugins/x86-unicode" \
      "$OUT_BASE/nsis-plugins/x86-unicode")" || return 1
    plugin_defines=("-DVELLOC_NSIS_PLUGIN_DIR=$(to_windows_path "$plugin_dir")")
  fi

  echo "==> makensis $nsis_script_win"
  (
    cd "$nsis_dir"
    MSYS2_ARG_CONV_EXCL="*" makensis \
      "-DPRODUCT_NAME=$product_name" \
      "-DMINI_INSTALLER_SOURCE=$mini_installer_win" \
      "-DMASTER_PREFERENCES_SOURCE=$master_prefs_win" \
      "${plugin_defines[@]}" \
      "$nsis_script_win"
  )

  if [ ! -f "$output_path" ]; then
    echo "ERROR: NSIS output not found at $output_path."
    return 1
  fi

  if velloc_sign_enabled; then
    velloc_sign_file "$output_path" || return 1
    velloc_sign_verify_nsis_output "$output_path" || return 1
  fi

  VELLOC_NSIS_INSTALLER_PATH="$output_path"
}

resolve_mini_installer_path() {
  local out_dir="$1"
  local mini_installer_path=""
  local candidates=(
    "$out_dir/mini_installer.exe"
    "$out_dir/mini_installer/mini_installer.exe"
  )

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      mini_installer_path="$candidate"
      break
    fi
  done

  if [ -z "$mini_installer_path" ]; then
    mini_installer_path="$(find "$out_dir" -maxdepth 3 -name "mini_installer.exe" -print -quit 2>/dev/null || true)"
  fi

  if [ -z "$mini_installer_path" ]; then
    echo "ERROR: mini_installer.exe not found under $out_dir."
    return 1
  fi

  echo "$mini_installer_path"
}

run_setup_uninstall() {
  local setup_exe="$1"
  echo "==> $setup_exe --uninstall"
  if ! "$setup_exe" --uninstall; then
    local status=$?
    echo "WARN: uninstall failed with exit code $status."
    return $status
  fi
  return 0
}

run_mini_installer() {
  local mini_installer_path="$1"
  echo "==> $mini_installer_path"
  if ! "$mini_installer_path"; then
    local status=$?
    echo "WARN: installer failed with exit code $status."
    return $status
  fi
  return 0
}

run_nsis_installer() {
  local nsis_installer_path="$1"
  echo "==> $nsis_installer_path"
  if ! "$nsis_installer_path"; then
    local status=$?
    echo "WARN: NSIS installer failed with exit code $status."
    return $status
  fi
  return 0
}

reinstall_velloc_nsis() {
  echo "==> Reinstall Velloc NSIS"
  if velloc_sign_enabled; then
    velloc_sign_check_config
  fi
  build_velloc_mini_installer
  build_velloc_nsis_installer "$VELLOC_MINI_INSTALLER_PATH"

  if run_setup_uninstall "$VELLOC_SETUP_EXE"; then
    run_nsis_installer "$VELLOC_NSIS_INSTALLER_PATH"
  else
    echo "Skipping NSIS installer because uninstall failed."
  fi
}

# Build the release package without touching the local install:
#   build.sh package [--sign | --no-sign]
#   build.sh reinstall [--sign | --no-sign]
# --sign / --no-sign override VELLOC_SIGN for this run. No arguments = menu.
package_velloc_nsis() {
  echo "==> Package Velloc NSIS"
  if velloc_sign_enabled; then
    velloc_sign_check_config
  else
    echo "==> Signing OFF (--no-sign / VELLOC_SIGN=0); this package is UNSIGNED"
  fi
  build_velloc_mini_installer
  build_velloc_nsis_installer "$VELLOC_MINI_INSTALLER_PATH"
  echo "==> Package: $VELLOC_NSIS_INSTALLER_PATH"
}

if [ "$#" -gt 0 ]; then
  command_name="$1"
  shift
  for flag in "$@"; do
    case "$flag" in
      --sign) VELLOC_SIGN=1 ;;
      --no-sign) VELLOC_SIGN=0 ;;
      *) echo "ERROR: unknown option: $flag"; exit 1 ;;
    esac
  done
  case "$command_name" in
    package) package_velloc_nsis ;;
    reinstall) reinstall_velloc_nsis ;;
    *) echo "Usage: build.sh [package|reinstall] [--sign|--no-sign]"; exit 1 ;;
  esac
  exit 0
fi

while true; do
  echo "==> Build options:"
  for i in "${!arg_names[@]}"; do
    printf "%2d) Build %s\n" $((i + 1)) "${arg_names[$i]}"
  done
  if velloc_sign_enabled; then sign_label="signed"; else sign_label="unsigned"; fi
  menu_build_mini=$(( ${#arg_names[@]} + 1 ))
  menu_reinstall_nsis=$(( ${#arg_names[@]} + 2 ))
  menu_package_nsis=$(( ${#arg_names[@]} + 3 ))
  menu_exit=$(( ${#arg_names[@]} + 4 ))
  printf "%2d) Build mini_installer\n" "$menu_build_mini"
  printf "%2d) Reinstall Velloc NSIS (%s)\n" "$menu_reinstall_nsis" "$sign_label"
  printf "%2d) Package Velloc NSIS, no install (%s)\n" "$menu_package_nsis" "$sign_label"
  printf "%2d) Exit\n" "$menu_exit"

  read -r -p "Select option [1-$menu_exit] (default: $last_choice): " choice
  if [ -z "$choice" ] || ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$menu_exit" ]; then
    choice=$last_choice
    echo "Invalid choice; defaulting to last selection."
  else
    last_choice=$choice
  fi

  if [ "$choice" -eq "$menu_exit" ]; then
    echo "Exiting."
    break
  elif [ "$choice" -eq "$menu_reinstall_nsis" ]; then
    reinstall_velloc_nsis
  elif [ "$choice" -eq "$menu_package_nsis" ]; then
    package_velloc_nsis
  elif [ "$choice" -eq "$menu_build_mini" ]; then
    build_mini_installer
  else
    build_chrome $((choice - 1))
  fi
done
