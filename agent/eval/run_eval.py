#!/usr/bin/env python3
# Read-only eval runner: calls the LOCAL Ollama on this machine only. No installs, no pulls.
import json,sys,time,urllib.request
model=sys.argv[1]; out=sys.argv[2]; base=sys.argv[3] if len(sys.argv)>3 else "http://127.0.0.1:11434"
jobs=json.load(open(sys.argv[4] if len(sys.argv)>4 else "jobs.json"))
done=set()
try:
  for l in open(out): done.add(json.loads(l)["id"])
except FileNotFoundError: pass
f=open(out,"a")
for j in jobs:
  if j["id"] in done: continue
  body={"model":model,"stream":False,"think":False,"format":j["format"],"options":{"temperature":0,"num_ctx":8192,"seed":7},
        "messages":[{"role":"system","content":j["system"]},{"role":"user","content":j["user"]}]}
  t=time.time(); err=None; content=None; ev=None
  try:
    r=urllib.request.urlopen(urllib.request.Request(base+"/api/chat",data=json.dumps(body).encode(),headers={"content-type":"application/json"}),timeout=300)
    res=json.loads(r.read()); content=res.get("message",{}).get("content"); ev={k:res.get(k) for k in ("eval_count","prompt_eval_count","total_duration")}
  except Exception as e: err=str(e)[:300]
  f.write(json.dumps({"id":j["id"],"task":j["task"],"model":model,"secs":round(time.time()-t,2),"content":content,"err":err,"ev":ev},ensure_ascii=False)+"\n"); f.flush()
print("done",model)
