import os, pathlib, subprocess as sp, time, json, shutil, hashlib
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M7EJT50KNXTM8HRAGFTD6NTB'); D=R/'.gate-test-tmp/live'; D.mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or k=='TMUX': env.pop(k,None)
env.update(LC_ALL='en_US.UTF-8',TMPDIR=str(R/'.gate-test-tmp'))
rows=[]
def run(name,args,expected=0,e=None,input=None,timeout=20):
 t=time.monotonic(); p=sp.run(args,env=e or env,input=input,stdout=sp.PIPE,stderr=sp.PIPE,timeout=timeout); elapsed=time.monotonic()-t
 row=dict(name=name,exit=p.returncode,seconds=round(elapsed,3),stdout=p.stdout.decode('utf-8','backslashreplace'),stderr=p.stderr.decode('utf-8','backslashreplace')); rows.append(row)
 assert p.returncode==expected,row
 return p
H=D/'home'; run('mint disposable home',['bin/fm-lab-home.sh','create',str(H)])
P=D/'primary'; P.mkdir(); run('initialize disposable primary',['git','init','-q',str(P)])
shutil.copy(R/'AGENTS.md',P/'AGENTS.md'); (P/'bin').mkdir()
for f in ['fm-cd-pretool-check.sh','fm-arm-command-policy.mjs','fm-cd-command-policy.mjs','fm-hook-host-lib.sh']: shutil.copy(R/'bin'/f,P/'bin'/f)
large='Línea áéíóú ñ «comillas» — → '*2048
arm=R/'bin/fm-arm-pretool-check.sh'; cd=P/'bin/fm-cd-pretool-check.sh'
base=D/'base-arm.sh'; base.write_bytes(sp.check_output(['git','show','427056c:bin/fm-arm-pretool-check.sh']))
# Same command, same stock shell and UTF-8 locale, compare the affected fast path.
for label,path in [('base',base),('target',arm)]:
 try: run(label+' large innocuous command',['/bin/bash',str(path),'--command',"echo '"+large+"'"],timeout=15)
 except sp.TimeoutExpired: rows.append(dict(name=label+' large innocuous command',timeout_seconds=15))
for kind,path,deny,allowed in [('arm',arm,'bin/fm-watc\\\nh-arm.sh &','bin/fm-watch-arm.sh'),('cd',cd,'c\\\nd projects/example','(cd projects/example)')]:
 for label,command,want in [('fast UTF8',"echo '"+large+"'",0),('protected UTF8',deny+' # '+large,2),('allowed protected',allowed,0),('ANSI-C marker',"bin/fm-$'\\x77'atch-arm.sh &" if kind=='arm' else "$'\\x63\\x64' projects/example",2),('quoted token','bin/fm-"watch"-arm.sh &' if kind=='arm' else 'c"d" projects/example',2)]:
  run(kind+' '+label,['/bin/bash',str(path),'--command',command]) if want==0 else run(kind+' '+label,['/bin/bash',str(path),'--command',command],2)
 # Real BSD tr receives invalid bytes; innocuous must allow, protected suffix must deny.
 for label,command,want in [('invalid innocuous',b'echo \xc3',0),('invalid protected',b'echo \xc3; '+(b'bin/fm-watch-arm.sh &' if kind=='arm' else b'cd projects/example'),2)]:
  run(kind+' '+label,[b'/bin/bash',os.fsencode(path),b'--command',command],want)
# Inject only a failing external utility; Node and both classifiers remain real.
F=D/'fault-bin'; F.mkdir(); realnode=shutil.which('node'); realtr=shutil.which('tr')
(F/'tr').write_text('#!/bin/bash\nif [ "$1" = -d ]; then head -c 3; exit 1; fi\nexec '+realtr+' "$@"\n'); (F/'tr').chmod(0o755)
(F/'node').write_text('#!/bin/bash\nprintf "%s\\0" "$@" > "$ARGV_LOG"\nexec '+realnode+' "$@"\n'); (F/'node').chmod(0o755)
fe=env|{'PATH':str(F)+':'+env['PATH']}
for kind,path,bad in [('arm',arm,'bin/fm-watch-arm.sh &'),('cd',cd,'cd projects/example')]:
 for label,command,want in [('partial-deny','echo harmless; '+bad,2),('partial-allow','echo harmless',0)]:
  argv=E/(kind+'-'+label+'-argv.bin'); e=fe|{'ARGV_LOG':str(argv)}
  run(kind+' failed tr '+label,['/bin/bash',str(path),'--command',command],want,e)
  args=argv.read_bytes().split(b'\0'); assert args[args.index(b'--command')+1]==command.encode()
  rows[-1]['classifier_received_exact_original']=True
# Real tmux transport in a private socket, no model CLI or real fleet touched.
socket=R/'.gate-test-tmp/s'; tm=['tmux','-S',str(socket)]
try:
 run('start private tmux consumer',tm+['new-session','-d','-s','fm-lab-7173','-n','fm-t1','-x','120','-y','30','cat'])
 se=env|{'FM_HOME':str(H),'FM_BACKEND':'tmux','TMUX':str(socket)+',0,0','FM_SEND_SETTLE':'0'}
 (H/'state/t1.meta').write_text('window=fm-lab-7173:fm-t1\nkind=ship\nharness=claude\nbackend=tmux\n')
 msg=large+'\núltima línea\n'
 run('send large UTF8 to real tmux',['/bin/bash','bin/fm-send.sh','t1',msg],e=se)
 rec=H/'state/t1.inbox/001.msg'
 p=run('read durable steer body',['/bin/bash','-c','. "$1"; fm_task_inbox_body "$2"','_',str(R/'bin/fm-task-inbox-lib.sh'),str(rec)],e=se)
 assert p.stdout==msg.encode(); rows[-1]['sha256']=hashlib.sha256(p.stdout).hexdigest(); rows[-1]['body_bytes']=len(p.stdout); rows[-1]['stdout']='[large body omitted; exact byte comparison succeeded]'
 shutil.copy(rec,E/'large-steer.msg')
 before=sorted(str(p.relative_to(H)) for p in H.rglob('*'))
 for msg in ['', ' \t\n', '\u2003']:
  p=run('reject whitespace '+repr(msg),['/bin/bash','bin/fm-send.sh','t1',msg],1,se)
 assert before==sorted(str(p.relative_to(H)) for p in H.rglob('*'))
 run('capture real tmux doorbell',tm+['capture-pane','-p','-t','fm-lab-7173:fm-t1'])
finally:
 p=sp.run(tm+['kill-server'],stdout=sp.PIPE,stderr=sp.PIPE); rows.append(dict(name='stop private tmux server',exit=p.returncode)); assert p.returncode==0
 (E/'live-results.json').write_text(json.dumps(dict(sha=sp.check_output(['git','rev-parse','HEAD']).decode().strip(),shell=sp.check_output(['/bin/bash','--version']).decode().splitlines()[0],locale=env['LC_ALL'],results=rows),ensure_ascii=False,indent=2))
 shutil.rmtree(D)
print('Live product scenarios complete; results:', E/'live-results.json')
