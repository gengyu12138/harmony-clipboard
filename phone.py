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
from sync import SERVER, MAX_BYTES, validate_endpoint, atomic_json, control


def main():
    action = sys.argv[1]
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
        control('start', quiet=True)
        return {'message': '地址已保存，正在连接；如手机出现调试授权提示，请允许。'}
    if action in ('start', 'stop'):
        if action == 'start' and not (ROOT / 'config.json').exists():
            raise RuntimeError('请先在“手机连接设置”中填写 IP 和端口。')
        control(action, quiet=True)
        return {'message': '手机同步已启用' if action == 'start' else '手机同步及其登录自启已暂停；本机历史仍会记录'}
    if not (ROOT / 'config.json').exists():
        raise RuntimeError('请先在“手机连接设置”中填写 IP 和端口。')
    endpoint = validate_endpoint(json.loads((ROOT / 'config.json').read_text())['endpoint'])
    env = dict(os.environ, OHOS_HDC_CMD_RECORD='0', OHOS_HDC_LOG_LEVEL='0', OHOS_HDC_ENCRYPT_CHANNEL='1')

    def remote(command):
        result = subprocess.run([str(ROOT / 'bin/hdc'), '-p', '-s', SERVER, '-l0',
                                 '-t', endpoint, 'shell', command], env=env,
                                capture_output=True, timeout=12)
        if result.returncode:
            raise RuntimeError('手机连接不可用，请检查 Wi-Fi 和无线调试。')
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
