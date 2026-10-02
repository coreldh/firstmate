import os, pathlib, subprocess as sp, time, json, shutil
root=pathlib.Path.cwd(); evidence=pathlib.Path('/Users/admin/.no-mistakes/evidence/01M3Z3B8GPATG6DATDSPKBZ9QC'); labs=root/'.validation-live-target'
labs.mkdir(); records=[]; homes=[]; children=[]
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH'])}
def run(args,e=env):
 p=sp.run(args,env=e,text=True,stdout=sp.PIPE,stderr=sp.PIPE,timeout=40)
 records.append({'command':args,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr}); return p
def home(name):
 h=labs/name; run(['bin/fm-lab-home.sh','create',str(h)]); homes.append(h); (h/'config/supervision-host-off').touch(); return h
socket=None
try:
 h=home('socket'); socket=run(['bin/fm-lab-home.sh','tmux-dir',str(h)]).stdout.strip(); te=dict(env,TMUX_TMPDIR=socket)
 assert run(['tmux','-L','fm-lab','new-session','-d','-s','firstmate','-c',str(root),'sleep 600'],te).returncode==0
 pane=run(['tmux','-L','fm-lab','display-message','-p','-t','firstmate:0','#{pane_id}'],te).stdout.strip()
 tmux_value=run(['tmux','-L','fm-lab','display-message','-p','-t',pane,'#{socket_path},#{pid},0'],te).stdout.strip()
 def case(name,args,extra={},armed=False,prep=False):
  h=home(name); e=dict(te,FM_HOME=str(h),FM_POLL='1',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999',**extra)
  if prep: assert run(['bin/fm-afk-launch.sh','enter','--words','isolated validation only'],e).returncode==0
  out=open(evidence/(name+'.stdout'),'w'); err=open(evidence/(name+'.stderr'),'w')
  p=sp.Popen(args,env=e,stdout=out,stderr=err); children.append(p)
  log=h/'state/.supervise-daemon.log'; deadline=time.monotonic()+12
  while p.poll() is None and time.monotonic()<deadline:
   if armed and log.exists() and 'daemon starting' in log.read_text(): break
   time.sleep(.1)
  running=p.poll() is None
  if running: p.terminate()
  p.wait(timeout=10); out.close(); err.close()
  text=log.read_text() if log.exists() else ''; (evidence/(name+'.log')).write_text(text)
  r={'scenario':name,'command':args,'env_overrides':extra,'was_running':running,'rc':p.returncode,'stderr':(evidence/(name+'.stderr')).read_text(),'log':text,'state':sorted(x.name for x in (h/'state').iterdir())}; records.append(r); print(json.dumps(r),flush=True); return r,h
 r,h=case('daemon-no-handle',['bin/fm-supervise-daemon.sh'])
 assert r['rc']==1 and 'target_source=UNAVAILABLE' in r['stderr'] and 'target_source=UNAVAILABLE' in r['log'] and 'daemon starting' not in r['log'] and not (h/'state/.supervise-daemon.lock').exists() and not (h/'state/.supervise-daemon.pid').exists()
 r,h=case('launcher-no-handle',['bin/fm-afk-launch.sh','start'],prep=True)
 assert r['rc']==1 and 'target_source=UNAVAILABLE' in r['stderr'] and 'target_source=UNAVAILABLE' in r['log'] and not (h/'state/.afk').exists() and not (h/'state/.afk-daemon-terminal').exists() and (h/'state/.afk-contract').exists()
 r,h=case('launcher-record-guard',['bin/fm-afk-launch.sh','start'])
 assert r['rc']==1 and 'record is required' in r['stderr'] and not r['log']
 r,h=case('explicit-target',['bin/fm-supervise-daemon.sh'],{'FM_SUPERVISOR_TARGET':pane,'FM_SUPERVISOR_BACKEND':'tmux','TMUX':tmux_value,'TMUX_PANE':'%999999'},True)
 assert 'target='+pane+'; target_source=FM_SUPERVISOR_TARGET;' in r['log'] and 'daemon starting' in r['log']
 r,h=case('inherited-tmux',['bin/fm-supervise-daemon.sh'],{'TMUX':tmux_value,'TMUX_PANE':pane},True)
 assert 'target='+pane+'; target_source=TMUX_PANE;' in r['log'] and 'daemon starting' in r['log']
 h=home('native-no-handle'); e=dict(te,FM_HOME=str(h)); assert run(['bin/fm-afk-launch.sh','enter'],e).returncode==0
 assert run(['bin/fm-afk-launch.sh','start-native'],e).returncode==0
 p=run(['bin/fm-afk-start.sh'],e); log=(h/'state/.supervise-daemon.log').read_text(); records.append({'scenario':'native-no-handle','afk_flag':(h/'state/.afk').exists(),'log':log,'pidfile':(h/'state/.supervise-daemon.pid').exists(),'lock':(h/'state/.supervise-daemon.lock').exists()}); assert p.returncode==1 and 'target_source=UNAVAILABLE' in p.stderr and (h/'state/.afk').exists()
 # Lab contract readiness, never provision if prepare refuses.
 he=dict(env,FM_HERDR_LAB_STATE_DIR=str(labs/'herdr-records'))
 name=run(['bin/fm-herdr-lab.sh','name','target-refusal'],he).stdout.strip()
 p=run(['bin/fm-herdr-lab.sh','prepare',name],he)
 print('Herdr prepare:',p.returncode,p.stderr,flush=True)
 if p.returncode==0: print('HERDR_READY',name,flush=True)
finally:
 for p in children:
  if p.poll() is None: p.terminate(); p.wait(timeout=10)
 if socket:
  run(['tmux','-L','fm-lab','kill-server'],dict(env,TMUX_TMPDIR=socket)); run(['bin/fm-lab-home.sh','teardown',str(homes[0])])
 (evidence/'transcript.json').write_text(json.dumps(records,indent=2))
 shutil.rmtree(labs)
