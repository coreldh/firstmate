import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path.cwd()
EVIDENCE = Path('/Users/admin/.no-mistakes/evidence/01M3ZXB3JCK4N38MK9HEYBD5ZR')
LAB = ROOT / '.l'
assert not LAB.exists(), 'refuse to adopt an existing lab'
ENV = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
for key in ('TMUX', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION',
            'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
    ENV.pop(key, None)
ENV['TMPDIR'] = str(ROOT / '.validation-supervisor-target' / 'tmp')
Path(ENV['TMPDIR']).mkdir(exist_ok=True)
REPORT = []
PROCESSES = []
SOCKET_STARTED = False


def run(args, env=None, timeout=20):
    return subprocess.run([str(x) for x in args], cwd=ROOT, env=env or ENV,
                          text=True, capture_output=True, timeout=timeout)


def tmux(*args):
    return run(['tmux', '-L', 'fm-lab', *args], ENV)


def home(label, host=False):
    path = LAB / label
    result = run(['bin/fm-lab-home.sh', 'create', path])
    assert result.returncode == 0, result.stderr
    (path / 'config' / ('supervision-host' if host else 'supervision-host-off')).touch()
    return path


def env_for(path, **extra):
    return dict(ENV, FM_HOME=str(path), FM_POLL='1', FM_HEARTBEAT='999999',
                FM_CHECK_INTERVAL='999999', FM_INJECT_FAIL_SLEEP='1', **extra)


def record(label, commands, output, checks):
    passed = all(checks.values())
    text = '\n'.join(['# ' + label, 'HEAD 937437e506016e39fe74dc4cd10cf78c1b7d906b',
                       'COMMANDS', *commands, 'PRODUCT OUTPUT', output,
                       'OBSERVED STATE', json.dumps(checks, indent=2)]) + '\n'
    (EVIDENCE / (label + '.log')).write_text(text)
    REPORT.append(dict(name=label, result='pass' if passed else 'fail', checks=checks,
                       evidence=str(EVIDENCE / (label + '.log'))))
    print(label + ': ' + ('PASS' if passed else 'FAIL'), flush=True)
    assert passed, text


def state(path):
    return {'afk': (path / 'state/.afk').exists(),
            'terminal': (path / 'state/.afk-daemon-terminal').exists(),
            'contract': (path / 'state/.afk-contract').exists(),
            'daemon_pid': (path / 'state/.supervise-daemon.pid').exists(),
            'daemon_lock': (path / 'state/.supervise-daemon.lock').exists(),
            'launcher_lock': (path / 'state/.afk-launch.lock').exists()}


def daemon(path, label, extra=None, base=False):
    env = env_for(path, **(extra or {}))
    executable = ROOT / ('.validation-supervisor-target/bin/fm-supervise-daemon.sh'
                         if base else 'bin/fm-supervise-daemon.sh')
    out = EVIDENCE / (label + '.stdout')
    err = EVIDENCE / (label + '.stderr')
    with out.open('w') as stdout, err.open('w') as stderr:
        process = subprocess.Popen([str(executable)], cwd=ROOT, env=env,
                                   stdout=stdout, stderr=stderr)
    PROCESSES.append(process)
    log = path / 'state/.supervise-daemon.log'
    deadline = time.monotonic() + 15
    while process.poll() is None and time.monotonic() < deadline:
        if log.exists() and 'daemon starting' in log.read_text():
            break
        time.sleep(0.1)
    armed = log.exists() and 'daemon starting' in log.read_text()
    alive_when_observed = process.poll() is None
    if process.poll() is None:
        process.terminate()
    rc = process.wait(timeout=15)
    return dict(rc=rc, armed=armed, alive_when_observed=alive_when_observed,
                stderr=err.read_text(), log=log.read_text() if log.exists() else '',
                state=state(path))


try:
    mint = run(['bin/fm-lab-home.sh', 'create', LAB])
    assert mint.returncode == 0, mint.stderr
    (LAB / 'tmux').mkdir()
    ENV['TMUX_TMPDIR'] = str(LAB / 'tmux')
    create = tmux('new-session', '-d', '-s', 'firstmate', '-x', '120', '-y', '40',
                  '-c', ROOT, 'bash --noprofile --norc')
    assert create.returncode == 0, create.stderr
    SOCKET_STARTED = True
    socket = tmux('display-message', '-p', '-t', 'firstmate:0', '#{socket_path}').stdout.strip()
    # This selects the owned socket only. There is deliberately no TMUX_PANE.
    ENV['TMUX'] = socket + ',0,0'
    decoy = tmux('display-message', '-p', '-t', 'firstmate:0', '#{pane_id} #{pane_current_command}').stdout

    baseline_home = home('base')
    baseline = daemon(baseline_home, 'baseline', base=True)
    record('baseline-reproduces-fallback',
           ['git archive e31bc6e620ca532c2e0e0b72f3fd7c0869a12270 bin (isolated copy)',
            'tmux -L fm-lab new-session -d -s firstmate -x 120 -y 40 bash',
            'FM_HOME=<lab/base> <base>/bin/fm-supervise-daemon.sh (no pane handles)'],
           'Existing unrelated pane: ' + decoy + json.dumps(baseline, indent=2),
           {'base_armed': baseline['armed'], 'constant_selected':
            'target=firstmate:0; target_source=FALLBACK(firstmate:0)' in baseline['log'],
            'base_stopped_and_released_lock': not baseline['state']['daemon_lock']})

    for label, extra in [('absent', {}), ('empty', {'FM_SUPERVISOR_TARGET': '', 'TMUX_PANE': '',
          'HERDR_ENV': '', 'HERDR_PANE_ID': ''}), ('incomplete-herdr', {'HERDR_ENV': '1'})]:
        h = home('refuse-' + label)
        result = daemon(h, 'daemon-' + label, extra)
        discovery = run(['bash', '-c', '. bin/fm-supervisor-target-lib.sh; discover_supervisor_target'],
                        env_for(h, **extra))
        record('daemon-refuses-' + label,
               ['FM_HOME=<isolated marked home> bin/fm-supervise-daemon.sh',
                'bash -c ". bin/fm-supervisor-target-lib.sh; discover_supervisor_target"',
                'real firstmate:0 shell remains on the private fm-lab socket'],
               decoy + json.dumps(result, indent=2) + '\nDiscovery: ' +
               json.dumps({'rc': discovery.returncode, 'stdout': discovery.stdout}),
               {'discovery_rc_1_no_output': discovery.returncode == 1 and discovery.stdout == '',
                'daemon_rc_1': result['rc'] == 1, 'stderr_UNAVAILABLE':
                'target_source=UNAVAILABLE' in result['stderr'], 'log_UNAVAILABLE':
                'target_source=UNAVAILABLE' in result['log'], 'never_armed': not result['armed'],
                'no_pid_or_locks': not any(result['state'][k] for k in
                                          ['daemon_pid', 'daemon_lock', 'launcher_lock'])})

    h = home('launch-refuse')
    enter = run(['bin/fm-afk-launch.sh', 'enter', '--words', 'isolated local test only'], env_for(h))
    assert enter.returncode == 0, enter.stderr
    contract_before = (h / 'state/.afk-contract').read_bytes()
    prior = '[2026-01-01T00:00:00+0000] existing durable log entry\n'
    (h / 'state/.supervise-daemon.log').write_text(prior)
    before_sessions = tmux('list-sessions', '-F', '#{session_id}:#{session_name}').stdout
    refusals = [run(['bin/fm-afk-launch.sh', 'start'], env_for(h)) for _ in range(2)]
    log = (h / 'state/.supervise-daemon.log').read_text()
    current = state(h)
    record('launcher-refuses-durably', ['bin/fm-afk-launch.sh enter --words "isolated local test only"',
           'bin/fm-afk-launch.sh start (twice, no pane handles)'],
           enter.stdout + '\n'.join(r.stderr for r in refusals) + log +
           json.dumps(current, indent=2),
           {'both_rc_1': all(r.returncode == 1 for r in refusals),
            'both_stderr_UNAVAILABLE': all('target_source=UNAVAILABLE' in r.stderr for r in refusals),
            'prior_log_preserved': log.startswith(prior), 'two_appended_refusals':
            log.count('refused_by=fm-afk-launch start') == 2,
            'no_flag_terminal_pid_or_lock': not any(current[k] for k in
               ['afk', 'terminal', 'daemon_pid', 'daemon_lock', 'launcher_lock']),
            'contract_unchanged': (h / 'state/.afk-contract').read_bytes() == contract_before,
            'private_sessions_unchanged': tmux('list-sessions', '-F', '#{session_id}:#{session_name}').stdout == before_sessions})

    for label, setup, expected in [('missing-record', 'none', 'an away-posture record is required'),
          ('pending-return', 'catchup', 'return catch-up is still pending'),
          ('supervision-host', 'host', 'runs the supervision host')]:
        h = home('guard-' + label, host=setup == 'host')
        if setup in ('host', 'catchup'):
            entered = run(['bin/fm-afk-launch.sh', 'enter', '--words', 'isolated guard test'], env_for(h))
            assert entered.returncode == 0, entered.stderr
        if setup == 'catchup':
            (h / 'state/.afk-return-catchup').write_text('schema\tfm-afk-return.v1\nphase\tblocked\n')
        refused = run(['bin/fm-afk-launch.sh', 'start'], env_for(h))
        current = state(h)
        record('guard-first-' + label, ['bin/fm-afk-launch.sh start without pane handles'],
               refused.stdout + refused.stderr + json.dumps(current, indent=2),
               {'refused': refused.returncode == 1, 'earlier_guard_message': expected in refused.stderr,
                'no_UNAVAILABLE_message': 'target_source=UNAVAILABLE' not in refused.stderr,
                'no_discovery_log': not (h / 'state/.supervise-daemon.log').exists(),
                'no_daemon_or_launcher_lock': not any(current[k] for k in
                    ['afk', 'terminal', 'daemon_pid', 'daemon_lock', 'launcher_lock'])})

    operator = tmux('new-session', '-d', '-P', '-F', '#{pane_id}', '-s', 'operator',
                    '-x', '120', '-y', '40', '-c', ROOT, 'bash --noprofile --norc').stdout.strip()
    assert operator.startswith('%')
    h = home('explicit')
    result = daemon(h, 'explicit-target', {'FM_SUPERVISOR_TARGET': operator,
              'FM_SUPERVISOR_BACKEND': 'tmux', 'TMUX_PANE': decoy.split()[0],
              'HERDR_ENV': '1', 'HERDR_PANE_ID': 'not-a-target'})
    record('explicit-target-keeps-precedence',
           ['FM_SUPERVISOR_TARGET=<real operator pane> FM_SUPERVISOR_BACKEND=tmux',
            'TMUX_PANE=<different real shell pane> HERDR_ENV=1 HERDR_PANE_ID=not-a-target',
            'bin/fm-supervise-daemon.sh; terminate exact test process after startup'],
           json.dumps(result, indent=2),
           {'real_daemon_armed': result['armed'] and result['alive_when_observed'],
            'selected_explicit_operator': f'target={operator}; target_source=FM_SUPERVISOR_TARGET; backend=tmux' in result['log'],
            'normal_shutdown': result['rc'] == 0 and not result['state']['daemon_lock']})

    h = home('native')
    run(['bin/fm-afk-launch.sh', 'enter', '--words', 'isolated native path test'], env_for(h))
    native = run(['bin/fm-afk-launch.sh', 'start-native'], env_for(h))
    result = daemon(h, 'native-no-handle')
    record('native-known-limitation', ['bin/fm-afk-launch.sh enter; bin/fm-afk-launch.sh start-native',
           'bin/fm-supervise-daemon.sh without pane handles'], native.stdout + native.stderr +
           json.dumps(result, indent=2),
           {'preparation_succeeded': native.returncode == 0, 'daemon_refused_rc_1': result['rc'] == 1,
            'afk_flag_remains_as_documented': result['state']['afk'],
            'refusal_durable': 'target_source=UNAVAILABLE' in result['log'],
            'no_live_daemon_lock_or_pid': not result['state']['daemon_lock'] and not result['state']['daemon_pid']})

    h = home('auto')
    command = f'env FM_HOME={h} FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 {ROOT}/bin/fm-supervise-daemon.sh >{EVIDENCE}/auto.stdout 2>{EVIDENCE}/auto.stderr'
    created = tmux('new-session', '-d', '-P', '-F', '#{pane_id}', '-s', 'auto',
                   '-x', '120', '-y', '40', '-c', ROOT, command)
    assert created.returncode == 0, created.stderr
    pane = created.stdout.strip()
    logpath = h / 'state/.supervise-daemon.log'
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if logpath.exists() and 'daemon starting' in logpath.read_text():
            break
        time.sleep(0.1)
    observed = logpath.read_text() if logpath.exists() else ''
    pid = int((h / 'state/.supervise-daemon.pid').read_text())
    os.kill(pid, 15)
    deadline = time.monotonic() + 15
    while (h / 'state/.supervise-daemon.lock').exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    record('tmux-inherited-pane-arms', ['tmux -L fm-lab new-session -s auto -x 120 -y 40 bin/fm-supervise-daemon.sh',
            'daemon inherits the actual TMUX_PANE; no target override'],
           logpath.read_text() + (EVIDENCE / 'auto.stderr').read_text(),
           {'daemon_armed_in_actual_pane': f'target={pane}; target_source=TMUX_PANE; backend=tmux; backend_source=TMUX_PANE' in observed,
            'clean_shutdown': not state(h)['daemon_pid'] and not state(h)['daemon_lock']})
finally:
    for process in PROCESSES:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=15)
    if SOCKET_STARTED:
        stopped = tmux('kill-server')
        (EVIDENCE / 'tmux-teardown.log').write_text('Owned fm-lab socket: ' + ENV.get('TMUX', '') +
            '\nkill-server rc=' + str(stopped.returncode) + '\n' + stopped.stderr)
    if LAB.exists():
        shutil.rmtree(LAB)
    (EVIDENCE / 'live-results.json').write_text(json.dumps(REPORT, indent=2) + '\n')
