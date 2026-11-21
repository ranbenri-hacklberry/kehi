#!/usr/bin/env python3
# Two-stage intent: (1) enum-constrained classification, (2) per-scenario extraction schema. Local Ollama only.
import json,sys,time,urllib.request
model,out=sys.argv[1],sys.argv[2]; T=json.load(open('twostage.json'))
def chat(system,user,fmt):
  body={"model":model,"stream":False,"think":False,"format":fmt,"options":{"temperature":0,"num_ctx":4096,"seed":7,"num_predict":384},
        "messages":[{"role":"system","content":system},{"role":"user","content":user}]}
  r=json.loads(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434/api/chat",data=json.dumps(body).encode(),headers={"content-type":"application/json"}),timeout=300).read())
  return r["message"]["content"], {k:r.get(k) for k in ("eval_count","eval_duration","total_duration")}
f=open(out,"w")
for iid,msg in T["items"]:
  t=time.time(); res=None; err=None; ev=[]
  try:
    c1,e1=chat(T["sys1"],msg,T["fmt1"]); ev.append(e1); a=json.loads(c1)
    intent=a["intent"]; res={"intent":None if intent=="none" else intent,"confidence":a.get("confidence",0),"variant":None,"slots":{},"missing_required":[],"sensitive_detected":False}
    if intent in T["stage2"]:
      st=T["stage2"][intent]; c2,e2=chat(st["system"],msg,st["format"]); ev.append(e2); b=json.loads(c2)
      res.update({"variant":b.get("variant"),"slots":b.get("slots") or {},"sensitive_detected":bool(b.get("sensitive_detected"))})
  except Exception as e: err=str(e)[:200]
  f.write(json.dumps({"id":iid,"task":"intent","model":model,"secs":round(time.time()-t,2),"content":json.dumps(res,ensure_ascii=False) if res else None,"err":err,"ev":ev},ensure_ascii=False)+"\n"); f.flush()
print("done",model)
