"""Checks that a built installer is fit to publish.

  python release_package_check.py --out-dir src/out/Velloc \
      --installer ../VellocSetup/VellocSetup.exe \
      --version 1.149.2.3 --require-signed

Fails unless:
- the chrome.packed.7z embedded in mini_installer.exe (resource B7) is the
  one in the out dir, and its chrome.7z holds exactly one version manifest,
  under Chrome-bin\\<version>\\;
- with --require-signed, mini_installer.exe and the installer have a Valid
  Authenticode signature;
- both carry ProductVersion <version>.

build.sh runs it at the end of `package`; a published release must pass it
with --require-signed.
"""

import argparse
import ctypes
import os
import re
import subprocess
import sys
import tempfile
from ctypes import wintypes

HERE = os.path.dirname(os.path.abspath(__file__))
SEVEN_ZIP = os.path.join(HERE, "src", "third_party", "lzma_sdk", "bin",
                         "host_platform", "7za.exe")
VERSION_MANIFEST = re.compile(r"^\d+\.\d+\.\d+\.\d+\.manifest$")
LOAD_LIBRARY_AS_DATAFILE = 0x2


class CheckError(Exception):
    pass


def check_archive_names(names, version):
    """`names`: chrome.7z member paths. Raises CheckError on a problem."""
    prefix = f"Chrome-bin\\{version}\\"
    in_version = {n[len(prefix):] for n in names if n.startswith(prefix)}
    if not in_version:
        raise CheckError(f"chrome.7z has no {prefix} directory")
    manifests = sorted(n for n in in_version if VERSION_MANIFEST.match(n))
    if manifests != [f"{version}.manifest"]:
        raise CheckError(f"version manifests in chrome.7z: {manifests}, "
                         f"expected only {version}.manifest")


def embedded_resource(exe, res_type, name):
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.LoadLibraryExW.restype = wintypes.HMODULE
    kernel32.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD]
    kernel32.FindResourceW.restype = wintypes.HRSRC
    kernel32.FindResourceW.argtypes = [wintypes.HMODULE, wintypes.LPCWSTR, wintypes.LPCWSTR]
    kernel32.LoadResource.restype = wintypes.HGLOBAL
    kernel32.LoadResource.argtypes = [wintypes.HMODULE, wintypes.HRSRC]
    kernel32.LockResource.restype = ctypes.c_void_p
    kernel32.LockResource.argtypes = [wintypes.HGLOBAL]
    kernel32.SizeofResource.restype = wintypes.DWORD
    kernel32.SizeofResource.argtypes = [wintypes.HMODULE, wintypes.HRSRC]
    kernel32.FreeLibrary.argtypes = [wintypes.HMODULE]
    module = kernel32.LoadLibraryExW(os.path.abspath(exe), None, LOAD_LIBRARY_AS_DATAFILE)
    if not module:
        raise CheckError(f"cannot open {exe}")
    try:
        found = kernel32.FindResourceW(module, name, res_type)
        if not found:
            raise CheckError(f"{exe} has no {res_type}/{name} resource")
        size = kernel32.SizeofResource(module, found)
        pointer = kernel32.LockResource(kernel32.LoadResource(module, found))
        return ctypes.string_at(pointer, size)
    finally:
        kernel32.FreeLibrary(module)


def seven_zip(*args):
    result = subprocess.run([SEVEN_ZIP, *args], capture_output=True)
    if result.returncode != 0:
        raise CheckError(f"7za {' '.join(args)}: {result.stderr.decode(errors='replace')}")
    return result.stdout


def archive_names(archive):
    listing = seven_zip("l", "-slt", archive).decode("utf-8", "replace")
    return [line[len("Path = "):] for line in listing.splitlines()
            if line.startswith("Path = ")][1:]


def extract_chrome_7z(out_dir, temp):
    """Checks mini_installer.exe embeds the out dir's chrome.packed.7z, then
    extracts its chrome.7z into `temp` and returns that path."""
    mini = os.path.join(out_dir, "mini_installer.exe")
    packed = os.path.join(out_dir, "chrome.packed.7z")
    with open(packed, "rb") as handle:
        if embedded_resource(mini, "B7", "chrome.packed.7z") != handle.read():
            raise CheckError("mini_installer.exe does not embed the out dir's chrome.packed.7z")
    seven_zip("e", f"-o{temp}", packed, "chrome.7z")
    return os.path.join(temp, "chrome.7z")


def powershell(script):
    result = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                            capture_output=True, text=True)
    return result.stdout.strip()


def check_binary(path, version, require_signed):
    quoted = path.replace("'", "''")
    product = powershell(f"(Get-Item -LiteralPath '{quoted}').VersionInfo.ProductVersion")
    if product != version:
        raise CheckError(f"{path}: ProductVersion {product!r}, expected {version}")
    if require_signed:
        status = powershell(f"(Get-AuthenticodeSignature -LiteralPath '{quoted}').Status")
        if status != "Valid":
            raise CheckError(f"{path}: Authenticode status {status!r}, expected Valid")


def run(out_dir, installer, version, require_signed):
    with tempfile.TemporaryDirectory() as temp:
        check_archive_names(archive_names(extract_chrome_7z(out_dir, temp)), version)
    for path in (os.path.join(out_dir, "mini_installer.exe"), installer):
        check_binary(path, version, require_signed)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--installer", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--require-signed", action="store_true")
    args = parser.parse_args(argv)
    try:
        run(args.out_dir, args.installer, args.version, args.require_signed)
    except (CheckError, OSError, ValueError) as error:
        print(f"release_package_check: FAIL: {error}", file=sys.stderr)
        return 1
    signed = "signed" if args.require_signed else "signature NOT checked"
    print(f"release_package_check: OK {args.version}, {signed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
