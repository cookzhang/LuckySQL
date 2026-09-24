#!/usr/bin/env python3
"""Wide-field actual native paint/RSS acceptance via byte-counting TCP fixture."""
import json, os, pathlib, subprocess, tempfile, time
root=pathlib.Path(__file__).resolve().parent.parent
out=root/'Docs/acceptance/wide';out.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='luckysql-wide-') as tmp:
 state=pathlib.Path(tmp)/'transport.json'
 proxy=subprocess.Popen(['python3',str(root/'scripts/latency-proxy.py'),'--target-port',os.environ['LUCKYSQL_TEST_PORT'],'--rtt-ms','0','--state',str(state)])
 try:
  for _ in range(100):
   if state.exists():break
   time.sleep(.05)
  env=os.environ.copy();env.update(LUCKYSQL_TEST_PORT=str(json.loads(state.read_text())['port']),LUCKYSQL_WIDE_BENCHMARK=str(out),LUCKYSQL_PERF_OUTPUT=str(out),LUCKYSQL_PERF_FILTER='WideBrowsePerformanceTests',LUCKYSQL_PERF_LOG='/tmp/luckysql-wide-final.log')
  result=subprocess.run(['python3',str(root/'scripts/test-native-performance.py')],env=env,cwd=root)
 finally:
  proxy.terminate();proxy.wait(timeout=10)
  (out/'transport.json').write_text(state.read_text())
raise SystemExit(result.returncode)
