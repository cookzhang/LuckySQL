#!/usr/bin/env python3
"""TCP delay fixture: schedule each received chunk + RTT/2 in both directions.
No bandwidth shaping/loss. Bounded queues keep delay independent of read chunk
count without unbounded pending payload. Counts TCP payload bytes, not headers.
"""
import argparse, asyncio, json, pathlib, signal, time
p=argparse.ArgumentParser();p.add_argument('--target-port',type=int,required=True);p.add_argument('--rtt-ms',type=float,default=0);p.add_argument('--state',required=True);args=p.parse_args()
state={'rtt_ms':args.rtt_ms,'connections':0,'client_bytes':0,'server_bytes':0}; stop=asyncio.Event()
def save():pathlib.Path(args.state).write_text(json.dumps(state))
async def relay(reader,writer,key):
 q=asyncio.Queue(maxsize=16)
 async def receive():
  try:
   while data:=await reader.read(65536):
    state[key]+=len(data);await q.put((time.monotonic()+args.rtt_ms/2000,data))
  finally:await q.put(None)
 async def send():
  while (item:=await q.get()) is not None:
   at,data=item;await asyncio.sleep(max(0,at-time.monotonic()));writer.write(data);await writer.drain()
  writer.close()
 try:await asyncio.gather(receive(),send())
 except (ConnectionError,asyncio.CancelledError):pass
 finally:writer.close()
async def client(reader,writer):
 state['connections']+=1
 try:
  upstream,out=await asyncio.open_connection('127.0.0.1',args.target_port)
  await asyncio.gather(relay(reader,out,'client_bytes'),relay(upstream,writer,'server_bytes'))
 except ConnectionError:writer.close()
 finally:save()
async def main():
 server=await asyncio.start_server(client,'127.0.0.1',0)
 state['port']=server.sockets[0].getsockname()[1];save()
 loop=asyncio.get_running_loop()
 for sig in [signal.SIGINT,signal.SIGTERM]:loop.add_signal_handler(sig,stop.set)
 async with server:await stop.wait()
 save()
asyncio.run(main())
