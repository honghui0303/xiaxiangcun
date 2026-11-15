# -*- coding: utf-8 -*-
"""
修仙小院 - 窗口贴底守护

Godot 只有「置顶」没有「置底」，这里用 ctypes 直接调 user32 补上：
  WS_EX_NOACTIVATE  点击不抢焦点
  WS_EX_TOOLWINDOW  不进 Alt+Tab、不显示任务栏按钮
  HWND_BOTTOM       压在 Z 序最底，被其他窗口盖住

用法：
  python tools/pin_bottom.py            启动游戏并贴底（常驻）
  python tools/pin_bottom.py --shot a.bmp  启动后截图并退出（验证用）
"""

import ctypes
import ctypes.wintypes as wintypes
import os
import shutil
import struct
import subprocess
import sys
import time

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE_NAME = "Godot_v4.7.2-stable_win64.exe"


def resolve_godot():
    """找 Godot 可执行文件。

    优先级：`--godot=<路径>` > 环境变量 XIANXIA_GODOT > PATH 里的 godot > 桌面/下载的常见位置。
    这个仓库是公开的，不能写死某台机器的绝对路径，所以本机默认值只当最后的兜底。
    """
    for a in sys.argv[1:]:
        if a.startswith("--godot="):
            return a.split("=", 1)[1].strip('"')
    env = os.environ.get("XIANXIA_GODOT", "").strip().strip('"')
    if env:
        return env
    for name in ("godot", "godot4", ENGINE_NAME, "Godot_v4.7.2-stable_win64_console.exe"):
        p = shutil.which(name)
        if p:
            return p
    home = os.path.expanduser("~")
    for cand in (
        os.path.join(home, "Desktop", ENGINE_NAME),
        os.path.join(home, "Downloads", ENGINE_NAME),
        os.path.join(home, "Desktop", "Godot", "godot.exe"),
        r"C:\Program Files\Godot\godot.exe",
    ):
        if os.path.exists(cand):
            return cand
    return ""

GWL_EXSTYLE = -20
WS_EX_NOACTIVATE = 0x08000000
WS_EX_TOOLWINDOW = 0x00000080
WS_EX_APPWINDOW = 0x00040000

HWND_BOTTOM = ctypes.c_void_p(1)
HWND_TOPMOST = ctypes.c_void_p(-1)
SWP_NOSIZE = 0x0001
SWP_NOMOVE = 0x0002
SWP_NOACTIVATE = 0x0010
SWP_NOOWNERZORDER = 0x0200

SRCCOPY = 0x00CC0020

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

# 关键：脚本自己也要 DPI-aware，否则拿到的是被系统虚拟化过的坐标，
# 截图会变成 1536x864 这种缩放尺寸，测出来的东西全是错的。
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    try:
        user32.SetProcessDPIAware()
    except Exception:
        pass

user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
user32.GetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int]
user32.SetWindowLongPtrW.restype = ctypes.c_ssize_t
user32.SetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t]
user32.SetWindowPos.argtypes = [
    wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
    ctypes.c_int, ctypes.c_int, wintypes.UINT
]


def find_window(pid, timeout=40.0):
    """按进程号找主窗口，不依赖标题字符串。"""
    WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    deadline = time.time() + timeout
    while time.time() < deadline:
        found = []

        def _cb(hwnd, _):
            proc_id = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(proc_id))
            if proc_id.value != pid or not user32.IsWindowVisible(hwnd):
                return True
            rect = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            area = (rect.right - rect.left) * (rect.bottom - rect.top)
            if area > 20000:
                found.append((area, hwnd))
            return True

        user32.EnumWindows(WNDENUMPROC(_cb), 0)
        if found:
            found.sort(reverse=True)
            return found[0][1]
        time.sleep(0.25)
    return None


def make_overlay(hwnd):
    ex = user32.GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
    ex |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
    ex &= ~WS_EX_APPWINDOW
    user32.SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex)


def pin_bottom(hwnd):
    user32.SetWindowPos(
        hwnd, HWND_BOTTOM, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER
    )


SPI_GETWORKAREA = 0x0030
WM_CLOSE = 0x0010


def close_gracefully(proc, hwnd, timeout=6.0):
    """发 WM_CLOSE 让 Godot 走正常退出流程。
    直接 terminate 是 TerminateProcess 硬杀，_exit_tree / WM_CLOSE_REQUEST 都不会触发，
    游戏里的"退出时存档"就永远不会执行。
    """
    if user32.IsWindow(hwnd):
        user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            print("[exit] 正常关闭，存档已落盘")
            return True
        time.sleep(0.1)
    print("[exit] 超时未退出，强制结束（本次进度可能丢失）")
    proc.terminate()
    return False


def place_bottom(hwnd):
    """位置由这边算，不用 Godot 的 window_set_position。
    Godot 在 125% DPI 下上报的坐标和实际窗口位置对不上（实测差一半），
    与其跟它较劲，不如让 DPI-aware 的 Python 直接摆。
    """
    work = wintypes.RECT()
    user32.SystemParametersInfoW(SPI_GETWORKAREA, 0, ctypes.byref(work), 0)
    r = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    w = r.right - r.left
    h = r.bottom - r.top
    work_w = work.right - work.left
    x = work.left + max(0, (work_w - w) // 2)
    y = work.bottom - h
    user32.SetWindowPos(
        hwnd, HWND_BOTTOM, x, y, 0, 0,
        SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER
    )
    print(f"[place] -> ({x},{y})  work={work.left},{work.top},{work.right},{work.bottom}")


def print_rect(hwnd):
    r = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    scr_w = user32.GetSystemMetrics(0)
    scr_h = user32.GetSystemMetrics(1)
    print(f"[rect] window = ({r.left},{r.top})-({r.right},{r.bottom})  "
          f"size={r.right - r.left}x{r.bottom - r.top}  screen={scr_w}x{scr_h}")


def grab_window(hwnd, path):
    """只截窗口那一块。
    窗口在 HWND_BOTTOM，被别的窗口盖住时从屏幕拷贝会拿到遮挡物，
    所以先临时提到最上层、截完再压回去。
    """
    r = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    x, y = r.left, r.top
    W = r.right - r.left
    H = r.bottom - r.top

    user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)
    time.sleep(0.35)

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [
            ("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG),
            ("biHeight", wintypes.LONG), ("biPlanes", wintypes.WORD),
            ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
            ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
            ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
            ("biClrImportant", wintypes.DWORD),
        ]

    hdc = user32.GetDC(0)
    mdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, W, H)
    gdi32.SelectObject(mdc, bmp)
    gdi32.BitBlt(mdc, 0, 0, W, H, hdc, x, y, SRCCOPY)

    bi = BITMAPINFOHEADER()
    bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.biWidth = W
    bi.biHeight = -H
    bi.biPlanes = 1
    bi.biBitCount = 32
    bi.biCompression = 0

    buf = ctypes.create_string_buffer(W * H * 4)
    gdi32.GetDIBits(mdc, bmp, 0, H, buf, ctypes.byref(bi), 0)

    with open(path, "wb") as f:
        f.write(struct.pack("<2sIHHI", b"BM", 54 + W * H * 4, 0, 0, 54))
        f.write(struct.pack("<IiiHHIIiiII", 40, W, -H, 1, 32, 0, W * H * 4, 0, 0, 0, 0))
        f.write(buf.raw)

    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(0, hdc)

    pin_bottom(hwnd)
    print("[shot] saved ->", path, f"({W}x{H})")


def grab_screen(path):
    """不依赖 Pillow 的全屏截图，直接走 GDI。"""
    W = user32.GetSystemMetrics(0)
    H = user32.GetSystemMetrics(1)

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [
            ("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG),
            ("biHeight", wintypes.LONG), ("biPlanes", wintypes.WORD),
            ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
            ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
            ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
            ("biClrImportant", wintypes.DWORD),
        ]

    hdc = user32.GetDC(0)
    mdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, W, H)
    gdi32.SelectObject(mdc, bmp)
    gdi32.BitBlt(mdc, 0, 0, W, H, hdc, 0, 0, SRCCOPY)

    bi = BITMAPINFOHEADER()
    bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.biWidth = W
    bi.biHeight = -H
    bi.biPlanes = 1
    bi.biBitCount = 32
    bi.biCompression = 0

    buf = ctypes.create_string_buffer(W * H * 4)
    gdi32.GetDIBits(mdc, bmp, 0, H, buf, ctypes.byref(bi), 0)

    with open(path, "wb") as f:
        f.write(struct.pack("<2sIHHI", b"BM", 54 + W * H * 4, 0, 0, 54))
        f.write(struct.pack("<IiiHHIIiiII", 40, W, -H, 1, 32, 0, W * H * 4, 0, 0, 0, 0))
        f.write(buf.raw)

    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(0, hdc)
    print("[shot] saved ->", path)


def main():
    shot_idx = sys.argv.index("--shot") if "--shot" in sys.argv else -1
    shot_path = sys.argv[shot_idx + 1] if shot_idx >= 0 else None
    wait_idx = sys.argv.index("--wait") if "--wait" in sys.argv else -1
    wait_sec = float(sys.argv[wait_idx + 1]) if wait_idx >= 0 else 3.5

    godot = resolve_godot()

    if not godot or not os.path.exists(godot):
        print("[err] 没找到 Godot 引擎。三种指定方式，任选一种：")
        print("      1) python tools/pin_bottom.py --godot=<引擎路径>")
        print("      2) set XIANXIA_GODOT=<引擎路径>  （PowerShell: $env:XIANXIA_GODOT=...）")
        print("      3) 把 godot 加进 PATH")
        return 1

    print("[launch]", godot)
    proc = subprocess.Popen([godot, "--path", PROJ])
    hwnd = find_window(proc.pid)
    if not hwnd:
        print("[err] window not found")
        proc.terminate()
        return 1

    print("[ok] hwnd =", hwnd)
    make_overlay(hwnd)
    place_bottom(hwnd)
    print_rect(hwnd)

    if shot_path:
        time.sleep(wait_sec)
        grab_window(hwnd, shot_path)
        close_gracefully(proc, hwnd)
        return 0

    print("[run] 守护中，Ctrl+C 结束")
    try:
        while True:
            if proc.poll() is not None:
                print("[exit] godot closed")
                break
            if not user32.IsWindow(hwnd):
                print("[exit] window gone")
                break
            pin_bottom(hwnd)
            time.sleep(1.5)
    except KeyboardInterrupt:
        pass
    finally:
        if proc.poll() is None:
            close_gracefully(proc, hwnd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
