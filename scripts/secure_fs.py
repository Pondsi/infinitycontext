#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Owner-only filesystem hardening for the InfinityContext archive.

Portable core: Python standard library only. No shell, no subprocess, no
network access.

Why this module exists
----------------------
The archive stores conversation history. On a shared machine the process umask
(commonly 0022) would create the archive directory as 0755 and the SQLite files
as 0644, so any other local account could read them. This module closes that
gap:

* POSIX   - directories are forced to 0700 and files to 0600; a new database
            file is created atomically with 0600, so it never exists with wider
            permissions (no check-then-chmod race).
* Windows - the DACL is replaced by a protected DACL that grants only the
            current user and LOCAL SYSTEM, using the documented Win32 security
            APIs through ctypes. No external program is started.

Policy
------
* a pre-existing archive directory owned by another account is refused
* a pre-existing archive directory that is merely too permissive is tightened
* if hardening is impossible (unsupported filesystem, API unavailable) a loud
  warning is printed and the caller records ``permissions_enforced: false``;
  archiving still proceeds so that a session is never lost
"""
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

IS_WINDOWS = sys.platform == "win32"

DIR_MODE = 0o700
FILE_MODE = 0o600


class UnsafeArchiveError(PermissionError):
    """The archive path is not safe to store sensitive data in."""


def _warn(message: str) -> None:
    print(f"SECURITY_WARN: {message}", file=sys.stderr)


# ---------------------------------------------------------------------------
# POSIX
# ---------------------------------------------------------------------------

def _posix_tighten(path: Path, is_dir: bool) -> bool:
    mode = DIR_MODE if is_dir else FILE_MODE
    try:
        os.chmod(path, mode)
    except OSError as exc:  # exotic filesystem, read-only mount, ...
        _warn(f"cannot apply mode {oct(mode)} to {path}: {exc}")
        return False
    return True


# ---------------------------------------------------------------------------
# Windows (ctypes, no external process)
# ---------------------------------------------------------------------------

def _windows_tighten(target: Path, is_dir: bool) -> bool:
    """Replace the DACL with a protected DACL for the current user + SYSTEM."""
    if not IS_WINDOWS:
        return False

    import ctypes
    from ctypes import wintypes

    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    SE_FILE_OBJECT = 1
    DACL_SECURITY_INFORMATION = 0x00000004
    PROTECTED_DACL_SECURITY_INFORMATION = 0x80000000
    TOKEN_QUERY = 0x0008
    TOKEN_USER = 1
    ACL_REVISION = 2
    OBJECT_INHERIT_ACE = 0x1
    CONTAINER_INHERIT_ACE = 0x2
    FILE_ALL_ACCESS = 0x001F01FF
    LOCAL_SYSTEM_SID = "S-1-5-18"

    advapi32.OpenProcessToken.argtypes = [
        wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE),
    ]
    advapi32.OpenProcessToken.restype = wintypes.BOOL
    advapi32.GetTokenInformation.argtypes = [
        wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
        wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
    ]
    advapi32.GetTokenInformation.restype = wintypes.BOOL
    advapi32.ConvertStringSidToSidW.argtypes = [
        wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_void_p),
    ]
    advapi32.ConvertStringSidToSidW.restype = wintypes.BOOL
    advapi32.InitializeAcl.argtypes = [ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD]
    advapi32.InitializeAcl.restype = wintypes.BOOL
    advapi32.AddAccessAllowedAceEx.argtypes = [
        ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
        wintypes.DWORD, ctypes.c_void_p,
    ]
    advapi32.AddAccessAllowedAceEx.restype = wintypes.BOOL
    advapi32.SetNamedSecurityInfoW.argtypes = [
        wintypes.LPWSTR, ctypes.c_int, wintypes.DWORD, ctypes.c_void_p,
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
    ]
    advapi32.SetNamedSecurityInfoW.restype = wintypes.DWORD
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]

    token = wintypes.HANDLE()
    if not advapi32.OpenProcessToken(
        kernel32.GetCurrentProcess(), TOKEN_QUERY, ctypes.byref(token)
    ):
        _warn(f"OpenProcessToken failed (winerror {ctypes.get_last_error()})")
        return False

    user_sid_buffer = None
    try:
        size = wintypes.DWORD(0)
        advapi32.GetTokenInformation(token, TOKEN_USER, None, 0, ctypes.byref(size))
        if not size.value:
            _warn("GetTokenInformation size probe failed")
            return False
        user_sid_buffer = ctypes.create_string_buffer(size.value)
        if not advapi32.GetTokenInformation(
            token, TOKEN_USER, user_sid_buffer, size.value, ctypes.byref(size)
        ):
            _warn(f"GetTokenInformation failed (winerror {ctypes.get_last_error()})")
            return False
    finally:
        kernel32.CloseHandle(token)

    # TOKEN_USER begins with SID_AND_ATTRIBUTES { PSID Sid; DWORD Attributes; }
    user_sid = ctypes.cast(user_sid_buffer, ctypes.POINTER(ctypes.c_void_p))[0]

    system_sid = ctypes.c_void_p()
    if not advapi32.ConvertStringSidToSidW(
        LOCAL_SYSTEM_SID, ctypes.byref(system_sid)
    ):
        _warn(f"ConvertStringSidToSidW failed (winerror {ctypes.get_last_error()})")
        return False

    try:
        # Generous fixed buffer: two ACEs fit far inside 1 KiB.
        acl_buffer = ctypes.create_string_buffer(1024)
        acl = ctypes.cast(acl_buffer, ctypes.c_void_p)
        if not advapi32.InitializeAcl(acl, 1024, ACL_REVISION):
            _warn(f"InitializeAcl failed (winerror {ctypes.get_last_error()})")
            return False
        inherit = (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE) if is_dir else 0
        for sid, label in ((user_sid, "current user"), (system_sid.value, "SYSTEM")):
            if not advapi32.AddAccessAllowedAceEx(
                acl, ACL_REVISION, inherit, FILE_ALL_ACCESS, sid
            ):
                _warn(f"AddAccessAllowedAceEx({label}) failed "
                      f"(winerror {ctypes.get_last_error()})")
                return False
        flags = DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION
        rc = advapi32.SetNamedSecurityInfoW(
            str(target), SE_FILE_OBJECT, flags, None, None, acl, None
        )
        if rc != 0:
            _warn(f"SetNamedSecurityInfoW failed for {target} (winerror {rc})")
            return False
    finally:
        kernel32.LocalFree(system_sid)
    return True


def _tighten(target: Path, is_dir: bool) -> bool:
    if IS_WINDOWS:
        return _windows_tighten(target, is_dir)
    return _posix_tighten(target, is_dir)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def _assert_owned_by_current_user(target: Path) -> None:
    """Refuse a directory that belongs to another local account (POSIX)."""
    if IS_WINDOWS:
        return
    getuid = getattr(os, "getuid", None)
    if getuid is None:  # platform cannot report ownership
        return
    try:
        st = os.stat(target)
    except OSError as exc:
        raise UnsafeArchiveError(f"cannot stat {target}: {exc}") from exc
    if st.st_uid != getuid():
        raise UnsafeArchiveError(
            f"archive directory {target} is owned by uid {st.st_uid}, "
            f"not the current user {getuid()}; refusing to use it"
        )


def assert_safe_directory(path: str | os.PathLike) -> None:
    """Validate an existing archive directory without creating or changing it."""
    target = Path(path).expanduser()
    if not target.is_dir():
        raise UnsafeArchiveError(f"archive path is not a directory: {target}")
    _assert_owned_by_current_user(target)


def secure_directory(path: str | os.PathLike) -> bool:
    """Create the archive directory if needed and force owner-only access.

    Returns True when owner-only access is in effect, False when the platform
    or filesystem could not enforce it (a warning has been printed).
    """
    target = Path(path).expanduser()
    if target.exists():
        if not target.is_dir():
            raise UnsafeArchiveError(f"archive path is not a directory: {target}")
        _assert_owned_by_current_user(target)
    else:
        try:
            os.makedirs(target, exist_ok=True)
        except OSError as exc:
            raise UnsafeArchiveError(
                f"cannot create archive directory {target}: {exc}"
            ) from exc
    return _tighten(target, is_dir=True)


def secure_file(path: str | os.PathLike) -> bool:
    """Create (atomically, owner-only) and tighten a single archive file."""
    target = Path(path).expanduser()
    if not target.exists():
        flags = os.O_CREAT | os.O_WRONLY
        try:
            fd = os.open(str(target), flags, FILE_MODE)
        except OSError as exc:
            raise UnsafeArchiveError(f"cannot create {target}: {exc}") from exc
        os.close(fd)
    return _tighten(target, is_dir=False)


def secure_sidecars(db_path: str | os.PathLike) -> int:
    """Tighten the database and the ``-wal``/``-shm`` files SQLite creates."""
    base = Path(db_path).expanduser()
    locked = 0
    for suffix in ("", "-wal", "-shm"):
        candidate = Path(f"{base}{suffix}")
        if not candidate.exists():
            continue
        try:
            if secure_file(candidate):
                locked += 1
        except UnsafeArchiveError as exc:
            _warn(str(exc))
    return locked


def permissions_enforced(path: str | os.PathLike, is_dir: bool) -> bool | None:
    """Report owner-only mode: True/False on POSIX, None when unreportable."""
    if IS_WINDOWS:
        return None
    try:
        mode = stat.S_IMODE(os.stat(Path(path).expanduser()).st_mode)
    except OSError:
        return False
    expected = DIR_MODE if is_dir else FILE_MODE
    return mode == expected
