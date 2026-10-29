#!/usr/bin/python3
"""Capture the paired phone screen over the existing hdc connection."""
import ctypes as C
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

from sync import ROOT, SERVER, Pasteboard, validate_endpoint


def capture():
    endpoint = validate_endpoint(json.loads((ROOT / 'config.json').read_text())['endpoint'])
    env = dict(os.environ, OHOS_HDC_CMD_RECORD='0', OHOS_HDC_LOG_LEVEL='0',
               OHOS_HDC_ENCRYPT_CHANNEL='1')
    base = [str(ROOT / 'bin/hdc'), '-p', '-s', SERVER, '-l0']

    def hdc(*args):
        result = subprocess.run(base + list(args), env=env, capture_output=True, timeout=20)
        if result.returncode:
            raise RuntimeError('无线调试命令失败，请检查手机连接。')
        return result.stdout

    targets = hdc('list', 'targets', '-v').decode('utf-8', errors='replace')
    if not any(row.split()[:3] == [endpoint, 'TCP', 'Connected'] for row in targets.splitlines()):
        raise RuntimeError('手机未连接。请开启无线调试，并等待文字同步服务重连。')

    board = Pasteboard()
    expected_count = board.count()
    remote = '/data/local/tmp/mac-phone-capture-' + uuid.uuid4().hex + '.jpeg'
    try:
        reply = hdc('-t', endpoint, 'shell', 'snapshot_display -f ' + remote)
        if b'success: snapshot' not in reply:
            raise RuntimeError('手机截图失败，请解锁手机后重试。')
        with tempfile.TemporaryDirectory(prefix='harmony-capture-') as directory:
            local = Path(directory) / 'screen.jpeg'
            hdc('-t', endpoint, 'file', 'recv', remote, str(local))
            if not local.exists() or local.stat().st_size == 0:
                raise RuntimeError('截图传输失败，剪贴板未修改。')
            pool = board.call(C.c_void_p, board.cls(b'NSAutoreleasePool'), 'new')
            try:
                data = board.call(C.c_void_p, board.cls(b'NSData'), 'dataWithContentsOfFile:',
                                  (board.string(str(local)),), (C.c_void_p,))
                image = board.call(C.c_void_p, board.cls(b'NSImage'), 'alloc')
                image = board.call(C.c_void_p, image, 'initWithData:', (data,), (C.c_void_p,))
                if not image:
                    raise RuntimeError('收到的截图无法解码，剪贴板未修改。')
                board.call(None, image, 'release')
                # A newer user copy takes priority over an in-flight capture.
                if board.count() != expected_count:
                    raise RuntimeError('截图期间剪贴板发生变化，已保留新复制的内容；请重试。')
                kind = board.string('public.jpeg')
                board.call(C.c_long, board.board, 'clearContents')
                ok = board.call(C.c_bool, board.board, 'setData:forType:',
                                (data, kind), (C.c_void_p, C.c_void_p))
                if not ok:
                    raise RuntimeError('截图已取回，但写入 Mac 剪贴板失败。')
                print('手机截图已复制，可按 ⌘V 粘贴。')
            finally:
                board.call(None, pool, 'drain')
    finally:
        try:
            hdc('-t', endpoint, 'shell', 'rm ' + remote)
        except (RuntimeError, OSError, subprocess.TimeoutExpired):
            print('手机临时截图清理失败：连接恢复后可清理 /data/local/tmp/mac-phone-capture-*.jpeg。',
                  file=sys.stderr)


def main():
    os.umask(0o077)
    with (ROOT / 'capture.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('正在获取手机截图，请勿重复触发。')
        capture()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        message = str(error) if isinstance(error, RuntimeError) else '截图失败：' + type(error).__name__
        print(message, file=sys.stderr)
        if '--notify-errors' in sys.argv:
            subprocess.run(['/usr/bin/osascript', '-e',
                            'on run argv\ndisplay alert "手机截图" message (item 1 of argv)\nend run',
                            message], timeout=60)
        sys.exit(1)
