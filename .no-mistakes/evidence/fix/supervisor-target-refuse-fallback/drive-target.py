import os, pathlib, subprocess, time, json, signal, tarfile, io
root=pathlib.Path.cwd(); scratch=root/'.validation-live'; evidence=pathlib.Path('/Users/admin/.no-mistakes/evidence/01M3Z793827DR4CNNK5GB0VA0M')
baseenv=os.environ.copy()
for key in list(baseenv):
    if key in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','FM_SUPERVISOR_TARGET','FM_SUPERVISOR_BACKEND','FM_TEST_HARNESS','FM_TEST_SEAM','FM_AFK_LAUNCH_ENTRY','FM_AFK_MODE','FM_AFK_STATE_PREPARED'] or key.startswith('FM_') and key.endswith('_OVERRIDE'):
        baseenv.pop(key,None)
sock='.validation-live/tmux.sock'
tmuxenv=baseenv.copy(); tmuxenv['TMUX']=f'{sock},0,0'
results=[]
def run(args,env=baseenv):
    return subprocess.run([str(x) for x in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=40)
def home(name):
    p=scratch/name
    r=run(['bin/fm-lab-home.sh','create',p]); assert r.returncode==0,r.stderr
    (p/'config/supervision-host-off').touch()
    return p
def envhome(p,extra=None):
    env=baseenv.copy(); env['FM_HOME']=str(p); env['FM_POLL']='1'; env['FM_HEARTBEAT']='999999'; env['FM_CHECK_INTERVAL']='999999'
    if extra: env.update(extra)
    return env
def record(name,output,checks):
    passed=all(checks.values()); results.append({'name':name,'pass':passed,'checks':checks})
    (evidence/(name+'.txt')).write_text(output+'\nObservable assertions:\n'+json.dumps(checks,indent=2)+'\n')
    print(name,passed,checks,flush=True)
def daemon(name,extra=None,code=root):
    p=home(name); env=envhome(p,extra)
    outpath=evidence/(name+'-stdout.txt'); errpath=evidence/(name+'-stderr.txt')
    with outpath.open('w') as out,errpath.open('w') as err:
        proc=subprocess.Popen([str(code/'bin/fm-supervise-daemon.sh')],env=env,stdout=out,stderr=err,start_new_session=True)
        deadline=time.monotonic()+15
        while proc.poll() is None and time.monotonic()<deadline:
            log=(p/'state/.supervise-daemon.log')
            if log.exists() and 'daemon starting' in log.read_text(): break
            time.sleep(.1)
        armed=proc.poll() is None and (p/'state/.supervise-daemon.log').exists() and 'daemon starting' in (p/'state/.supervise-daemon.log').read_text()
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try: proc.wait(timeout=12)
            except subprocess.TimeoutExpired: os.killpg(proc.pid,signal.SIGKILL); proc.wait()
    log=(p/'state/.supervise-daemon.log').read_text() if (p/'state/.supervise-daemon.log').exists() else ''
    err=errpath.read_text(); rc=proc.returncode
    text=f'Command: {code}/bin/fm-supervise-daemon.sh\nEnvironment: FM_HOME={p}; pane overrides={extra}\nExit: {rc}; armed observed: {armed}\nStderr:\n{err}\nDurable daemon log:\n{log}'
    return p,rc,armed,log,err,text
# The constant actually resolves in this private server; it is a sleep shell, not an operator.
probe=run(['tmux','-S',sock,'display-message','-p','-t','firstmate:0','#{pane_id} #{pane_current_command}']); assert probe.returncode==0
p,rc,armed,log,err,text=daemon('no-handle',{'TMUX':tmuxenv['TMUX']})
record('no-handle',text+'\nUnrelated existing pane: '+probe.stdout,{'exit_exactly_1':rc==1,'stderr_unavailable':'target_source=UNAVAILABLE' in err,'log_unavailable':'target_source=UNAVAILABLE' in log,'never_armed':not armed and 'daemon starting' not in log,'pid_removed':not (p/'state/.supervise-daemon.pid').exists(),'lock_released':not (p/'state/.supervise-daemon.lock').exists()})
# Repeated refusal proves the first attempt released its singleton lock.
r=run(['bin/fm-supervise-daemon.sh'],envhome(p,{'TMUX':tmuxenv['TMUX']}))
record('refusal-retry',f'Exit: {r.returncode}\nStderr:\n{r.stderr}\nLog:\n'+(p/'state/.supervise-daemon.log').read_text(),{'exit_1':r.returncode==1,'unavailable_again':'target_source=UNAVAILABLE' in r.stderr,'no_singleton_collision':'already running' not in r.stderr})
# Shared executable discovery interface, no source assertions.
r=run(['bash','-c','. bin/fm-supervisor-target-lib.sh; discover_supervisor_target'])
record('discovery-empty',f'Exit: {r.returncode}\nStdout bytes: {r.stdout.encode()!r}\nStderr: {r.stderr}',{'exit_1':r.returncode==1,'zero_stdout_bytes':r.stdout==''})
# Actual launcher path with real entry command and no replaced backend or daemon.
p=home('launcher-refusal'); env=envhome(p)
r=run(['bin/fm-afk-launch.sh','enter','--words','Validate refusal only'],env); assert r.returncode==0,r.stderr
prior=(p/'state/.afk-contract').read_bytes()
old='[2000-01-01T00:00:00+0000] prior entry retained\n'; (p/'state/.supervise-daemon.log').write_text(old)
sessions_before=run(['tmux','-S',sock,'list-sessions']).stdout
r=run(['bin/fm-afk-launch.sh','start'],env); log=(p/'state/.supervise-daemon.log').read_text()
record('launcher-refusal',f'Command: bin/fm-afk-launch.sh enter; bin/fm-afk-launch.sh start\nExit: {r.returncode}\nStderr:\n{r.stderr}\nLog:\n{log}',{'exit_1':r.returncode==1,'stderr_unavailable':'target_source=UNAVAILABLE' in r.stderr,'append_only_log':log.startswith(old) and 'target_source=UNAVAILABLE' in log,'record_unchanged':prior==(p/'state/.afk-contract').read_bytes(),'no_flag':not (p/'state/.afk').exists(),'no_terminal_record':not (p/'state/.afk-daemon-terminal').exists(),'no_daemon_pid':not (p/'state/.supervise-daemon.pid').exists(),'sessions_unchanged':sessions_before==run(['tmux','-S',sock,'list-sessions']).stdout})
# Guards still take precedence over target discovery.
p=home('missing-record'); r=run(['bin/fm-afk-launch.sh','start'],envhome(p))
record('missing-record',f'Exit: {r.returncode}\n{r.stderr}',{'refused':r.returncode==1,'record_guard_first':'away-posture record is required' in r.stderr,'no_target_refusal':'target_source=UNAVAILABLE' not in r.stderr,'no_daemon_log':not (p/'state/.supervise-daemon.log').exists()})
p=home('pending-return'); (p/'state/.afk-return-catchup').write_text('schema\tfm-afk-return.v1\nphase\tblocked\n'); r=run(['bin/fm-afk-launch.sh','start'],envhome(p))
record('pending-return',f'Exit: {r.returncode}\n{r.stderr}',{'refused':r.returncode==1,'return_guard_first':'return catch-up is still pending' in r.stderr,'no_target_refusal':'target_source=UNAVAILABLE' not in r.stderr,'no_daemon_log':not (p/'state/.supervise-daemon.log').exists()})
# Explicit target wins over a conflicting implicit pane; real tmux validates the target.
pane=probe.stdout.split()[0]
p,rc,armed,log,err,text=daemon('explicit-handle',{'TMUX':tmuxenv['TMUX'],'FM_SUPERVISOR_TARGET':pane,'TMUX_PANE':'%999999','FM_SUPERVISOR_BACKEND':'tmux'})
record('explicit-handle',text,{'armed':armed,'explicit_target_used':f'target={pane}; target_source=FM_SUPERVISOR_TARGET; backend=tmux' in log,'clean_shutdown':rc==0,'pid_removed':not (p/'state/.supervise-daemon.pid').exists()})
# Implicit pane inherited from a genuine tmux session, rather than an invented id.
p=home('inherited-tmux'); env=envhome(p)
command=f"env FM_HOME='{p}' FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 '{root}/bin/fm-supervise-daemon.sh' >'{evidence}/inherited-tmux-stdout.txt' 2>'{evidence}/inherited-tmux-stderr.txt'"
r=run(['tmux','-S',sock,'new-session','-d','-s','operator','-x','120','-y','40',command],env); assert r.returncode==0,r.stderr
for _ in range(150):
    lp=p/'state/.supervise-daemon.log'
    if lp.exists() and 'daemon starting' in lp.read_text(): break
    time.sleep(.1)
log=lp.read_text() if lp.exists() else ''; armed='daemon starting' in log
if (p/'state/.supervise-daemon.pid').exists():
    os.kill(int((p/'state/.supervise-daemon.pid').read_text()),signal.SIGTERM)
    for _ in range(100):
        if not (p/'state/.supervise-daemon.pid').exists(): break
        time.sleep(.1)
record('inherited-tmux',f'Command: tmux -S {sock} new-session -d -s operator <real daemon>\nLog:\n'+(lp.read_text() if lp.exists() else '')+'\nStderr:\n'+(evidence/'inherited-tmux-stderr.txt').read_text(),{'armed':armed,'inherited_pane_source':'target_source=TMUX_PANE; backend=tmux; backend_source=TMUX_PANE' in log,'clean_shutdown':not (p/'state/.supervise-daemon.pid').exists()})
# Native preparation's known limitation is preserved and its subsequent refusal recorded.
p=home('native-no-handle'); env=envhome(p)
r=run(['bin/fm-afk-launch.sh','enter','--words','Validate native refusal only'],env); assert r.returncode==0,r.stderr
r=run(['bin/fm-afk-launch.sh','start-native'],env); prepared=r.returncode==0 and (p/'state/.afk').exists()
r2=run(['bin/fm-afk-start.sh'],env); log=(p/'state/.supervise-daemon.log').read_text()
record('native-no-handle',f'start-native exit: {r.returncode}\n{r.stderr}\nfm-afk-start exit: {r2.returncode}\n{r2.stdout}{r2.stderr}\nDurable log:\n{log}',{'native_prepared':prepared,'daemon_refused':r2.returncode==1 and 'target_source=UNAVAILABLE' in r2.stderr,'flag_remains_as_documented':(p/'state/.afk').exists(),'refusal_logged':'target_source=UNAVAILABLE' in log,'no_armed_start':'daemon starting' not in log,'no_pid_or_lock':not (p/'state/.supervise-daemon.pid').exists() and not (p/'state/.supervise-daemon.lock').exists()})
# Behavioral before/after discriminator from the base commit, in an isolated source copy.
basecode=scratch/'base-code'; basecode.mkdir()
archive=subprocess.check_output(['git','archive','87fa81b8b7f6912f84658d52d816bb9bcc2c5da6','bin'])
with tarfile.open(fileobj=io.BytesIO(archive)) as tar: tar.extractall(basecode,filter='data')
p,rc,armed,log,err,text=daemon('base-no-handle',{'TMUX':tmuxenv['TMUX']},code=basecode)
record('base-regression',text,{'old_behavior_reproduced':armed and 'target_source=FALLBACK(firstmate:0)' in log,'fixed_version_refuses':results[0]['pass']})
(evidence/'results.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(x['pass'] for x in results),'Failed scenario; inspect evidence'
