#!/usr/bin/env python3
"""Run offline checks everywhere and app/CLI integration checks on macOS."""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'Sources/QuotaBarCore'
CHECKS = ROOT / 'Tests/Checks'
LOCALIZATION = 'Localization/AppLocalization'
QUOTA = 'Quota/RateLimitModels'
ANALYTICS = 'Analytics/AccountUsageModels'
CLIENT_SOURCES = [LOCALIZATION, QUOTA, ANALYTICS, 'Clients/UsageFetchRetry', 'Clients/ChatGPTUsageClient',
                  'Clients/CodexAppServerClient', 'System/CodexExecutableLocator',
                  'System/CodexProcessDiagnostics']
OFFLINE_CHECKS = [
    ('Quota/ParserCheck', [LOCALIZATION, QUOTA]),
    ('Quota/WeeklyPaceCheck', [LOCALIZATION, QUOTA]),
    ('Quota/AccountQuotaHistoryCheck', [LOCALIZATION, QUOTA, 'Quota/AccountQuotaHistory']),
    ('Analytics/AccountUsageCheck', [LOCALIZATION, ANALYTICS]),
    ('Analytics/ChatGPTUsageCheck', [LOCALIZATION, ANALYTICS, 'Clients/UsageFetchRetry', 'Clients/ChatGPTUsageClient']),
    ('Clients/UsageFetchRetryCheck', ['Clients/UsageFetchRetry']),
    ('Activity/ActivityCheck', [LOCALIZATION, 'Activity/LocalActivity']),
    ('Accounts/AccountProfileStorageCheck', [LOCALIZATION, 'Accounts/AccountProfileStorage']),
    ('Localization/LocalizationCheck', [LOCALIZATION, QUOTA, 'Activity/LocalActivity']),
    ('System/ExecutableLocatorCheck', ['System/CodexExecutableLocator']),
    ('System/ProcessDiagnosticsCheck', ['System/CodexProcessDiagnostics']),
]


def run(command, **kwargs):
    return subprocess.run([str(item) for item in command], cwd=ROOT, check=True, **kwargs)


def compile_check(name, sources, temporary):
    binary = temporary / Path(name).name
    print(f'Check: {name}', flush=True)
    run(['swiftc', '-parse-as-library', *[CORE / f'{source}.swift' for source in sources],
         CHECKS / f'{name}.swift', '-o', binary])
    run([binary])
    return binary


def check_cli(handshake, temporary):
    cli = ROOT / '.build/debug/quota-bar'
    run([cli, '--help'], stdout=subprocess.DEVNULL)
    home = temporary / 'expired-quota'
    home.mkdir()
    expired = subprocess.run([str(cli), 'status', '--json'], cwd=ROOT,
        env={**os.environ, 'CODEX_PATH': str(handshake), 'CODEX_HOME': str(home)},
        capture_output=True, text=True, timeout=60)
    assert expired.returncode == 1 and not expired.stdout and 'awaiting updated quota' in expired.stderr
    run([cli, 'history', '--days', '1', '--json'], stdout=subprocess.DEVNULL)
    import json
    history = run([cli, 'history', '--days', '1', '--currency', 'AUD', '--json'], capture_output=True, text=True)
    assert json.loads(history.stdout)['currency'] == 'AUD'
    for arguments in [
        ['--days', '0'], ['--input-rate', '2', '--input-rate', 'nope'],
        ['--input-rate', 'nan'], ['--days', '--json'], ['--currency', 'GBP'],
        ['--exchange-rate', '1.5'], ['--currency', 'EUR', '--exchange-rate', '0'],
    ]:
        result = subprocess.run([str(cli), 'history', *arguments], cwd=ROOT,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        assert result.returncode == 1, arguments
    print('CLI help, history JSON, stale quota and invalid argument checks passed.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='Also query the signed-in Codex app-server (macOS only).')
    options = parser.parse_args()
    macos = platform.system() == 'Darwin'
    if options.live and not macos:
        parser.error('--live requires macOS')
    if options.live and os.environ.get('SKIP_LIVE_CODEX_CHECK') == '1':
        parser.error('Unset SKIP_LIVE_CODEX_CHECK before using --live')
    for check in ['ReleasePublishCheck.py', 'SourceArchiveCheck.py']:
        run([sys.executable, ROOT / 'Tests/Automation' / check])
    with tempfile.TemporaryDirectory(prefix='quota-bar-checks-') as directory:
        temporary = Path(directory)
        for name, sources in OFFLINE_CHECKS:
            compile_check(name, sources, temporary)
        print(f'All {len(OFFLINE_CHECKS)} portable Swift checks passed.', flush=True)
        if not macos:
            print('macOS app, CLI and app-server integration checks require a Mac; skipped.', flush=True)
            return
        handshake = compile_check('Integration/AppServerHandshakeCheck', CLIENT_SOURCES, temporary)
        if options.live:
            compile_check('Integration/LiveCheck', CLIENT_SOURCES, temporary)
        run(['swift', 'build'])
        run(['swift', 'test'])
        check_cli(handshake, temporary)


if __name__ == '__main__':
    main()
