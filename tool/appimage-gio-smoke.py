#!/usr/bin/env python3
"""Exercise a packaged GIO desktop launcher with a harmless executable."""
import ctypes
from pathlib import Path
import sys


class GError(ctypes.Structure):
    _fields_ = [('domain', ctypes.c_uint), ('code', ctypes.c_int),
                ('message', ctypes.c_char_p)]


def main():
    payload = Path(sys.argv[1]).resolve()
    gio = ctypes.CDLL(str(payload / 'lib/libgio-2.0.so.0'))
    glib = ctypes.CDLL(str(payload / 'lib/libglib-2.0.so.0'))
    gobject = ctypes.CDLL(str(payload / 'lib/libgobject-2.0.so.0'))
    error_pointer = ctypes.POINTER(GError)
    gio.g_app_info_create_from_commandline.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(error_pointer)]
    gio.g_app_info_create_from_commandline.restype = ctypes.c_void_p
    gio.g_app_info_launch.argtypes = [
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(error_pointer)]
    gio.g_app_info_launch.restype = ctypes.c_int
    glib.g_error_free.argtypes = [error_pointer]
    gobject.g_object_unref.argtypes = [ctypes.c_void_p]
    error = error_pointer()
    info = gio.g_app_info_create_from_commandline(
        b'/usr/bin/true', b'Raft AppImage desktop launcher check', 0,
        ctypes.byref(error))
    try:
        if not info or not gio.g_app_info_launch(info, None, None, ctypes.byref(error)):
            message = error.contents.message.decode() if error else 'Unknown GIO launch failure'
            raise ValueError(message)
        print('Bundled GIO desktop launcher executed the harmless command')
    finally:
        if info:
            gobject.g_object_unref(info)
        if error:
            glib.g_error_free(error)


if __name__ == '__main__':
    main()
