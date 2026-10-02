import os,pathlib,subprocess,time,json
root=pathlib.Path.cwd(); ev=pathlib.Path('/Users/admin/.no-mistakes/evidence/01M3Z793827DR4CNNK5GB0VA0M'); scratch=root/'.validation-live'; sock='.validation-live/tmux.sock'
env=os.environ.copy()
for k in list(env):
    if k in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','FM_SUPERVISOR_TARGET','FM_SUPERVISOR_BACKEND','FM_TEST_HARNESS','FM_TEST_SEAM','FM_AFK_LAUNCH_ENTRY','FM_AFK_MODE','FM_AFK_STATE_PREPARED'] or k.startswith('FM_') and k.endswith('_OVERRIDE'): env.pop(k,None)
def run(args,e=env): return subprocess.run(args,env=e,text=True,capture_output=True,timeout=40)
def home(name):
    p=scratch/name; r=run(['bin/fm-lab-home.sh','create',str(p)]); assert r.returncode==0,r.stderr
    return p
def record(name,text,checks):
    (ev/(name+'.txt')).write_text(text+'\nObservable assertions:\n'+json.dumps(checks,indent=2)+'\n'); print(name,checks,flush=True); assert all(checks.values())
p=home('launcher-tmux-final'); (p/'config/supervision-host-off').touch(); e=env.copy(); e.update(FM_HOME=str(p),TMUX=f'{sock},0,0',FM_SUPERVISOR_TARGET='%0',FM_SUPERVISOR_BACKEND='tmux',FM_POLL='1',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999')
r=run(['bin/fm-afk-launch.sh','enter','--words','Validate actual detached launch only'],e); assert r.returncode==0,r.stderr
before=run(['tmux','-S',sock,'list-panes','-t','firstmate','-F','#{pane_id} #{pane_width} #{pane_height}']).stdout
r=run(['bin/fm-afk-launch.sh','start'],e)
logpath=p/'state/.supervise-daemon.log'
for _ in range(150):
    if logpath.exists() and 'daemon starting' in logpath.read_text(): break
    time.sleep(.1)
log=logpath.read_text() if logpath.exists() else ''; terminal=(p/'state/.afk-daemon-terminal').read_text() if (p/'state/.afk-daemon-terminal').exists() else ''; pid=(p/'state/.supervise-daemon.pid').read_text() if (p/'state/.supervise-daemon.pid').exists() else ''
after=run(['tmux','-S',sock,'list-panes','-t','firstmate','-F','#{pane_id} #{pane_width} #{pane_height}']).stdout
stop=run(['bin/fm-afk-launch.sh','stop'],e)
record('launcher-tmux',f'start exit: {r.returncode}\n{r.stdout}{r.stderr}\nDaemon pid: {pid}\nDaemon terminal record:\n{terminal}\nDaemon log before stop:\n{log}\nOperator pane before: {before}Operator pane after: {after}\nstop exit: {stop.returncode}\n{stop.stdout}{stop.stderr}',{'actual_daemon_launched':r.returncode==0 and 'daemon starting' in log,'captured_target_passed': 'target=%0; target_source=FM_SUPERVISOR_TARGET; backend=tmux' in log,'detached_terminal_recorded':terminal.startswith('tmux\tfm-afk-daemon-'),'operator_topology_unchanged':before==after,'stop_succeeded':stop.returncode==0,'pid_and_flag_removed':not (p/'state/.supervise-daemon.pid').exists() and not (p/'state/.afk').exists(),'terminal_record_removed':not (p/'state/.afk-daemon-terminal').exists()})
p=home('host-guard-final'); (p/'config/supervision-host').touch(); e=env.copy(); e['FM_HOME']=str(p)
r=run(['bin/fm-afk-launch.sh','start'],e)
record('host-guard',f'Exit: {r.returncode}\n{r.stdout}{r.stderr}',{'refused':r.returncode==1,'host_guard_first':'runs the supervision host' in r.stderr,'no_unavailable_refusal':'target_source=UNAVAILABLE' not in r.stderr,'no_daemon_log':not (p/'state/.supervise-daemon.log').exists()})
for name,extra,expected in [('unsupported-backend-final',{'FM_SUPERVISOR_BACKEND':'orca'},'does not support supervisor backend')]:
    p=home(name); e=env.copy(); e.update(FM_HOME=str(p)); e.update(extra)
    r=run(['bin/fm-supervise-daemon.sh'],e); log=(p/'state/.supervise-daemon.log').read_text()
    record(name,f'Exit: {r.returncode}\n{r.stderr}\nDurable log:\n{log}',{'refused':r.returncode==1,'expected_guard':expected in r.stderr,'never_armed':'daemon starting' not in log,'ownership_released':not (p/'state/.supervise-daemon.pid').exists() and not (p/'state/.supervise-daemon.lock').exists()})
