#!/usr/bin/env python3
"""Compile/run independent facade198 acceptance using an already frozen adapter.
Never builds or modifies the adapter/upstream. --compile-only does not link/run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'Engine/tests/native-cmyk-psd-preserve-tests.c'
HEADER=ROOT/'Sources/CGlimsEngine/include/glims_engine.h'

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def bounded(argv,log,cwd,env,seconds):
    with log.open('xb') as stream:
        child=subprocess.Popen(argv,cwd=cwd,env=env,stdin=subprocess.DEVNULL,
            stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            return child.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGTERM)
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL);child.wait()
            return 124
        except BaseException:
            try: os.killpg(child.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL);child.wait()
            raise

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--producer',type=Path,required=True)
    p.add_argument('--work',type=Path,required=True)
    p.add_argument('--cmyk-profile',type=Path,default=Path('/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc'))
    p.add_argument('--compile-only',action='store_true')
    p.add_argument('--timeout',type=float,default=300)
    args=p.parse_args()
    if not 0<args.timeout<=900: p.error('timeout must be in (0,900] seconds')
    producer=args.producer.resolve();work=args.work.resolve();profile=args.cmyk_profile.resolve()
    if work.exists() and any(work.iterdir()): p.error('work must be new or empty; existing evidence is never overwritten')
    work.mkdir(parents=True,exist_ok=True)
    required=[producer/'compile.rsp']
    if not args.compile_only:
        required += [producer/n for n in ('link.rsp','objects.rsp','libglimsengine.dylib')]
        required += sorted((producer/'obj').glob('*.o'))
        if not (producer/'obj/native-cmyk-import.o').is_file(): p.error('producer has no native-cmyk-import.o')
        if not profile.is_file(): p.error('external profile is missing')
    if not all(x.is_file() for x in required):p.error('producer response/object files are missing')
    inputs={str(x):digest(x) for x in [SOURCE,HEADER]+required}
    env=os.environ.copy()
    for key,leaf in [('HOME','home'),('CFFIXED_USER_HOME','home'),('XDG_CACHE_HOME','cache'),
        ('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','data'),('GIMP3_DIRECTORY','user'),('TMPDIR','tmp')]:
        (work/leaf).mkdir(exist_ok=True);env[key]=str(work/leaf)
    obj=work/'fixture.o';binary=work/'fixture'
    receipt={'scope':'Independent facade198 preserving CMYK PSD acceptance; literal byte producer',
        'compile_only':args.compile_only,'source':str(SOURCE),'producer':str(producer),
        'inputs_before':inputs,'commands':[],'profile':str(profile),
        'profile_sha256':digest(profile) if profile.is_file() else None}
    try:
        command=['xcrun','clang','@'+str(producer/'compile.rsp'),'-std=c11','-O2','-Wall','-Wextra',
          '-Werror=implicit-function-declaration','-I',str(ROOT/'Engine'),'-I',str(ROOT/'Sources/CGlimsEngine/include'),
          '-c',str(SOURCE),'-o',str(obj)]
        receipt['commands'].append(command)
        code=bounded(command,work/'compile.log',ROOT,env,120);receipt['compile_exit']=code
        if code:
            print((work/'compile.log').read_text(errors='replace')[-12000:]);return code
        if args.compile_only:return 0
        command=['xcrun','clang++','-o',str(binary),str(obj)] + [str(x) for x in sorted((producer/'obj').glob('*.o'))] + ['@'+str(producer/'objects.rsp'),'@'+str(producer/'link.rsp')]
        receipt['commands'].append(command)
        code=bounded(command,work/'link.log',ROOT,env,120);receipt['link_exit']=code
        if code:
            print((work/'link.log').read_text(errors='replace')[-12000:]);return code
        command=[str(binary),str(work),str(profile)];receipt['commands'].append(command)
        begin=time.monotonic();code=bounded(command,work/'run.log',work,env,args.timeout)
        receipt['run_exit']=code;receipt['run_seconds']=time.monotonic()-begin
        text=(work/'run.log').read_text(errors='replace')
        print('\n'.join(line for line in text.splitlines() if line.startswith(('FAIL','INFO preview')) or 'checks, ' in line))
        print('Raw log:',work/'run.log')
        return code
    finally:
        receipt['inputs_after']={name:digest(Path(name)) for name in inputs}
        receipt['inputs_unchanged']=receipt['inputs_after']==inputs
        receipt['artifacts']={x.name:digest(x) for x in work.iterdir() if x.is_file()}
        (work/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        if not receipt['inputs_unchanged']:raise RuntimeError('frozen fixture/header/producer inputs changed')

if __name__=='__main__':raise SystemExit(main())
