#!/usr/bin/env python3
"""Run release pagination acceptance through 0/50/150 ms TCP delay fixtures.
Requires LUCKYSQL_TEST_PORT/PASSWORD (and optional USER), a disposable `luckysql`
database, and full Xcode. The Swift test creates/drops only its UUID-named table.
"""
import json, os, pathlib, subprocess, tempfile, time
root=pathlib.Path(__file__).resolve().parent.parent
out=root/'Docs/acceptance/pagination';out.mkdir(parents=True,exist_ok=True)
base=os.environ.copy();base['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
port=base['LUCKYSQL_TEST_PORT'];base['LUCKYSQL_SETUP_PORT']=port
for rtt in [0,50,150]:
 with tempfile.TemporaryDirectory(prefix='luckysql-rtt-') as temporary:
  state=pathlib.Path(temporary)/'state.json'
  proxy=subprocess.Popen(['python3',str(root/'scripts/latency-proxy.py'),'--target-port',port,'--rtt-ms',str(rtt),'--state',str(state)])
  try:
   for _ in range(100):
    if state.exists():break
    time.sleep(.05)
   env=base.copy();env.update(LUCKYSQL_TEST_PORT=str(json.loads(state.read_text())['port']),LUCKYSQL_RTT_MS=str(rtt),LUCKYSQL_BROWSE_BENCHMARK=str(out/('rtt-'+str(rtt)+'.json')))
   with open('/tmp/luckysql-pagination-'+str(rtt)+'.log','w') as log:
    result=subprocess.run(['swift','test','-c','release','--filter','PaginationPerformanceTests|PrefetchPerformanceTests'],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
   print('RTT',rtt,'exit',result.returncode,flush=True)
   if result.returncode:raise RuntimeError('Pagination acceptance failed')
  finally:
   proxy.terminate();proxy.wait(timeout=10)
   if state.exists():(out/('rtt-'+str(rtt)+'-transport.json')).write_text(state.read_text())
