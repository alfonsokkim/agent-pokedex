from pathlib import Path
import tempfile,shutil,subprocess,os,json
source=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='pet-installer-check-') as t:
 root=Path(t)
 for case in ['fresh','replace','reject','copy-failure','interrupted','source']:
  base=root/case; pkg=base/'package'; home=base/'home'; bins=base/'bin'
  for p in [pkg,home,bins]: p.mkdir(parents=True)
  for f in ['install.sh','hooks.js','claude-pet','pet.md']: shutil.copy2(source/f,pkg/f)
  prebuilt=pkg/'Claude Pet.app'; (prebuilt/'Contents/MacOS').mkdir(parents=True)
  (prebuilt/'Contents/MacOS/ClaudePet').write_text('new binary')
  (pkg/'fetch-sprites.sh').write_text('touch "$HOME/fetched"\n')
  (pkg/'build.sh').write_text('echo unexpected build >&2; exit 90\n')
  old=home/'Applications/Claude Pet.app'
  if case in ['replace','copy-failure','interrupted']:
   (old/'Contents').mkdir(parents=True)
   (old/'Contents/obsolete').write_text('old bundle')
  for name,body in {
   'codesign':'exit 0',
   'spctl':'exit '+('1' if case=='reject' else '0'),
   'pkill':'exit 0',
   'open':'exit 0',
   'swiftc':'echo unexpected compiler >&2; exit 91',
  }.items():
   p=bins/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o755)
  if case in ['copy-failure','interrupted']:
   p=bins/'mv'
   p.write_text('''#!/bin/sh
case "$1" in
 */.agent-pokedex.*/Claude\ Pet.app)
   if [ "$INSTALL_CASE" = interrupted ]; then kill -TERM "$PPID"; fi
   exit 1;;
esac
exec /bin/mv "$@"
''');p.chmod(0o755)
  if case=='source':
   shutil.rmtree(prebuilt)
   (pkg/'build.sh').write_text('mkdir -p "$HOME/Applications/Claude Pet.app/Contents/MacOS"; printf %s "new binary" > "$HOME/Applications/Claude Pet.app/Contents/MacOS/ClaudePet"\n')
   (bins/'swiftc').write_text('#!/bin/sh\nexit 0\n')
  (home/'.claude').mkdir()
  (home/'.claude/settings.json').write_text(json.dumps({'customPreference':True,'hooks':{'Stop':[{'hooks':[{'type':'command','command':'/existing-handler'}]}]}}))
  env=dict(os.environ,HOME=str(home),INSTALL_CASE=case,PATH=str(bins)+':/usr/bin:/bin:/usr/sbin:/sbin')
  result=subprocess.run(['/bin/zsh',str(pkg/'install.sh')],env=env,capture_output=True,text=True)
  if case in ['fresh','replace','source']:
   assert result.returncode==0,(case,result.stdout,result.stderr)
   assert (old/'Contents/MacOS/ClaudePet').read_text()=='new binary'
   assert not (old/'Contents/obsolete').exists()
   settings=json.loads((home/'.claude/settings.json').read_text())
   assert 'UserPromptSubmit' in settings['hooks']
   assert settings['customPreference'] is True
   assert settings['hooks']['Stop'][0]['hooks'][0]['command']=='/existing-handler'
  elif case=='reject':
   assert result.returncode!=0
   assert not (home/'fetched').exists()
   assert not old.exists()
  else:
   assert result.returncode!=0
   assert (old/'Contents/obsolete').read_text()=='old bundle'
  assert not list((home/'Applications').glob('.agent-pokedex.*')) if (home/'Applications').exists() else True
  print(case+': passed')
 # Test the actual JavaScript catalog parser without invoking downloads.
 script=(source/'fetch-sprites.sh').read_text().split("/usr/bin/osascript -l JavaScript -e '\n",1)[1].split("\n' \"$catalog\"",1)[0]
 for case,data,ok in [('valid',{'results':[{'name':'pokemon-'+str(i)} for i in range(649)]},True),('short',{'results':[]},False),('invalid-name',{'results':[{'name':'bad/name'}]*649},False)]:
  p=root/(case+'.json');p.write_text(json.dumps(data))
  result=subprocess.run(['/usr/bin/osascript','-l','JavaScript','-e',script,str(p)],capture_output=True,text=True)
  assert (result.returncode==0)==ok,(case,result.stderr)
  if ok: assert len(result.stdout.strip().splitlines())==649
  print('catalog '+case+': passed')
