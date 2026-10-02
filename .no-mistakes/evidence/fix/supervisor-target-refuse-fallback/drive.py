import os, pathlib, subprocess, time, json, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/admin/.no-mistakes/evidence/01M3Z7YFRS4QVQKKSD63H7KXD4')
lab=root/'.l'
assert not lab.exists()
base=os.environ.copy()
for k in list(base):
    if k.startswith('FM_') or k in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION']:
        base.pop(k,None)
base.update(FM_HOME=str(lab), FM_POLL='1', FM_HEARTBEAT='999999', FM_CHECK_INTERVAL='999999', FM_WEDGE_ALARM_EXEC='discard')
rows=[]
procs=[]
def run(cmd, env=None, timeout=15):
    p=subprocess.run(cmd,env=env or base,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    return p

def record(name,p,extra=''):
    text=f'$ {name}\nexit={p.returncode}\nstdout:\n{p.stdout}\nstderr:\n{p.stderr}\n{extra}'
    (evidence/(name+'.log')).write_text(text)
    print(text,flush=True)

def state():
    out=[]
    for p in sorted((lab/'state').iterdir()):
        out.append(p.name+(' [directory]' if p.is_dir() else '\n'+p.read_text(errors='replace')))
    return '\n'.join(out)

def daemon(name,env,expect=None):
    out=open(evidence/(name+'.stdout'),'w'); err=open(evidence/(name+'.stderr'),'w')
    p=subprocess.Popen(['bin/fm-supervise-daemon.sh'],env=env,stdout=out,stderr=err)
    procs.append(p)
    log=lab/'state/.supervise-daemon.log'
    end=time.monotonic()+15
    while time.monotonic()<end and p.poll() is None:
        if log.exists() and 'daemon starting' in log.read_text(): break
        time.sleep(.1)
    started=log.exists() and 'daemon starting' in log.read_text()
    if p.poll() is None:
        p.terminate(); p.wait(timeout=15)
    out.close();err.close()
    transcript=f'exit={p.returncode}\n'+(evidence/(name+'.stderr')).read_text()+'\n'+state()
    (evidence/(name+'.log')).write_text(transcript)
    print(name+'\n'+transcript,flush=True)
    if expect:
        assert started and expect in log.read_text(),name
    else:
        assert p.returncode==1 and not started and 'target_source=UNAVAILABLE' in (evidence/(name+'.stderr')).read_text()
    assert not (lab/'state/.supervise-daemon.pid').exists()
    assert not (lab/'state/.supervise-daemon.lock').exists()
    if log.exists(): log.unlink()

try:
    p=run(['bin/fm-lab-home.sh','create',str(lab)]); assert p.returncode==0,p.stderr
    (lab/'t').mkdir()
    # Existing opt-out config prevents the host from replacing the daemon path.
    (lab/'config/supervision-host-off').touch()
    tmuxenv=base|{'TMUX_TMPDIR':str(lab/'t')}
    def tmux(*args): return run(['tmux','-L','fm-lab',*args],tmuxenv)
    p=tmux('new-session','-d','-s','firstmate','-x','120','-y','40','-c',str(root),'sleep 300'); assert p.returncode==0,p.stderr
    q=tmux('display-message','-p','-t','firstmate:0','#{pane_id}|#{socket_path}')
    pane,socket=q.stdout.strip().split('|')
    connected=base|{'TMUX_TMPDIR':str(lab/'t'),'TMUX':socket+',0,0'}
    record('unrelated-firstmate-pane',q)
    p=run(['bash','-c','. bin/fm-supervisor-target-lib.sh; discover_supervisor_target'],connected)
    record('discovery-no-handle',p)
    assert p.returncode==1 and p.stdout==''
    daemon('daemon-no-handle-existing-firstmate',connected)
    # A real tmux pane is used for all positive validations, without replacing the transport.
    daemon('daemon-explicit-precedence', connected|{'FM_SUPERVISOR_TARGET':pane,'FM_SUPERVISOR_BACKEND':'tmux','TMUX_PANE':'%999999','HERDR_ENV':'1','HERDR_PANE_ID':'missing'},'target='+pane+'; target_source=FM_SUPERVISOR_TARGET; backend=tmux')
    daemon('daemon-tmux-precedence',connected|{'TMUX_PANE':pane,'HERDR_ENV':'1','HERDR_PANE_ID':'missing'},'target='+pane+'; target_source=TMUX_PANE; backend=tmux')
    p=run(['bin/fm-afk-launch.sh','start'],connected)
    record('launcher-missing-record-guard',p,state())
    assert p.returncode!=0 and 'target_source=UNAVAILABLE' not in p.stderr and not (lab/'state/.supervise-daemon.log').exists()
    p=run(['bin/fm-afk-launch.sh','enter','--words','Disposable refusal validation'],connected)
    record('enter',p);assert p.returncode==0
    before=(lab/'state/.afk-contract').read_bytes()
    p=run(['bin/fm-afk-launch.sh','start'],connected)
    record('launcher-no-handle',p,state())
    assert p.returncode==1 and 'target_source=UNAVAILABLE' in p.stderr
    assert 'target_source=UNAVAILABLE' in (lab/'state/.supervise-daemon.log').read_text()
    assert not (lab/'state/.afk').exists() and not (lab/'state/.afk-daemon-terminal').exists()
    assert before==(lab/'state/.afk-contract').read_bytes()
    (lab/'state/.supervise-daemon.log').unlink()
    p=run(['bin/fm-afk-launch.sh','start'],connected|{'TMUX_PANE':pane})
    record('launcher-valid-pane',p,state());assert p.returncode==0
    end=time.monotonic()+15
    log=lab/'state/.supervise-daemon.log'
    while time.monotonic()<end:
        if log.exists() and 'daemon starting' in log.read_text():break
        time.sleep(.1)
    assert log.exists() and 'target='+pane+'; target_source=FM_SUPERVISOR_TARGET' in log.read_text()
    (evidence/'launcher-valid-pane-started.log').write_text(state())
    p=run(['bin/fm-afk-launch.sh','stop'],connected)
    record('launcher-stop',p,state());assert p.returncode==0
    assert not (lab/'state/.supervise-daemon.pid').exists() and not (lab/'state/.supervise-daemon.lock').exists()
    # The documented native preparation limitation is deliberately retained.
    log.unlink()
    p=run(['bin/fm-afk-launch.sh','enter','--words','Disposable native refusal validation'],connected);assert p.returncode==0
    p=run(['bin/fm-afk-launch.sh','start-native'],connected)
    record('native-preparation',p,state());assert p.returncode==0 and (lab/'state/.afk').exists()
    daemon('native-daemon-refusal',connected)
    assert (lab/'state/.afk').exists()
    p=run(['bin/fm-afk-launch.sh','stop'],connected);record('native-stop',p,state());assert p.returncode==0
    print('All driven scenarios passed.',flush=True)
finally:
    for p in procs:
        if p.poll() is None:
            p.terminate();p.wait(timeout=15)
    if lab.exists():
        p=subprocess.run(['tmux','-L','fm-lab','kill-server'],env=base|{'TMUX_TMPDIR':str(lab/'t')},capture_output=True,text=True)
        (evidence/'cleanup.log').write_text('Private tmux kill-server exit='+str(p.returncode)+'\n'+p.stderr)
        shutil.rmtree(lab)
