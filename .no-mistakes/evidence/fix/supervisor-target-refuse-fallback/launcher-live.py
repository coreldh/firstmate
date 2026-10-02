import os,pathlib,subprocess as sp,time,json,shutil
r=pathlib.Path.cwd(); h=r/'.validation-launcher-live'; ev=pathlib.Path('/Users/admin/.no-mistakes/evidence/01M3Z3B8GPATG6DATDSPKBZ9QC'); records=[]; sock=None
e={k:v for k,v in os.environ.items() if not(k.startswith('FM_') or k in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH'])}
def run(a):
 p=sp.run(a,env=e,text=True,capture_output=True,timeout=40); records.append({'command':a,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr}); return p
try:
 assert run(['bin/fm-lab-home.sh','create',str(h)]).returncode==0
 (h/'config/supervision-host-off').touch(); sock=run(['bin/fm-lab-home.sh','tmux-dir',str(h)]).stdout.strip(); e.update(FM_HOME=str(h),TMUX_TMPDIR=sock,FM_POLL='1',FM_HEARTBEAT='999999')
 assert run(['tmux','-L','fm-lab','new-session','-d','-s','operator','sleep 600']).returncode==0
 e['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','operator:0','#{socket_path},#{pid},0']).stdout.strip(); e['TMUX_PANE']=run(['tmux','-L','fm-lab','display-message','-p','-t','operator:0','#{pane_id}']).stdout.strip()
 assert run(['bin/fm-afk-launch.sh','enter']).returncode==0
 assert run(['bin/fm-afk-launch.sh','start']).returncode==0
 log=h/'state/.supervise-daemon.log'; end=time.monotonic()+10
 while time.monotonic()<end:
  if log.exists() and 'daemon starting' in log.read_text():break
  time.sleep(.1)
 text=log.read_text(); assert 'target='+e['TMUX_PANE']+';' in text and 'daemon starting' in text
 records.append({'started_log':text,'daemon_terminal':(h/'state/.afk-daemon-terminal').read_text(),'afk':(h/'state/.afk').exists()})
 assert run(['bin/fm-afk-launch.sh','stop']).returncode==0
 assert not(h/'state/.afk').exists() and not(h/'state/.afk-daemon-terminal').exists() and not(h/'state/.supervise-daemon.pid').exists() and not(h/'state/.supervise-daemon.lock').exists()
 records.append({'stopped_log':log.read_text(),'remaining_state':sorted(p.name for p in (h/'state').iterdir())})
 print(json.dumps(records,indent=2))
finally:
 if sock:run(['tmux','-L','fm-lab','kill-server']);run(['bin/fm-lab-home.sh','teardown',str(h)])
 (ev/'launcher-live.json').write_text(json.dumps(records,indent=2)); shutil.rmtree(h)
