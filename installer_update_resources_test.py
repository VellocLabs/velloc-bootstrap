"""Tests installer_update_resources.py against a real PE file.

  python installer_update_resources_test.py

A copy of a system executable gets B7/BL resources planted under a
non-default language (as rc.exe emits them), then the script replaces them.
"""

import ctypes
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from ctypes import wintypes

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import installer_update_resources as update_resources  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "installer_update_resources.py")
LANG = 0x0409  # en-US: what rc.exe stamps on packed_files.rc

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.BeginUpdateResourceW.restype = wintypes.HANDLE
kernel32.BeginUpdateResourceW.argtypes = [wintypes.LPCWSTR, wintypes.BOOL]
kernel32.UpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.LPCWSTR,
                                     wintypes.LPCWSTR, wintypes.WORD,
                                     ctypes.c_void_p, wintypes.DWORD]
kernel32.EndUpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.BOOL]
kernel32.LoadLibraryExW.restype = wintypes.HMODULE
kernel32.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE,
                                    wintypes.DWORD]
kernel32.FindResourceExW.restype = wintypes.HANDLE
kernel32.FindResourceExW.argtypes = [wintypes.HMODULE, wintypes.LPCWSTR,
                                     wintypes.LPCWSTR, wintypes.WORD]
kernel32.SizeofResource.restype = wintypes.DWORD
kernel32.SizeofResource.argtypes = [wintypes.HMODULE, wintypes.HANDLE]
kernel32.LoadResource.restype = wintypes.HANDLE
kernel32.LoadResource.argtypes = [wintypes.HMODULE, wintypes.HANDLE]
kernel32.LockResource.restype = ctypes.c_void_p
kernel32.LockResource.argtypes = [wintypes.HANDLE]
kernel32.FreeLibrary.argtypes = [wintypes.HMODULE]


def plant(exe, resources):
  handle = kernel32.BeginUpdateResourceW(exe, False)
  assert handle
  for res_type, name, data in resources:
    buffer = ctypes.create_string_buffer(data, len(data))
    assert kernel32.UpdateResourceW(handle, res_type, name, LANG, buffer,
                                    len(data))
  assert kernel32.EndUpdateResourceW(handle, False)


def read(exe, res_type, name, lang):
  module = kernel32.LoadLibraryExW(exe, None, 0x2)
  assert module
  try:
    found = kernel32.FindResourceExW(module, res_type, name, lang)
    if not found:
      return None
    size = kernel32.SizeofResource(module, found)
    pointer = kernel32.LockResource(kernel32.LoadResource(module, found))
    return ctypes.string_at(pointer, size)
  finally:
    kernel32.FreeLibrary(module)


class UpdateResourcesTest(unittest.TestCase):

  def setUp(self):
    self.dir = tempfile.mkdtemp()
    self.exe = os.path.join(self.dir, "mini_installer.exe")
    shutil.copy(os.path.join(os.environ["SystemRoot"], "System32",
                             "whoami.exe"), self.exe)
    plant(self.exe, [("B7", "CHROME.PACKED.7Z", b"old-archive"),
                     ("BL", "SETUP.EX_", b"old-setup")])

  def tearDown(self):
    shutil.rmtree(self.dir, ignore_errors=True)

  def write(self, name, data):
    path = os.path.join(self.dir, name)
    with open(path, "wb") as f:
      f.write(data)
    return path

  def run_script(self, *specs):
    return subprocess.run([sys.executable, SCRIPT, self.exe, *specs],
                          capture_output=True, text=True)

  def test_replaces_in_place_keeping_language(self):
    archive = self.write("chrome.packed.7z", b"signed-archive" * 64)
    setup = self.write("setup.ex_", b"signed-setup")
    result = self.run_script("B7=chrome.packed.7z=" + archive,
                             "BL=setup.ex_=" + setup)
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(read(self.exe, "B7", "CHROME.PACKED.7Z", LANG),
                     b"signed-archive" * 64)
    self.assertEqual(read(self.exe, "BL", "SETUP.EX_", LANG), b"signed-setup")
    # Replaced, not added: still exactly one language per resource.
    self.assertEqual(update_resources.languages(self.exe, "B7",
                                                "CHROME.PACKED.7Z"), [LANG])
    self.assertEqual(update_resources.languages(self.exe, "BL", "SETUP.EX_"),
                     [LANG])

  def test_missing_resource_fails_and_changes_nothing(self):
    archive = self.write("chrome.packed.7z", b"signed-archive")
    result = self.run_script("B7=chrome.packed.7z=" + archive,
                             "B7=renamed.7z=" + archive)
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("no B7 resource named RENAMED.7Z", result.stderr)
    self.assertEqual(read(self.exe, "B7", "CHROME.PACKED.7Z", LANG),
                     b"old-archive")


if __name__ == "__main__":
  unittest.main()
