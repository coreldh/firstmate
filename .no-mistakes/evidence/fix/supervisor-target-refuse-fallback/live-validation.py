import json, os, pathlib, shutil, subprocess, time, traceback

ROOT = pathlib.Path('/Users/admin/.no-mistakes/worktrees/57ee2c16a82d/01M403X5GM3ZBZW2G6DGAMHVVR')
EVID = pathlib.Path('/Users/admin/.no-mistakes/evidence/01M403X5GM3ZBZW2G6DGAMHVVR')
WORK = ROOT / '.validation-supervisor-target-live'
WORK.mkdir()
ENV = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','CLAUDECODE','PI_CODING_AGENT','CURSOR_AGENT','CURSOR_INVOKED_AS','GEMINI_CLI','ATLASSIAN_AGENT_TYPE','ROVODEV_CLI'))}
ENV['TMPDIR'] = str(WORK)
ENV['FM_HERDR_LAB_STATE_DIR'] = str(WORK / 'herdr-records')
RESULTS=[]
ONLY=set(os.environ.get('FM_VALIDATION_ONLY','').split(','))-{''}
SOCKET_ENV=None
PROCS=[]

def call(args, env=None, timeout=30):
    p=subprocess.run([str(x) for x in args], cwd=ROOT, env=env or ENV, text=True, capture_output=True, timeout=timeout)
    return {'command': [str(x) for x in args], 'rc':p.returncode, 'stdout':p.stdout, 'stderr':p.stderr}

def check(b, why):
    if not b: raise AssertionError(why)

def textfile(p):
    return p.read_text() if p.exists() and p.is_file() else ''

def home(name):
    h=WORK/name
    r=call([ROOT/'bin/fm-lab-home.sh','create',h])
    check(r['rc']==0, str(r))
    (h/'config/supervision-host-off').touch()
    return h

def envhome(h, more=None):
    return dict(ENV, FM_HOME=str(h), FM_POLL='1', FM_HEARTBEAT='999999', FM_CHECK_INTERVAL='999999', **(more or {}))

def launch(h, op, *args, more=None):
    return call([ROOT/'bin/fm-afk-launch.sh',op,*args],envhome(h,more))

def state(h):
    s=h/'state'
    return {'files':sorted(p.name for p in s.iterdir()), 'daemon_log':textfile(s/'.supervise-daemon.log'), 'terminal_record':textfile(s/'.afk-daemon-terminal'), 'afk':textfile(s/'.afk'), 'contract':textfile(s/'.afk-contract')}

def record(name, fn):
    if ONLY and name not in ONLY: return
    details={}
    try:
        fn(details)
        result='pass'
    except Exception as e:
        details['failure']=str(e)
        details['traceback']=traceback.format_exc()
        result='fail'
    (EVID/(name+'.json')).write_text(json.dumps(details,indent=2)+'\n')
    RESULTS.append({'name':name,'result':result,'evidence':str(EVID/(name+'.json'))})
    print(name+': '+result,flush=True)

def run_daemon(h, more=None, exe=None, arm=False):
    env=envhome(h,more)
    out=open(h/'daemon.out','w');err=open(h/'daemon.err','w')
    p=subprocess.Popen([str(exe or ROOT/'bin/fm-supervise-daemon.sh')],cwd=ROOT,env=env,stdout=out,stderr=err)
    PROCS.append(p)
    armed=False
    deadline=time.monotonic()+12
    while time.monotonic()<deadline:
        if p.poll() is not None: break
        if 'daemon starting' in textfile(h/'state/.supervise-daemon.log'):
            armed=True;break
        time.sleep(.1)
    before=state(h)
    alive=p.poll() is None
    if alive:
        p.terminate()
    try: rc=p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill();rc=p.wait();raise AssertionError('daemon did not terminate within 10s')
    out.close();err.close()
    return {'command':str(exe or ROOT/'bin/fm-supervise-daemon.sh'), 'env':more or {}, 'rc':rc,'armed':armed, 'running_before_stop':alive, 'before_stop':before, 'after_stop':state(h), 'stdout':textfile(h/'daemon.out'),'stderr':textfile(h/'daemon.err')}

def discovery(d):
    cases=[({},1,''),({'HERDR_ENV':'1'},1,''),({'HERDR_PANE_ID':'w1:p9'},1,''),({'HERDR_ENV':'0','HERDR_PANE_ID':'w1:p9'},1,'')]
    d['cases']=[]
    for i,(vals,rc,out) in enumerate(cases):
        r=call(['bash','-c','. bin/fm-supervisor-target-lib.sh; discover_supervisor_target'],dict(ENV,**vals))
        h=home('partial-identity-'+str(i))
        daemon=run_daemon(h,dict(vals,TMUX=SOCKET_ENV['TMUX']))
        d['cases'].append({'env':vals,'library_interface':r,'real_daemon':daemon})
        check(r['rc']==rc and r['stdout']==out,'missing or partial identity returned a target')
        check(daemon['rc']==1 and not daemon['armed'] and 'target_source=UNAVAILABLE' in daemon['stderr'],'partial handle armed the running daemon')

def baseline(d):
    baseline_root=WORK/'baseline'
    baseline_bin=baseline_root/'bin'
    baseline_bin.mkdir(parents=True)
    replacements=('fm-supervise-daemon.sh','fm-supervisor-target-lib.sh')
    for p in (ROOT/'bin').iterdir():
        if p.name not in replacements:
            (baseline_bin/p.name).symlink_to(p,target_is_directory=p.is_dir())
    for name in replacements:
        r=call(['git','show','e31bc6e620ca532c2e0e0b72f3fd7c0869a12270:bin/'+name])
        check(r['rc']==0,'base object unavailable')
        p=baseline_bin/name
        p.write_text(r['stdout']);p.chmod(0o755)
    h=home('baseline-no-handle')
    d['base_commit']='e31bc6e620ca532c2e0e0b72f3fd7c0869a12270'
    d['baseline']=run_daemon(h,{'TMUX':SOCKET_ENV['TMUX']},baseline_bin/'fm-supervise-daemon.sh')
    check(d['baseline']['armed'],'baseline failed to reproduce reported unsafe startup')
    check('target=firstmate:0; target_source=FALLBACK(firstmate:0)' in d['baseline']['before_stop']['daemon_log'],'baseline chose an unexpected target')
    h=home('candidate-no-handle-comparison')
    d['candidate_commit']=call(['git','rev-parse','HEAD'])['stdout'].strip()
    d['candidate']=run_daemon(h,{'TMUX':SOCKET_ENV['TMUX']})
    check(d['candidate']['rc']==1 and not d['candidate']['armed'],'candidate did not discriminate from baseline')

def nohandle(d):
    h=home('no-handle')
    d['fallback_exists']=call(['tmux','-L','fm-lab','display-message','-p','-t','firstmate:0','#{pane_id}'],SOCKET_ENV)
    check(d['fallback_exists']['rc']==0,'adversarial firstmate:0 pane absent')
    d['enter']=launch(h,'enter','--words','Observe only the disposable validation home.')
    check(d['enter']['rc']==0,str(d['enter']))
    d['start_native']=launch(h,'start-native')
    check(d['start_native']['rc']==0,str(d['start_native']))
    check((h/'state/.afk').exists(),'known native flag path did not prepare the flag')
    d['attempts']=[]
    for _ in range(2):
        r=run_daemon(h,{'TMUX':SOCKET_ENV['TMUX']})
        d['attempts'].append(r)
        check(r['rc']==1 and not r['armed'],'daemon did not refuse with exact rc=1')
        check('target_source=UNAVAILABLE' in r['stderr'] and 'firstmate:0' not in r['stderr'],'refusal stderr is wrong')
        check('target_source=UNAVAILABLE' in r['after_stop']['daemon_log'] and 'daemon starting' not in r['after_stop']['daemon_log'],'refusal durable log is wrong')
        check(not (h/'state/.supervise-daemon.lock').exists() and not (h/'state/.supervise-daemon.pid').exists(),'refused daemon left ownership behind')
    d['final']=state(h)
    check((h/'state/.afk').exists(),'known start-native limitation unexpectedly changed')
    check(d['final']['daemon_log'].count('startup refused')==2,'repeat refusal did not append twice')
    d['stop']=launch(h,'stop',more={'TMUX':SOCKET_ENV['TMUX']})
    check(d['stop']['rc']==0,str(d['stop']))

def refusal(d):
    h=home('launcher-refusal')
    d['enter']=launch(h,'enter','--words','Keep all checks isolated.')
    check(d['enter']['rc']==0,str(d['enter']))
    contract=(h/'state/.afk-contract').read_bytes()
    d['attempts']=[]
    for _ in range(2):
        r=launch(h,'start',more={'TMUX':SOCKET_ENV['TMUX']})
        d['attempts'].append(r)
        check(r['rc']==1 and 'target_source=UNAVAILABLE' in r['stderr'],'launcher did not name same refusal')
    d['final']=state(h)
    check((h/'state/.afk-contract').read_bytes()==contract,'refusal changed standing mandate')
    for f in ('.afk','.afk-daemon-terminal','.supervise-daemon.pid','.supervise-daemon.lock','.afk-launch.lock'):
        check(not (h/'state'/f).exists(),'launcher left '+f)
    check(d['final']['daemon_log'].count('refused_by=fm-afk-launch start')==2,'launcher durable append missing')

def guards(d):
    h=home('launcher-guards')
    d['missing_record']=launch(h,'start')
    check(d['missing_record']['rc']==1 and 'record is required' in d['missing_record']['stderr'],'record guard did not run first')
    (h/'state/.afk-return-catchup').touch()
    d['catchup']=launch(h,'start')
    check(d['catchup']['rc']==1 and 'catch-up is still pending' in d['catchup']['stderr'],'catchup guard did not run first')
    (h/'state/.afk-return-catchup').unlink()
    (h/'config/supervision-host-off').unlink()
    (h/'config/supervision-host').touch()
    d['host']=launch(h,'start')
    check(d['host']['rc']==1 and 'runs the supervision host' in d['host']['stderr'],'host guard did not run first')
    d['state']=state(h)
    check('target_source=UNAVAILABLE' not in str(d),'identity verdict displaced an earlier guard')
    check(not (h/'state/.supervise-daemon.log').exists(),'earlier guards unexpectedly logged target refusal')

def identified(d):
    d['cases']=[]
    for name,handles,target,source in [
        ('explicit',{'FM_SUPERVISOR_TARGET':OTHER,'TMUX_PANE':PANE},OTHER,'FM_SUPERVISOR_TARGET'),
        ('explicit-default-backend',{'FM_SUPERVISOR_TARGET':OTHER},OTHER,'FM_SUPERVISOR_TARGET'),
        ('tmux',{'TMUX_PANE':PANE,'HERDR_ENV':'1','HERDR_PANE_ID':'unrelated'},PANE,'TMUX_PANE')]:
        h=home('daemon-'+name)
        r=run_daemon(h,dict(handles,TMUX=SOCKET_ENV['TMUX']))
        d['cases'].append(r)
        check(r['armed'] and r['running_before_stop'],'valid '+name+' handle failed to arm')
        check('target='+target+'; target_source='+source+'; backend=tmux' in r['before_stop']['daemon_log'],'wrong resolved '+name+' identity')
        check(not (h/'state/.supervise-daemon.lock').exists() and not (h/'state/.supervise-daemon.pid').exists(),'daemon shutdown did not clean ownership')

def launcher_tmux(d):
    h=home('launcher-tmux')
    more={'TMUX':SOCKET_ENV['TMUX'],'TMUX_PANE':PANE,'TMUX_TMPDIR':SOCKET_ENV['TMUX_TMPDIR']}
    d['enter']=launch(h,'enter','--words','Observe only this lab.',more=more)
    check(d['enter']['rc']==0,str(d['enter']))
    d['start']=launch(h,'start',more=more)
    d['running_state']=state(h)
    check(d['start']['rc']==0,str(d['start']))
    check('target='+PANE+'; target_source=FM_SUPERVISOR_TARGET' in d['running_state']['daemon_log'],'launcher targeted its own detached daemon pane')
    d['sessions']=call(['tmux','-L','fm-lab','list-sessions','-F','#{session_name}'],SOCKET_ENV)
    d['pane_count']=call(['tmux','-L','fm-lab','list-panes','-t','firstmate','-F','#{pane_id}'],SOCKET_ENV)
    check(d['pane_count']['stdout'].strip()==PANE,'launcher split operator pane')
    d['stop']=launch(h,'stop',more=more)
    d['stopped_state']=state(h)
    check(d['stop']['rc']==0,str(d['stop']))
    for f in ('.afk','.afk-daemon-terminal','.supervise-daemon.pid','.supervise-daemon.lock'):
        check(not (h/'state'/f).exists(),'stop leaked '+f)

try:
    socket_home=home('socket-home')
    socket=call([ROOT/'bin/fm-lab-home.sh','tmux-dir',socket_home])
    check(socket['rc']==0,str(socket))
    SOCKET_ENV=dict(ENV,TMUX_TMPDIR=socket['stdout'].strip())
    c=call(['tmux','-L','fm-lab','new-session','-d','-s','firstmate','-x','120','-y','40','-c',ROOT],SOCKET_ENV)
    check(c['rc']==0,str(c))
    call(['tmux','-L','fm-lab','new-session','-d','-s','explicit','-x','120','-y','40','-c',ROOT],SOCKET_ENV)
    PANE=call(['tmux','-L','fm-lab','display-message','-p','-t','firstmate:0','#{pane_id}'],SOCKET_ENV)['stdout'].strip()
    OTHER=call(['tmux','-L','fm-lab','display-message','-p','-t','explicit:0','#{pane_id}'],SOCKET_ENV)['stdout'].strip()
    SOCKET_ENV['TMUX']=call(['tmux','-L','fm-lab','display-message','-p','-t','firstmate:0','#{socket_path}'],SOCKET_ENV)['stdout'].strip()+',0,0'
    record('discovery-missing-partial',discovery)
    record('baseline-regression-comparison',baseline)
    record('daemon-no-handle-native-refusal',nohandle)
    record('launcher-no-handle-refusal',refusal)
    record('launcher-earlier-guards',guards)
    record('daemon-valid-tmux-identities',identified)
    record('launcher-real-tmux-start-stop',launcher_tmux)
    if not ONLY:
        name=call([ROOT/'bin/fm-herdr-lab.sh','name','target-refuse'])['stdout'].strip()
        prep=call([ROOT/'bin/fm-herdr-lab.sh','prepare',name])
        (EVID/'herdr-prepare.json').write_text(json.dumps({'session':name,'prepare':prep},indent=2)+'\n')
        print('Herdr prepare rc='+str(prep['rc'])+' '+prep['stderr'],flush=True)
finally:
    for p in PROCS:
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:p.kill();p.wait()
    cleanup={}
    if SOCKET_ENV:
        cleanup['private_tmux_stop']=call(['tmux','-L','fm-lab','kill-server'],SOCKET_ENV)
        cleanup['socket_cleanup']=call([ROOT/'bin/fm-lab-home.sh','teardown',WORK/'socket-home'])
    shutil.rmtree(WORK)
    cleanup['worktree_fixture_removed']=not WORK.exists()
    (EVID/'cleanup.json').write_text(json.dumps(cleanup,indent=2)+'\n')
    previous=json.loads((EVID/'live-results.json').read_text()) if ONLY and (EVID/'live-results.json').exists() else []
    combined=[r for r in previous if r['name'] not in ONLY]+RESULTS
    (EVID/'live-results.json').write_text(json.dumps(combined,indent=2)+'\n')
