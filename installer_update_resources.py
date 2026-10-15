"""Replaces resources in a PE file in place, keeping each one's language.

  python installer_update_resources.py <exe> <TYPE>=<NAME>=<file> ...

build.sh uses it to put a re-packed, signed payload (chrome.packed.7z as B7,
setup.ex_ as BL) into an already-linked mini_installer.exe. Relinking through
ninja is not an option: siso sees the signed binaries as modified outputs and
relinks them, which strips the signatures before they are packed.

Only resources that already exist are replaced; a missing one is an error,
so a renamed resource cannot silently leave the old payload in place.
"""

import ctypes
import sys
from ctypes import wintypes

LOAD_LIBRARY_AS_DATAFILE = 0x2

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.LoadLibraryExW.restype = wintypes.HMODULE
kernel32.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE,
                                    wintypes.DWORD]
kernel32.FreeLibrary.argtypes = [wintypes.HMODULE]
EnumLangProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE,
                                  wintypes.LPCWSTR, wintypes.LPCWSTR,
                                  wintypes.WORD, ctypes.c_void_p)
kernel32.EnumResourceLanguagesW.argtypes = [wintypes.HMODULE, wintypes.LPCWSTR,
                                            wintypes.LPCWSTR, EnumLangProc,
                                            ctypes.c_void_p]
kernel32.BeginUpdateResourceW.restype = wintypes.HANDLE
kernel32.BeginUpdateResourceW.argtypes = [wintypes.LPCWSTR, wintypes.BOOL]
kernel32.UpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.LPCWSTR,
                                     wintypes.LPCWSTR, wintypes.WORD,
                                     ctypes.c_void_p, wintypes.DWORD]
kernel32.EndUpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.BOOL]


def fail(message):
  sys.exit("ERROR: " + message)


def languages(exe, res_type, name):
  module = kernel32.LoadLibraryExW(exe, None, LOAD_LIBRARY_AS_DATAFILE)
  if not module:
    fail("cannot load %s (error %d)" % (exe, ctypes.get_last_error()))
  found = []

  def collect(_module, _type, _name, lang, _param):
    found.append(lang)
    return True

  try:
    kernel32.EnumResourceLanguagesW(module, res_type, name,
                                    EnumLangProc(collect), None)
  finally:
    kernel32.FreeLibrary(module)
  return found


def main(argv):
  if len(argv) < 3:
    fail("usage: installer_update_resources.py <exe> <TYPE>=<NAME>=<file> ...")
  exe = argv[1]
  updates = []
  for spec in argv[2:]:
    parts = spec.split("=", 2)
    if len(parts) != 3:
      fail("bad resource spec: " + spec)
    res_type, name, path = parts[0].upper(), parts[1].upper(), parts[2]
    langs = languages(exe, res_type, name)
    if not langs:
      fail("%s has no %s resource named %s" % (exe, res_type, name))
    with open(path, "rb") as f:
      data = f.read()
    updates.append((res_type, name, langs, data))

  handle = kernel32.BeginUpdateResourceW(exe, False)
  if not handle:
    fail("BeginUpdateResource failed on %s (error %d)"
         % (exe, ctypes.get_last_error()))
  for res_type, name, langs, data in updates:
    buffer = ctypes.create_string_buffer(data, len(data))
    for lang in langs:
      if not kernel32.UpdateResourceW(handle, res_type, name, lang, buffer,
                                      len(data)):
        error = ctypes.get_last_error()
        kernel32.EndUpdateResourceW(handle, True)
        fail("UpdateResource %s/%s failed (error %d)" % (res_type, name, error))
    print("==> replaced %s %s (%d bytes)" % (res_type, name, len(data)))
  if not kernel32.EndUpdateResourceW(handle, False):
    fail("EndUpdateResource failed on %s (error %d)"
         % (exe, ctypes.get_last_error()))


if __name__ == "__main__":
  main(sys.argv)
