import pathlib, os, subprocess as sp, json, time, shutil
root=pathlib.Path.cwd(); d=root/'.validation-regression'; d.mkdir(); b=d/'bin'; b.mkdir(); ev=pathlib.Path('/Users/admin/.no-mistakes/evidence/01M3Z3B8GPATG6DATDSPKBZ9QC'); records=[]; sock=None; p=None
e={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH'])}
def run(a,env=e):
 r=sp.run(a,env=env,text=True,capture_output=True,timeout=30); records.append({'command':a,'rc':r.returncode,'stdout':r.stdout,'stderr':r.stderr}); return r
try:
 for item in (root/'bin').iterdir():
  if item.name in ['fm-supervise-daemon.sh','fm-supervisor-target-lib.sh']:
   (b/item.name).write_text(run(['git','show','87fa81b8b7f6912f84658d52d816bb9bcc2c5da6:bin/'+item.name]).stdout); (b/item.name).chmod(0o755)
  else:(b/item.name).symlink_to(item)
 # Discard extraction text from public evidence; it is input, not product output.
 records=[]
 h=d/'home'; assert run(['bin/fm-lab-home.sh','create',str(h)]).returncode==0
 sock=run(['bin/fm-lab-home.sh','tmux-dir',str(h)]).stdout.strip(); te=dict(e,TMUX_TMPDIR=sock,FM_HOME=str(h),FM_POLL='1',FM_HEARTBEAT='999999')
 assert run(['tmux','-L','fm-lab','new-session','-d','-s','firstmate','sleep 600'],te).returncode==0
 tmux=run(['tmux','-L','fm-lab','display-message','-p','-t','firstmate:0','#{socket_path},#{pid},0'],te).stdout.strip(); te['TMUX']=tmux
 out=open(ev/'baseline.stderr','w'); p=sp.Popen([str(b/'fm-supervise-daemon.sh')],env=te,stdout=sp.DEVNULL,stderr=out)
 log=h/'state/.supervise-daemon.log'; deadline=time.monotonic()+10
 while time.monotonic()<deadline and p.poll() is None:
  if log.exists() and 'daemon starting' in log.read_text():break
  time.sleep(.1)
 text=log.read_text() if log.exists() else ''; (ev/'baseline.log').write_text(text)
 assert 'target=firstmate:0; target_source=FALLBACK(firstmate:0)' in text and 'daemon starting' in text
 p.terminate(); p.wait(timeout=10); out.close()
 records.append({'scenario':'baseline-no-handle','log':text,'stderr':(ev/'baseline.stderr').read_text(),'result':'baseline reproduced unwanted arm'})
 # Execute discovery, asserting its intentional return/output contracts; these are supplemental functional checks, not real Herdr lifecycle.
 cases=[('none',{},1,''),('partial-herdr',{'HERDR_ENV':'1'},1,''),('herdr-identity',{'HERDR_ENV':'1','HERDR_PANE_ID':'w1:p9','HERDR_SESSION':'fm-lab-discovery'},0,'fm-lab-discovery:w1:p9'),('tmux-wins',{'TMUX_PANE':'%42','HERDR_ENV':'1','HERDR_PANE_ID':'w1:p9'},0,'%42'),('explicit-wins',{'FM_SUPERVISOR_TARGET':'chosen:0','TMUX_PANE':'%42','HERDR_ENV':'1','HERDR_PANE_ID':'w1:p9'},0,'chosen:0')]
 for name,extra,rc,expected in cases:
  r=run(['bash','-c','. bin/fm-supervisor-target-lib.sh; discover_supervisor_target'],dict(e,**extra)); assert r.returncode==rc and r.stdout==expected; records[-1]['case']=name
 print(json.dumps(records,indent=2))
finally:
 if p and p.poll() is None:p.terminate(); p.wait(timeout=10)
 if sock:
  run(['tmux','-L','fm-lab','kill-server'],dict(e,TMUX_TMPDIR=sock)); run(['bin/fm-lab-home.sh','teardown',str(d/'home')])
 (ev/'regression.json').write_text(json.dumps(records,indent=2)); shutil.rmtree(d)
