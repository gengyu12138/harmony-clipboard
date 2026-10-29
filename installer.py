#!/usr/bin/python3
"""Install this user's app and launch agents without copying personal data."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

BASE = Path(__file__).resolve().parent
HOME_DIR = Path.home()
APP = HOME_DIR / 'Applications/接力剪贴板.app'
ROOT = HOME_DIR / 'Library/Application Support/HarmonyClipboard'
AGENTS = HOME_DIR / 'Library/LaunchAgents'
DOMAIN = 'gui/' + str(os.getuid())
PANEL = 'local.gengyu.harmony-panel'
SYNC = 'local.gengyu.harmony-clipboard'


def launch(*args, check=True):
    return subprocess.run(['/bin/launchctl', *args], check=check, capture_output=True, timeout=25)


def unload(label):
    service = DOMAIN + '/' + label
    if launch('print', service, check=False).returncode == 0:
        launch('bootout', service)
        deadline = time.monotonic() + 20
        while launch('print', service, check=False).returncode == 0:
            if time.monotonic() > deadline:
                raise RuntimeError('旧服务退出超时，请稍后重试：' + label)
            time.sleep(0.2)


def stop_panel():
    executable = str(APP / 'Contents/MacOS/HarmonyPanel')
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True,
                            text=True, check=True, timeout=5)
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or parts[1] != executable:
            continue
        pid = int(parts[0])
        try:
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 10
            while True:
                os.kill(pid, 0)
                if time.monotonic() > deadline:
                    raise RuntimeError('面板未退出，请手动退出后重试。')
                time.sleep(0.1)
        except ProcessLookupError:
            pass


def write_plist(label, value):
    path = AGENTS / (label + '.plist')
    temporary = path.with_suffix('.tmp')
    temporary.write_bytes(plistlib.dumps(dict(Label=label, **value)))
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hdc', type=Path, help='官方 macOS arm64 hdc 可执行文件的路径')
    args = parser.parse_args()
    os.umask(0o077)
    if os.uname().machine != 'arm64':
        raise RuntimeError('此安装包仅支持 Apple Silicon Mac（arm64）。')
    source = BASE / '接力剪贴板.app'
    if not source.exists():
        source = BASE / 'build/接力剪贴板.app'
    if not source.is_dir():
        raise RuntimeError('未找到应用，请先运行 build.sh 或解压完整 Release 安装包。')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(source)],
                   check=True, timeout=20)
    hdc = args.hdc.expanduser().resolve() if args.hdc else None
    if hdc:
        if not hdc.is_file() or not os.access(hdc, os.X_OK):
            raise RuntimeError('hdc 路径不是可执行文件。')
        subprocess.run([str(hdc), '-v'], check=True, timeout=10)
    APP.parent.mkdir(parents=True, exist_ok=True)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    AGENTS.mkdir(parents=True, exist_ok=True)
    (ROOT / 'bin').mkdir(exist_ok=True, mode=0o700)
    # Stage and verify before stopping the installed version; restore it if the rename fails.
    with tempfile.TemporaryDirectory(prefix='.harmony-install-', dir=APP.parent) as staging:
        staged = Path(staging) / APP.name
        shutil.copytree(source, staged)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged)],
                       check=True, timeout=20)
        unload(PANEL)
        unload(SYNC)
        stop_panel()
        previous = Path(staging) / 'previous.app'
        if APP.exists():
            APP.rename(previous)
        try:
            staged.rename(APP)
        except OSError:
            if previous.exists():
                previous.rename(APP)
            raise
        for name in ('sync.py', 'capture.py'):
            temporary = ROOT / (name + '.tmp')
            shutil.copyfile(APP / 'Contents/Resources/Bridge' / name, temporary)
            temporary.replace(ROOT / name)
        if hdc:
            for name in ('hdc', 'libusb_shared.dylib'):
                original = hdc.parent / name
                target = ROOT / 'bin' / name
                if original.is_file() and original.resolve() != target.resolve():
                    temporary = target.with_suffix(target.suffix + '.tmp')
                    shutil.copy2(original, temporary)
                    temporary.replace(target)
        write_plist(PANEL, dict(
            ProgramArguments=['/usr/bin/open', '-g', '-j', str(APP)],
            RunAtLoad=True, LimitLoadToSessionType='Aqua'))
        write_plist(SYNC, dict(
            ProgramArguments=['/usr/bin/python3', '-B', str(ROOT / 'sync.py'), 'run'],
            WorkingDirectory=str(ROOT), RunAtLoad=True, KeepAlive=True, ExitTimeOut=10,
            ThrottleInterval=10, LimitLoadToSessionType='Aqua',
            EnvironmentVariables={'LANG': 'en_US.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1'},
            StandardErrorPath='/dev/null', StandardOutPath='/dev/null'))
        launch('enable', DOMAIN + '/' + PANEL)
        launch('bootstrap', DOMAIN, str(AGENTS / (PANEL + '.plist')))
        # Honor a deliberately paused service. A new install starts it via Settings after pairing.
        disabled = launch('print-disabled', DOMAIN).stdout.decode('utf-8')
        sync_disabled = '"' + SYNC + '" => true' in disabled
        if (ROOT / 'config.json').exists() and (ROOT / 'bin/hdc').exists() and not sync_disabled:
            launch('bootstrap', DOMAIN, str(AGENTS / (SYNC + '.plist')))
    print('已安装到 ~/Applications/接力剪贴板.app，登录后后台启动。')
    print('按 Control+X 呼出，点击齿轮设置手机 IP 和端口。')
    if not (ROOT / 'bin/hdc').exists():
        print('尚未安装 hdc：目前只能使用本机面板。请使用 --hdc 参数重新运行安装程序。')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit('安装未完成：' + str(error))
