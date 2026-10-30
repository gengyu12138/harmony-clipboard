#!/usr/bin/python3
"""Mac ↔ HarmonyOS text clipboard bridge using the official hdc/testhelper."""
import argparse
import base64
import ctypes as C
import fcntl
import ipaddress
import json
import logging
from logging.handlers import RotatingFileHandler
import os
import re
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT = Path.home() / 'Library/Application Support/HarmonyClipboard'
LABEL = 'local.gengyu.harmony-clipboard'
PLIST = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
SERVICE = 'gui/' + str(os.getuid()) + '/' + LABEL
SERVER = '127.0.0.1:18710'
MAX_BYTES = 16 * 1024  # Base64 remains below the hdc command packet limit.
STOP = threading.Event()


class Pasteboard:
    """Small native bridge: changeCount avoids polling pbpaste subprocesses."""
    def __init__(self):
        C.CDLL('/System/Library/Frameworks/AppKit.framework/AppKit')
        lib = C.CDLL('/usr/lib/libobjc.A.dylib')
        lib.objc_getClass.argtypes = [C.c_char_p]
        lib.objc_getClass.restype = C.c_void_p
        lib.sel_registerName.argtypes = [C.c_char_p]
        lib.sel_registerName.restype = C.c_void_p
        self.lib = lib
        self.selectors = {}
        self.functions = {}
        self.cls = lib.objc_getClass
        self.board = self.call(C.c_void_p, self.cls(b'NSPasteboard'), 'generalPasteboard')

    def call(self, result, obj, name, args=(), types=()):
        if name not in self.selectors:
            self.selectors[name] = self.lib.sel_registerName(name.encode())
        key = (result, types)
        if key not in self.functions:
            self.functions[key] = C.CFUNCTYPE(result, C.c_void_p, C.c_void_p, *types)(
                ('objc_msgSend', self.lib))
        return self.functions[key](obj, self.selectors[name], *args)

    def string(self, text):
        return self.call(C.c_void_p, self.cls(b'NSString'), 'stringWithUTF8String:',
                         (text.encode('utf-8'),), (C.c_char_p,))

    def count(self):
        return self.call(C.c_long, self.board, 'changeCount')

    def frontmost_bundle(self):
        pool = self.call(C.c_void_p, self.cls(b'NSAutoreleasePool'), 'new')
        try:
            workspace = self.call(C.c_void_p, self.cls(b'NSWorkspace'), 'sharedWorkspace')
            # NSWorkspace caches its frontmost app until the main run loop advances.
            # This CLI otherwise waits in threading.Event/subprocess, so polling alone
            # would keep returning the app that was frontmost when the bridge started.
            loop = self.call(C.c_void_p, self.cls(b'NSRunLoop'), 'mainRunLoop')
            deadline = self.call(C.c_void_p, self.cls(b'NSDate'), 'dateWithTimeIntervalSinceNow:',
                                 (0.001,), (C.c_double,))
            self.call(None, loop, 'runUntilDate:', (deadline,), (C.c_void_p,))
            app = self.call(C.c_void_p, workspace, 'frontmostApplication')
            bundle = self.call(C.c_void_p, app, 'bundleIdentifier') if app else None
            value = self.call(C.c_char_p, bundle, 'UTF8String') if bundle else None
            return value.decode('utf-8') if value else None
        finally:
            self.call(None, pool, 'drain')

    def read(self):
        pool = self.call(C.c_void_p, self.cls(b'NSAutoreleasePool'), 'new')
        try:
            count = self.count()
            kinds = self.call(C.c_void_p, self.board, 'types')
            for marker in ('org.nspasteboard.ConcealedType', 'org.nspasteboard.TransientType',
                           'com.agilebits.onepassword'):
                if kinds and self.call(C.c_bool, kinds, 'containsObject:',
                                       (self.string(marker),), (C.c_void_p,)):
                    return count, None
            value = self.call(C.c_void_p, self.board, 'stringForType:',
                              (self.string('public.utf8-plain-text'),), (C.c_void_p,))
            text = None
            if value:
                size = self.call(C.c_ulong, value, 'lengthOfBytesUsingEncoding:',
                                 (4,), (C.c_ulong,))
                ptr = self.call(C.c_void_p, value, 'UTF8String')
                text = C.string_at(ptr, size).decode('utf-8')
            if count != self.count():
                raise RuntimeError('mac_clipboard_changed_during_read')
            return count, text
        finally:
            self.call(None, pool, 'drain')

    def write(self, text, expected_count):
        pool = self.call(C.c_void_p, self.cls(b'NSAutoreleasePool'), 'new')
        try:
            value = self.string(text)
            kind = self.string('public.utf8-plain-text')
            if self.count() != expected_count:
                return None
            self.call(C.c_long, self.board, 'clearContents')
            ok = self.call(C.c_bool, self.board, 'setString:forType:',
                           (value, kind), (C.c_void_p, C.c_void_p))
            if not ok:
                raise RuntimeError('mac_clipboard_write_failed')
            return self.count()
        finally:
            self.call(None, pool, 'drain')


def eligible(text):
    return text is not None and text != '' and '\0' not in text and len(text.encode('utf-8')) <= MAX_BYTES


def atomic_json(path, data):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)


def privacy_status():
    path = ROOT / 'privacy.json'
    try:
        if not path.exists():
            return False, None
        value = json.loads(path.read_text())
        if not isinstance(value, dict) or not isinstance(value.get('paused'), bool):
            return True, 'invalid'
        until = value.get('until')
        active = value['paused'] and (until is None or float(until) > time.time())
        return bool(active), value.get('generation')
    except (OSError, ValueError, TypeError, KeyError):
        # A damaged privacy file must never silently resume data transfer.
        return True, 'invalid'


def exclusion_status(board):
    path = ROOT / 'exclusions.json'
    try:
        if not path.exists():
            return False, None
        value = json.loads(path.read_text())
        if (not isinstance(value, dict) or not isinstance(value.get('generation'), str)
                or not isinstance(value.get('applications'), list)
                or any(not isinstance(app, dict) or not isinstance(app.get('id'), str)
                       or not app['id'] or not isinstance(app.get('name'), str)
                       for app in value['applications'])):
            return True, 'invalid'
        identifiers = {app['id'] for app in value['applications']}
        return board.frontmost_bundle() in identifiers, value['generation']
    except (OSError, ValueError, TypeError, KeyError):
        return True, 'invalid'


class Bridge:
    def __init__(self):
        self.config = json.loads((ROOT / 'config.json').read_text())
        validate_endpoint(self.config['endpoint'])
        self.endpoint = self.config['endpoint']
        self.env = dict(os.environ, OHOS_HDC_CMD_RECORD='0', OHOS_HDC_LOG_LEVEL='0',
                        OHOS_HDC_ENCRYPT_CHANNEL='1')
        self.server = None
        self.board = Pasteboard()
        self.mac_count, _ = self.board.read()
        self.phone_text = None
        self.pending = None
        self.connected = False
        self.retry_at = 0.0
        self.backoff = 2.0
        self.state = {}
        try:
            previous = json.loads((ROOT / 'status.json').read_text())
            self.state = {key: previous[key] for key in ('last_sync', 'last_direction') if isinstance(previous.get(key), str)}
        except (OSError, ValueError, AttributeError):
            pass  # Status is a disposable cache; never prevent sync because an old status is unreadable.
        self.saved_state = None
        self.saved_at = 0.0
        self.was_paused, self.privacy_stamp = privacy_status()
        self.was_excluded, self.exclusion_stamp = exclusion_status(self.board)

    def status(self, **changes):
        self.state.update(changes)
        self.state.update(pid=os.getpid(), endpoint=self.endpoint,
                          connected=self.connected, pending_mac=self.pending is not None)
        if self.state != self.saved_state or time.monotonic() - self.saved_at > 30:
            atomic_json(ROOT / 'status.json', dict(self.state, updated_at=time.strftime('%Y-%m-%d %H:%M:%S')))
            self.saved_state = dict(self.state)
            self.saved_at = time.monotonic()

    def command(self, *args, timeout=4):
        cmd = [str(ROOT / 'bin/hdc'), '-p', '-s', SERVER, '-l0', *args]
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=timeout, env=self.env)
        if result.returncode:
            raise RuntimeError('hdc_command_failed')
        return result.stdout

    def remote(self, command):
        return self.command('-t', self.endpoint, 'shell', command)

    def start_server(self):
        if self.server is not None and self.server.poll() is None:
            return
        with socket.socket() as probe:
            if probe.connect_ex(('127.0.0.1', 18710)) == 0:
                raise RuntimeError('private_hdc_port_busy')
        self.server = subprocess.Popen([str(ROOT / 'bin/hdc'), '-s', SERVER, '-l0', '-m'],
                                       env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        STOP.wait(0.5)
        if self.server.poll() is not None:
            raise RuntimeError('hdc_server_start_failed_or_another_hdc_is_running')

    def connect(self):
        self.start_server()
        targets = self.command('list', 'targets', '-v').decode('utf-8')
        ready = any(row.split()[:3] == [self.endpoint, 'TCP', 'Connected']
                    for row in targets.splitlines())
        if not ready:
            # hdc may retain an Unknown session after a timed-out handshake.
            if any(row.split()[:1] == [self.endpoint] for row in targets.splitlines()):
                self.command('tconn', self.endpoint, '-remove')
            reply = self.command('tconn', self.endpoint, timeout=6)
            if b'Connect OK' not in reply:
                raise RuntimeError('connection_unavailable')
        self.connected = True
        self.backoff = 2.0
        logging.info('connected')
        self.status(state='connected', error=None)

    def capture_mac(self):
        count, text = self.board.read()
        if count != self.mac_count:
            self.mac_count = count
            self.pending = text if eligible(text) else None
            self.status(mac_text_skipped=not eligible(text))
        return count

    def sync_allowed(self):
        active, stamp = privacy_status()
        excluded, exclusion_stamp = exclusion_status(self.board)
        allowed = not active and stamp == self.privacy_stamp and not excluded and exclusion_stamp == self.exclusion_stamp
        if not allowed:
            # Drop queued data immediately, including when exclusion begins during hdc IO.
            self.pending = None
            self.phone_text = None
            self.mac_count = self.board.count()
            self.was_excluded = excluded
        return allowed

    def sync(self):
        if not self.sync_allowed():
            return
        self.capture_mac()
        if self.pending is not None:
            text = self.pending
            # Fixed shell code + base64 avoids quote expansion and code execution.
            # The final dot prevents command substitution stripping trailing newlines.
            encoded = base64.b64encode(text.encode('utf-8')).decode('ascii')
            command = ('task_clip_text=$(printf %s ' + encoded + ' | base64 -d; printf .); '
                       'testhelper set-pastedata "${task_clip_text%.}"')
            if not self.sync_allowed():
                return
            reply = self.remote(command)
            if reply != b'Pasteboard text set successfully.\n':
                raise RuntimeError('phone_clipboard_write_failed')
            self.phone_text = text
            self.pending = None
            self.status(last_direction='Mac → 手机', last_sync=time.strftime('%Y-%m-%d %H:%M:%S'))
        count = self.capture_mac()
        if self.pending is not None:
            return
        reply = self.remote('testhelper get-pastedata')
        if reply == b'Error: Service is not available.\n':
            # Locked phones can still accept writes; do not disconnect on read denial.
            self.status(state='phone_read_unavailable', error='手机可能锁屏，Mac → 手机仍可同步')
            return
        prefix = b'Pasteboard text: '
        if not reply.startswith(prefix) or not reply.endswith(b'\n'):
            raise RuntimeError('phone_clipboard_read_failed')
        text = reply[len(prefix):-1].decode('utf-8')
        if not self.sync_allowed():
            return
        if self.board.count() != count:
            return  # A Mac copy during the network call takes priority next cycle.
        previous = self.phone_text
        if previous is not None and text != previous and eligible(text):
            written_count = self.board.write(text, count)
            if written_count is None:
                return
            self.mac_count = written_count
            self.status(last_direction='手机 → Mac', last_sync=time.strftime('%Y-%m-%d %H:%M:%S'))
        self.phone_text = text
        self.status(state='syncing', error=None)

    def close(self):
        if self.server is not None and self.server.poll() is None:
            self.server.terminate()
            try:
                self.server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait()
        self.connected = False
        self.pending = None
        self.status(state='stopped', error=None)

    def run(self):
        self.status(state='starting')
        try:
            while not STOP.is_set():
                started = time.monotonic()
                try:
                    active, stamp = privacy_status()
                    excluded, exclusion_stamp = exclusion_status(self.board)
                    if active or self.was_paused or stamp != self.privacy_stamp or excluded or self.was_excluded or exclusion_stamp != self.exclusion_stamp:
                        self.pending = None
                        self.phone_text = None
                        self.mac_count = self.board.count()
                        self.was_paused, self.privacy_stamp = active, stamp
                        self.was_excluded, self.exclusion_stamp = excluded, exclusion_stamp
                    if active or excluded:
                        self.status(state='privacy_paused' if active else 'application_excluded', error=None)
                        STOP.wait(0.8)
                        continue
                    config = json.loads((ROOT / 'config.json').read_text())
                    endpoint = validate_endpoint(config['endpoint'])
                    if endpoint != self.endpoint:
                        # A changed target must not receive pending text intended for the old phone.
                        self.close()
                        self.endpoint = endpoint
                        self.phone_text = None
                        self.retry_at = 0.0
                        self.backoff = 2.0
                        self.mac_count = self.board.count()
                    self.capture_mac()
                    if not self.connected and started >= self.retry_at:
                        self.connect()
                    if self.connected and not STOP.is_set():
                        self.sync()
                except (OSError, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
                    # Never log exception messages: command arguments can contain clipboard text.
                    if self.connected:
                        logging.warning('connection_or_clipboard_unavailable')
                    self.connected = False
                    self.retry_at = time.monotonic() + self.backoff
                    self.backoff = min(self.backoff * 2, 30)
                    reason = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
                    self.status(state='retrying', error=reason)
                STOP.wait(max(0.1, 0.8 - (time.monotonic() - started)))
        finally:
            self.close()


def validate_endpoint(value):
    address, port = value.rsplit(':', 1)
    if ipaddress.ip_address(address).version != 4 or not port.isascii() or not port.isdigit() or not 1 <= int(port) <= 65535:
        raise ValueError('请输入手机无线调试页的 IPv4:端口')
    return value


def launch(*args, check=True):
    return subprocess.run(['/bin/launchctl', *args], check=check,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)


def service_disabled(label, output):
    return re.search(r'"' + re.escape(label) + r'"\s*=>\s*(?:true|disabled)\b', output) is not None


def control(action, quiet=False):
    loaded = launch('print', SERVICE, check=False).returncode == 0
    if action in ('stop', 'runtime-stop'):
        if action == 'stop':
            launch('disable', SERVICE)
        if loaded:
            launch('bootout', SERVICE)
            deadline = time.monotonic() + 15
            while launch('print', SERVICE, check=False).returncode == 0:
                if time.monotonic() >= deadline:
                    raise RuntimeError('service_stop_timeout')
                time.sleep(0.2)
        if not quiet:
            print('已暂停同步，并关闭登录自启。运行 start 恢复。')
    elif action in ('start', 'runtime-start'):
        disabled = launch('print-disabled', 'gui/' + str(os.getuid())).stdout.decode('utf-8')
        restore_disabled = action == 'runtime-start' and service_disabled(LABEL, disabled)
        launch('enable', SERVICE)
        if not loaded:
            try:
                launch('bootstrap', 'gui/' + str(os.getuid()), str(PLIST))
            finally:
                if restore_disabled:
                    launch('disable', SERVICE)
        elif restore_disabled:
            launch('disable', SERVICE)
        if not quiet:
            print('已启用同步和登录自启。')
    elif action == 'status':
        print('登录服务：' + ('已加载' if loaded else '未加载 / 已暂停'))
        if (ROOT / 'status.json').exists():
            print((ROOT / 'status.json').read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['run', 'start', 'stop', 'status', 'endpoint'])
    parser.add_argument('address', nargs='?')
    args = parser.parse_args()
    os.umask(0o077)
    if args.action == 'endpoint':
        address = validate_endpoint(args.address or '')
        config = json.loads((ROOT / 'config.json').read_text())
        config['endpoint'] = address
        atomic_json(ROOT / 'config.json', config)
        print('已更新手机地址：' + address)
    elif args.action != 'run':
        control(args.action)
    else:
        with (ROOT / 'sync.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            handler = RotatingFileHandler(ROOT / 'events.log', maxBytes=200000, backupCount=1)
            logging.basicConfig(level=logging.INFO, handlers=[handler],
                                format='%(asctime)s %(levelname)s %(message)s')
            signal.signal(signal.SIGTERM, lambda *_: STOP.set())
            signal.signal(signal.SIGINT, lambda *_: STOP.set())
            Bridge().run()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Avoid tracebacks containing clipboard values or command arguments.
        print('操作失败：' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
