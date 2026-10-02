import pathlib,subprocess,os,time,signal,json
root=pathlib.Path.cwd(); ev=pathlib.Path('/Users/admin/.no-mistakes/evidence/01M3Z793827DR4CNNK5GB0VA0M'); home=root/'.validation-live/base-invalid-target'
r=subprocess.run(['bin/fm-lab-home.sh','create',str(home)],capture_output=True,text=True); assert r.returncode==0
base=os.environ.copy()
for k in list(base):
    if k in ['TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION'] or k.startswith('FM_') and k.endswith('_OVERRIDE'): base.pop(k,None)
base.update(FM_HOME=str(home),TMUX='.validation-live/tmux.sock,0,0',FM_SUPERVISOR_TARGET='%999999',FM_SUPERVISOR_BACKEND='tmux',FM_POLL='1',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999')
with (ev/'base-invalid-target-stderr.txt').open('w') as out:
    p=subprocess.Popen([str(root/'.validation-live/base-code/bin/fm-supervise-daemon.sh')],env=base,stdout=out,stderr=out,start_new_session=True)
    try:
        for _ in range(100):
            lp=home/'state/.supervise-daemon.log'
            if lp.exists() and 'daemon starting' in lp.read_text(): break
            if p.poll() is not None: break
            time.sleep(.1)
    finally:
        if p.poll() is None: p.send_signal(signal.SIGTERM)
        p.wait(timeout=15)
log=lp.read_text() if lp.exists() else ''; current=(root/'.validation-live/invalid-target/state/.supervise-daemon.log').read_text()
checks={'base_also_arms_missing_explicit_target':'daemon starting' in log and 'target=%999999' in log,'target_behavior_unchanged':'daemon starting' in current and 'target=%999999' in current}
(ev/'explicit-target-compatibility.txt').write_text('Exploratory invalid-target assertion was corrected: this is existing tmux behavior, not a regression from the no-handle change.\nBase log:\n'+log+'\nTarget log:\n'+current+'\n'+json.dumps(checks,indent=2)+'\n')
print(checks); assert all(checks.values())
