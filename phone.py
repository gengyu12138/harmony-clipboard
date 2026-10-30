#!/usr/bin/python3
"""Panel actions using the locally installed HarmonyClipboard service."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path.home() / 'Library/Application Support/HarmonyClipboard'
sys.path.insert(0, str(Path(__file__).resolve().parent / 'Bridge'))
from sync import SERVER, MAX_BYTES, validate_endpoint, atomic_json, control, launch, privacy_status, service_disabled


def service_preferences():
    disabled = launch('print-disabled', 'gui/' + str(os.getuid())).stdout.decode('utf-8')
    return {key: not service_disabled(label, disabled) for key, label in (
        ('panel_autostart', 'local.gengyu.harmony-panel'),
        ('sync_autostart', 'local.gengyu.harmony-clipboard'))}


def main():
    action = sys.argv[1]
    if action == 'services':
        return service_preferences()
    if action == 'autostart':
        value = json.loads(sys.stdin.buffer.read(1024))
        labels = {'panel_autostart': 'local.gengyu.harmony-panel', 'sync_autostart': 'local.gengyu.harmony-clipboard'}
        if not isinstance(value, dict) or not value or any(key not in labels or not isinstance(enabled, bool) for key, enabled in value.items()):
            raise RuntimeError('启动设置无效。')
        for key, enabled in value.items():
            label = labels[key]
            if not (Path.home() / 'Library/LaunchAgents' / (label + '.plist')).is_file():
                raise RuntimeError('登录组件尚未安装，请先运行安装程序。')
            launch('enable' if enabled else 'disable', 'gui/' + str(os.getuid()) + '/' + label)
        return dict(service_preferences(), message='登录自启设置已保存；当前运行状态不变')
    if action in ('get', 'send', 'capture', 'reconnect') and privacy_status()[0]:
        raise RuntimeError('隐私暂停中，请先恢复记录与同步。')
    privacy_stamp = privacy_status()[1]
    if not (ROOT / 'sync.py').is_file() or not (ROOT / 'bin/hdc').is_file():
        raise RuntimeError('手机组件未安装。请按 README 运行 install.command 并指定官方 hdc 路径；本机剪贴板仍可使用。')
    if action == 'configure':
        value = sys.stdin.buffer.read(128).decode('utf-8').strip()
        try:
            address = validate_endpoint(value)
        except (ValueError, TypeError):
            raise RuntimeError('请输入有效的手机 IPv4 地址和 1–65535 的端口。')
        path = ROOT / 'config.json'
        config = json.loads(path.read_text()) if path.exists() else {}
        config['endpoint'] = address
        atomic_json(path, config)
        control('runtime-start', quiet=True)
        return {'message': '地址已保存，正在连接；如手机出现调试授权提示，请允许。'}
    if action in ('start', 'stop', 'reconnect'):
        if action in ('start', 'reconnect') and not (ROOT / 'config.json').exists():
            raise RuntimeError('请先在“手机连接设置”中填写 IP 和端口。')
        if action == 'reconnect':
            control('runtime-stop', quiet=True)
        control('runtime-stop' if action == 'stop' else 'runtime-start', quiet=True)
        return dict(service_preferences(), message='手机同步已停止；登录设置不变' if action == 'stop' else '手机同步已启动，正在连接')
    if not (ROOT / 'config.json').exists():
        raise RuntimeError('请先在“手机连接设置”中填写 IP 和端口。')
    endpoint = validate_endpoint(json.loads((ROOT / 'config.json').read_text())['endpoint'])
    env = dict(os.environ, OHOS_HDC_CMD_RECORD='0', OHOS_HDC_LOG_LEVEL='0', OHOS_HDC_ENCRYPT_CHANNEL='1')

    def remote(command):
        if privacy_status() != (False, privacy_stamp):
            raise RuntimeError('隐私状态已变化，本次手机操作已取消。')
        result = subprocess.run([str(ROOT / 'bin/hdc'), '-p', '-s', SERVER, '-l0',
                                 '-t', endpoint, 'shell', command], env=env,
                                capture_output=True, timeout=12)
        if result.returncode:
            raise RuntimeError('手机连接不可用，请检查 Wi-Fi 和无线调试。')
        if privacy_status() != (False, privacy_stamp):
            raise RuntimeError('隐私状态已变化，已丢弃本次返回内容。')
        return result.stdout

    if action == 'get':
        reply = remote('testhelper get-pastedata')
        prefix = b'Pasteboard text: '
        if reply == b'Error: Service is not available.\n':
            raise RuntimeError('手机暂时不允许读取，请解锁后重试。')
        if not reply.startswith(prefix) or not reply.endswith(b'\n'):
            raise RuntimeError('未能读取手机文字，请确认连接及剪贴板内容。')
        text = reply[len(prefix):-1].decode('utf-8')
        if not text:
            raise RuntimeError('手机剪贴板没有可读取的文字。')
        return {'text': text}
    if action == 'send':
        data = sys.stdin.buffer.read(MAX_BYTES + 1)
        if not data or len(data) > MAX_BYTES or b'\0' in data:
            raise RuntimeError('文字须非空且不超过 16 KB。')
        encoded = base64.b64encode(data).decode('ascii')
        command = ('task_clip_text=$(printf %s ' + encoded + ' | base64 -d; printf .); '
                   'testhelper set-pastedata "${task_clip_text%.}"')
        if remote(command) != b'Pasteboard text set successfully.\n':
            raise RuntimeError('写入手机剪贴板失败，请检查连接后重试。')
        return {'message': '文字已发送，可在手机粘贴'}
    if action == 'capture':
        result = subprocess.run(['/usr/bin/python3', '-B', str(ROOT / 'capture.py')],
                                capture_output=True, timeout=70)
        if result.returncode:
            raise RuntimeError(result.stderr.decode('utf-8', errors='replace').strip() or '手机截图失败。')
        return {'message': '手机截图已取回'}
    raise RuntimeError('不支持的操作。')


try:
    os.umask(0o077)
    print(json.dumps(dict(ok=True, **main()), ensure_ascii=False))
except Exception as error:
    message = str(error) if isinstance(error, RuntimeError) else '连接操作失败：' + type(error).__name__
    print(json.dumps({'ok': False, 'error': message}, ensure_ascii=False))
    sys.exit(1)
