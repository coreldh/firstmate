import pathlib,subprocess as sp,os,time,json,re,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M7EJT50KNXTM8HRAGFTD6NTB'); D=R/'.gate-test-tmp/marked'; H=D/'home'; S=R/'.gate-test-tmp/m'; D.mkdir(parents=True)
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TASKS_AXI_')) and k!='TMUX'}; env['LC_ALL']='en_US.UTF-8'; rows=[]
def run(name,args,want=0):
 t=time.monotonic();p=sp.run(args,env=env,stdout=sp.PIPE,stderr=sp.PIPE,timeout=25); rows.append(dict(name=name,exit=p.returncode,seconds=round(time.monotonic()-t,3),stdout=p.stdout.decode('utf8','backslashreplace'),stderr=p.stderr.decode('utf8','backslashreplace'))); assert p.returncode==want,rows[-1]; return p
run('mint lab',['bin/fm-lab-home.sh','create',str(H)])
tm=['tmux','-S',str(S)]
try:
 run('start private pane',tm+['new-session','-d','-s','fm-lab-marker','-n','fm-domain','-x','120','-y','30','cat'])
 env.update(FM_HOME=str(H),FM_BACKEND='tmux',TMUX=str(S)+',0,0',FM_SEND_SETTLE='0')
 (H/'state/domain.meta').write_text(f'window=fm-lab-marker:fm-domain\nendpoint_task_id=domain\nworktree={H}\nproject={H}\nharness=claude\nkind=secondmate\nmode=secondmate\nhome={H}\nprojects=alpha\nbackend=tmux\n')
 before=set(H.rglob('*'))
 run('marked blank rejected before record or correlation',['/bin/bash','bin/fm-send.sh','fm-domain',' \t\n'],1)
 assert not (H/'state/domain.inbox').exists()
 assert not list((H/'state/pending-replies').glob('*'))
 msg='Línea ñ →\n'*3000
 run('send marked UTF8',['/bin/bash','bin/fm-send.sh','fm-domain',msg])
 rec=H/'state/domain.inbox/001.msg'
 p=run('read marked record',['/bin/bash','-c','. "$1"; fm_task_inbox_body "$2"','_',str(R/'bin/fm-task-inbox-lib.sh'),str(rec)])
 assert p.stdout.endswith(msg.encode())
 prefix=p.stdout[:-len(msg.encode())]; assert re.fullmatch(rb'\[fm-from-firstmate\]\xe2\x81\xa3corr=[0-9a-f]{16} ',prefix),prefix
 corr=re.search(rb'corr=([0-9a-f]{16})',prefix).group(1).decode()
 pending=(H/'state/pending-replies'/corr).read_text(); assert re.search(r'^delivered_epoch=[0-9]+$',pending,re.M)
 rows[-1]['stdout']='[body omitted: exact payload suffix preserved]'; rows[-1]['marker']=prefix.decode(); rows[-1]['payload_bytes']=len(msg.encode()); rows[-1]['pending_reply_delivered']=True
 shutil.copy(rec,E/'marked-steer.msg'); (E/'marked-pending-reply.txt').write_text(pending)
 run('capture marked doorbell',tm+['capture-pane','-p','-t','fm-lab-marker:fm-domain'])
finally:
 p=sp.run(tm+['kill-server'],capture_output=True); rows.append(dict(name='stop private pane',exit=p.returncode)); assert p.returncode==0
 (E/'marked-results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)); shutil.rmtree(D)
print('Marked delivery and blank rejection verified; private tmux server stopped.')
