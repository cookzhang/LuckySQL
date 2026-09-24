#!/usr/bin/env python3
"""Run the actual release AppKit benchmark and sample descendant RSS every 50 ms.
RSS is a sampled high-water mark, not an allocation budget or physical footprint.
Run without other performance tests to avoid contention.
"""
import json, os, pathlib, subprocess, time
root=pathlib.Path(__file__).resolve().parent.parent
out=pathlib.Path(os.environ.get('LUCKYSQL_PERF_OUTPUT',str(root/'Docs/acceptance/native/final')));out.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',LUCKYSQL_NATIVE_BENCHMARK=str(out),LUCKYSQL_BENCHMARK_SAMPLES='30')
peak=0;samples=0
with open(os.environ.get('LUCKYSQL_PERF_LOG','/tmp/luckysql-native-final.log'),'w') as log:
 p=subprocess.Popen(['swift','test','-c','release','--filter',os.environ.get('LUCKYSQL_PERF_FILTER','NativePerformanceTests')],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
 while p.poll() is None:
  lines=subprocess.check_output(['ps','-axo','pid=,ppid=,rss=,comm='],text=True).splitlines()
  entries=[line.strip().split(None,3) for line in lines];children={p.pid}
  for _ in range(5):
   children.update(int(e[0]) for e in entries if len(e)==4 and int(e[1]) in children)
  for e in entries:
   if len(e)==4 and int(e[0]) in children and ('xctest' in e[3] or 'LuckySQLPackageTests' in e[3]):peak=max(peak,int(e[2]));samples+=1
  time.sleep(.05)
(out/'rss.json').write_text(json.dumps({'method':'ps RSS of descendant XCTest process, sampled every approximately 50 ms; excludes compiler', 'peak_rss_kib':peak,'samples':samples,'exit':p.returncode},indent=2))
raise SystemExit(p.returncode)
