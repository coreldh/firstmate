#!/usr/bin/env python3
"""Drive real Firstmate entrypoints and a private real tmux server; no stubs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path('/Users/admin/.no-mistakes/worktrees/57ee2c16a82d/01M3ZYSES4EX4N46PB1WM7APD0')
EVIDENCE = Path('/Users/admin/.no-mistakes/evidence/01M3ZYSES4EX4N46PB1WM7APD0')
SCRATCH = ROOT / '.validation-supervisor-target'
BASE = 'e31bc6e620ca532c2e0e0b72f3fd7c0869a12270'
TARGET = '06debe10b1bfeda5a0b5c3bcdaf7574e7e933b26'
ENV = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') or k.startswith('HERDR_') or k in ('TMUX', 'TMUX_PANE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'))}
ENV['FM_WEDGE_ALARM_EXEC'] = 'discard'
results = []
transcript = []
homes = []
socket_dir = None
live_procs = []


def command(args, env=None, check=True, timeout=25):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env or ENV,
                       capture_output=True, text=True, timeout=timeout)
    transcript.append({'argv': [str(a) for a in args], 'rc': p.returncode,
                       'stdout': p.stdout, 'stderr': p.stderr})
    if check and p.returncode != 0:
        raise AssertionError(f'{args}: rc={p.returncode}: {p.stderr}')
    return p


def lab(name):
    p = Path(tempfile.mkdtemp(prefix=name + '-', dir=SCRATCH))
    command([ROOT / 'bin/fm-lab-home.sh', 'create', p])
    homes.append(p)
    return p


def environment(home, **extra):
    e = dict(ENV, FM_HOME=str(home), FM_POLL='1', FM_HEARTBEAT='999999',
             FM_CHECK_INTERVAL='999999', FM_INJECT_FAIL_SLEEP='1')
    if socket_dir:
        e['TMUX_TMPDIR'] = socket_dir
        e['TMUX'] = tmux_identity
    e.update(extra)
    return e


def persist_state(label, home):
    state = {}
    for name in ('.afk', '.afk-contract', '.afk-daemon-terminal', '.supervise-daemon.pid',
                 '.supervise-daemon.lock', '.afk-launch.lock', '.supervise-daemon.log'):
        p = home / 'state' / name
        state[name] = {'exists': os.path.lexists(p), 'directory': p.is_dir()}
        if p.is_file():
            state[name]['content'] = p.read_text()
    (EVIDENCE / f'{label}-state.json').write_text(json.dumps(state, indent=2) + '\n')
    return state


def daemon(label, home, extra=None, code=ROOT):
    e = environment(home, **(extra or {}))
    out = open(EVIDENCE / f'{label}.stdout.log', 'w')
    err = open(EVIDENCE / f'{label}.stderr.log', 'w')
    args = [str(code / 'bin/fm-supervise-daemon.sh')]
    p = subprocess.Popen(args, cwd=ROOT, env=e, stdout=out, stderr=err)
    live_procs.append(p)
    armed = False
    try:
        end = time.monotonic() + 15
        while time.monotonic() < end:
            log = home / 'state/.supervise-daemon.log'
            text = log.read_text() if log.exists() else ''
            if 'daemon starting' in text:
                armed = True
                break
            if p.poll() is not None:
                break
            time.sleep(.1)
        if p.poll() is None:
            p.terminate()
        rc = p.wait(timeout=15)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
        out.close()
        err.close()
        live_procs.remove(p)
    stderr = (EVIDENCE / f'{label}.stderr.log').read_text()
    stdout = (EVIDENCE / f'{label}.stdout.log').read_text()
    state = persist_state(label, home)
    transcript.append({'argv': args, 'env': {k: e[k] for k in e if k.startswith(('FM_', 'TMUX', 'HERDR_'))},
                       'rc': rc, 'armed': armed, 'stdout': stdout, 'stderr': stderr, 'state': state})
    return armed, rc, stderr, state


def case(name, fn, live=True):
    try:
        detail = fn()
        result = {'name': name, 'result': 'pass', 'live': live, 'evidence': detail, 'reason': ''}
    except Exception as exc:
        result = {'name': name, 'result': 'fail', 'live': live, 'evidence': 'product-transcript.json', 'reason': str(exc)}
    results.append(result)
    print(json.dumps(result), flush=True)


def discovery():
    for extra in ({}, {'HERDR_ENV': '1'}, {'HERDR_PANE_ID': 'w1:p9'}):
        e = dict(ENV, **extra)
        p = command(['bash', '-c', '. "$1"; discover_supervisor_target', '_', ROOT / 'bin/fm-supervisor-target-lib.sh'], e, check=False)
        assert p.returncode == 1 and p.stdout == '', (extra, p.returncode, p.stdout)
    return 'product-transcript.json: executed discovery returns 1 with zero stdout bytes, including incomplete Herdr identity'


def regression():
    old = SCRATCH / 'base-code'
    old.mkdir()
    archive = subprocess.run(['git', 'archive', BASE, 'bin'], cwd=ROOT, capture_output=True, check=True)
    subprocess.run(['tar', '-x', '-C', str(old)], input=archive.stdout, check=True)
    p = command(['bash', '-c', '. "$1"; discover_supervisor_target', '_', old / 'bin/fm-supervisor-target-lib.sh'], ENV, check=False)
    assert p.returncode == 1 and p.stdout == 'firstmate:0'
    home = lab('baseline')
    command([old / 'bin/fm-afk-launch.sh', 'enter', '--words', 'Disposable regression control.'], environment(home))
    command([old / 'bin/fm-afk-launch.sh', 'start-native'], environment(home))
    armed, rc, err, state = daemon('baseline-fallback', home, code=old)
    assert armed and 'target_source=FALLBACK(firstmate:0)' in state['.supervise-daemon.log']['content']
    assert state['.afk']['exists'] and 'afk=on' in state['.supervise-daemon.log']['content']
    return 'baseline-fallback-state.json: real pre-fix daemon armed at unrelated firstmate:0 on the private tmux server'


def refuse():
    home = lab('no-handle')
    for iteration in (1, 2):
        armed, rc, err, state = daemon(f'no-handle-{iteration}', home)
        assert not armed and rc == 1 and 'target_source=UNAVAILABLE' in err
        log = state['.supervise-daemon.log']['content']
        assert 'target_source=UNAVAILABLE' in log and 'daemon starting' not in log
        assert not state['.supervise-daemon.pid']['exists'] and not state['.supervise-daemon.lock']['exists']
        assert 'firstmate:0' not in err
    assert state['.supervise-daemon.log']['content'].count('startup refused') == 2
    after = tmux(['capture-pane', '-p', '-t', 'firstmate:0']).stdout
    assert after == crew_capture
    return 'no-handle-1.stderr.log, no-handle-2-state.json, product-transcript.json: two refusals, lock/pid cleanup, unrelated pane untouched'


def enter(home):
    p = command([ROOT / 'bin/fm-afk-launch.sh', 'enter', '--words', 'Disposable validation: record the refusal only.'], environment(home))
    assert (home / 'state/.afk-contract').is_file()
    return p


def launcher_refusal():
    home = lab('launcher-refusal')
    enter(home)
    record = (home / 'state/.afk-contract').read_bytes()
    for iteration in (1, 2):
        p = command([ROOT / 'bin/fm-afk-launch.sh', 'start'], environment(home), check=False)
        assert p.returncode == 1 and 'target_source=UNAVAILABLE' in p.stderr
        assert 'firstmate:0' not in p.stderr
        state = persist_state(f'launcher-refusal-{iteration}', home)
        for name in ('.afk', '.afk-daemon-terminal', '.supervise-daemon.pid', '.supervise-daemon.lock', '.afk-launch.lock'):
            assert not state[name]['exists'], name
        assert (home / 'state/.afk-contract').read_bytes() == record
    assert state['.supervise-daemon.log']['content'].count('refused_by=fm-afk-launch start') == 2
    command([ROOT / 'bin/fm-afk-launch.sh', 'stop'], environment(home))
    return 'launcher-refusal-2-state.json and product-transcript.json: start refused twice, record unchanged, no terminal or away flag'


def guards():
    home = lab('missing-record')
    p = command([ROOT / 'bin/fm-afk-launch.sh', 'start'], environment(home), check=False)
    assert p.returncode == 1 and 'an away-posture record is required' in p.stderr and 'UNAVAILABLE' not in p.stderr
    assert not (home / 'state/.supervise-daemon.log').exists()
    persist_state('guard-missing-record', home)
    home = lab('pending-return')
    (home / 'state/.afk-return-catchup').write_text('schema\tfm-afk-return.v1\nphase\tblocked\n')
    p = command([ROOT / 'bin/fm-afk-launch.sh', 'start'], environment(home), check=False)
    assert p.returncode == 1 and 'return catch-up is still pending' in p.stderr and 'UNAVAILABLE' not in p.stderr
    assert not (home / 'state/.supervise-daemon.log').exists()
    persist_state('guard-pending-return', home)
    home = lab('supervision-host')
    (home / 'config/supervision-host').touch()
    enter(home)
    p = command([ROOT / 'bin/fm-afk-launch.sh', 'start'], environment(home), check=False)
    assert p.returncode == 1 and 'runs the supervision host' in p.stderr and 'UNAVAILABLE' not in p.stderr
    assert not (home / 'state/.supervise-daemon.log').exists()
    persist_state('guard-supervision-host', home)
    return 'guard-*-state.json and product-transcript.json: missing record, pending return, and real Codex host opt-in guards precede discovery'


def handles():
    for label, extra, source in (
        ('explicit', {'FM_SUPERVISOR_TARGET': operator_pane, 'FM_SUPERVISOR_BACKEND': 'tmux', 'TMUX_PANE': crew_pane}, 'FM_SUPERVISOR_TARGET'),
        ('explicit-default-backend', {'FM_SUPERVISOR_TARGET': operator_pane}, 'FM_SUPERVISOR_TARGET'),
        ('inherited-tmux', {'TMUX_PANE': operator_pane}, 'TMUX_PANE'),
    ):
        home = lab(label)
        armed, rc, err, state = daemon(label, home, extra)
        assert armed and rc == 0, (label, rc, err)
        log = state['.supervise-daemon.log']['content']
        assert f'target={operator_pane}; target_source={source}; backend=tmux' in log
        assert not state['.supervise-daemon.pid']['exists'] and not state['.supervise-daemon.lock']['exists']
    return 'explicit-state.json, explicit-default-backend-state.json, inherited-tmux-state.json: real panes arm, override outranks another inherited pane, explicit target retains implicit tmux transport, graceful stop cleans ownership'


def launch_tmux():
    home = lab('real-launch')
    e = environment(home, TMUX_PANE=operator_pane)
    enter(home)
    topology_before = tmux(['list-panes', '-t', 'operator', '-F', '#{pane_id}:#{pane_width}:#{pane_height}']).stdout
    command([ROOT / 'bin/fm-afk-launch.sh', 'start'], e)
    end = time.monotonic() + 15
    while time.monotonic() < end:
        log = home / 'state/.supervise-daemon.log'
        if log.exists() and 'daemon starting' in log.read_text():
            break
        time.sleep(.1)
    state = persist_state('real-launch-running', home)
    assert f'target={operator_pane}; target_source=FM_SUPERVISOR_TARGET' in state['.supervise-daemon.log']['content']
    assert state['.afk']['exists'] and state['.afk-daemon-terminal']['exists']
    topology_after = tmux(['list-panes', '-t', 'operator', '-F', '#{pane_id}:#{pane_width}:#{pane_height}']).stdout
    assert topology_before == topology_after
    command([ROOT / 'bin/fm-afk-launch.sh', 'stop'], e)
    state = persist_state('real-launch-stopped', home)
    for name in ('.afk', '.afk-contract', '.afk-daemon-terminal', '.supervise-daemon.pid', '.supervise-daemon.lock'):
        assert not state[name]['exists'], name
    assert not tmux(['has-session', '-t', 'fm-afk-daemon'], check=False).returncode == 0
    return 'real-launch-running-state.json, real-launch-stopped-state.json: launcher created the real daemon separately, preserved operator geometry, then stopped it'


def native_limitation():
    home = lab('native-sequence')
    enter(home)
    command([ROOT / 'bin/fm-afk-launch.sh', 'start-native'], environment(home))
    assert (home / 'state/.afk').exists()
    p = command([ROOT / 'bin/fm-afk-start.sh'], environment(home), check=False)
    assert p.returncode == 1 and 'target_source=UNAVAILABLE' in p.stderr
    state = persist_state('native-sequence-refused', home)
    assert state['.afk']['exists'] and state['.afk-daemon-terminal']['exists']
    assert not state['.supervise-daemon.pid']['exists'] and not state['.supervise-daemon.lock']['exists']
    assert 'daemon starting' not in state['.supervise-daemon.log']['content']
    command([ROOT / 'bin/fm-afk-launch.sh', 'stop'], environment(home))
    return 'native-sequence-refused-state.json: real start-native/start sequence keeps the documented away flag after daemon refusal; native Claude/Grok background tool not exercised'


def herdr():
    e = dict(ENV, FM_HERDR_LAB_STATE_DIR=str(SCRATCH / 'herdr-state'))
    session = 'fm-lab-supervisor-01m3zy'
    p = command([ROOT / 'bin/fm-herdr-lab.sh', 'prepare', session], e, check=False)
    (EVIDENCE / 'herdr-lab-prepare.log').write_text(f'exit={p.returncode}\n{p.stdout}{p.stderr}')
    if p.returncode != 0:
        results.append({'name': 'La identidad Herdr conserva el arranque en una sesión aislada real',
                        'result': 'untested', 'live': False, 'evidence': 'herdr-lab-prepare.log',
                        'reason': 'Se intentó prepare de fm-lab-supervisor-01m3zy con el helper obligatorio. Rechazó porque no existe exactamente una sesión default en ejecución para la tripwire. El contrato exige prepare antes de provision; crear o arrancar default está fuera de la autoridad de esta fase. El operador debe proporcionar una sesión default saludable y repetir; no se usó una CLI simulada ni se alteró default.'})
        print(json.dumps(results[-1]), flush=True)
        return
    raise RuntimeError('Herdr prepare unexpectedly succeeded: extend driver with guarded provision/run/teardown before proceeding')


def tmux(args, check=True):
    return command(['tmux', '-L', 'fm-lab', *args], dict(ENV, TMUX_TMPDIR=socket_dir), check=check)


try:
    assert command(['git', 'rev-parse', 'HEAD']).stdout.strip() == TARGET
    command(['tmux', '-V'])
    command(['bin/fm-harness.sh'])
    sockhome = lab('socket-owner')
    socket_dir = command([ROOT / 'bin/fm-lab-home.sh', 'tmux-dir', sockhome]).stdout.strip()
    # Short private path comes from the supported helper; -L fm-lab is never the operator server.
    tmux(['new-session', '-d', '-s', 'firstmate', '-x', '120', '-y', '40', '-c', str(ROOT),
          'bash -c "printf UNRELATED_CREW_PANE; exec sleep 600"'])
    tmux(['new-session', '-d', '-s', 'operator', '-x', '120', '-y', '40', '-c', str(ROOT), 'sleep 600'])
    tmux_identity = tmux(['display-message', '-p', '-t', 'operator:0', '#{socket_path},#{pid},0']).stdout.strip()
    operator_pane = tmux(['display-message', '-p', '-t', 'operator:0', '#{pane_id}']).stdout.strip()
    crew_pane = tmux(['display-message', '-p', '-t', 'firstmate:0', '#{pane_id}']).stdout.strip()
    crew_capture = tmux(['capture-pane', '-p', '-t', 'firstmate:0']).stdout
    case('La versión anterior arma por error contra un firstmate:0 ajeno; control de regresión', regression)
    case('Descubrimiento sin identidad devuelve 1 y ningún destino', discovery)
    case('El daemon rechaza sin identidad aunque exista firstmate:0, registra el motivo y libera su propiedad', refuse)
    case('start rechaza sin identidad y conserva el registro, sin crear indicador ni terminal', launcher_refusal)
    case('Las condiciones previas del launcher siguen rechazando antes del descubrimiento', guards)
    case('La identidad explícita y TMUX_PANE real conservan el arranque y la prioridad', handles)
    case('El launcher arranca y detiene el daemon real sin dividir el panel del operador', launch_tmux)
    case('La secuencia start-native conserva la limitación documentada después del rechazo', native_limitation)
    herdr()
finally:
    for p in live_procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
    if socket_dir:
        tmux(['kill-server'], check=False)
        command([ROOT / 'bin/fm-lab-home.sh', 'teardown', sockhome])
    for home in homes:
        shutil.rmtree(home)
    (EVIDENCE / 'product-transcript.json').write_text(json.dumps(transcript, indent=2) + '\n')
    (EVIDENCE / 'live-results.json').write_text(json.dumps(results, indent=2) + '\n')
