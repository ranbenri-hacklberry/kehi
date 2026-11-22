#!/usr/bin/env python3
# Two-stage form step, prompt v3. usage: model out items.json [fewshot 0/1] [prompts file]
import json,sys,time,urllib.request
model,out,items=sys.argv[1],sys.argv[2],json.load(open(sys.argv[3])); fs=len(sys.argv)>4 and sys.argv[4]=='1'
P=json.load(open(sys.argv[5] if len(sys.argv)>5 else 'prompts_v3.json'))
def chat(system,user,fmt,shots=()):
  msgs=[{"role":"system","content":system}]
  for u,a in shots: msgs+= [{"role":"user","content":u},{"role":"assistant","content":a}]
  msgs.append({"role":"user","content":user})
  body={"model":model,"stream":False,"think":False,"format":fmt,"options":{"temperature":0,"num_ctx":4096,"seed":7,"num_predict":384},"messages":msgs}
  r=json.loads(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434/api/chat",data=json.dumps(body).encode(),headers={"content-type":"application/json"}),timeout=300).read())
  return r["message"]["content"], {k:r.get(k) for k in ("eval_count","prompt_eval_count","total_duration")}
f=open(out,"w")
for it in items:
  iid,msg=it[0],it[1]
  t=time.time(); res=None; err=None; ev=[]
  try:
    c1,e1=chat(P["sys1"],msg,P["fmt1"],P["fewshot1"] if fs else ()); ev.append(e1); a=json.loads(c1)
    intent=a["intent"]; res={"intent":None if intent=="none" else intent,"confidence":a.get("confidence",0),"variant":None,"slots":{},"missing_required":[],"sensitive_detected":False}
    if intent in P["stage2"]:
      st=P["stage2"][intent]; c2,e2=chat(st["system"],msg,st["format"]); ev.append(e2); b=json.loads(c2)
      res.update({"variant":b.get("variant"),"slots":b.get("slots") or {},"sensitive_detected":bool(b.get("sensitive_detected"))})
  except Exception as e: err=str(e)[:200]
  f.write(json.dumps({"id":iid,"task":"intent","model":model,"secs":round(time.time()-t,2),"content":json.dumps(res,ensure_ascii=False) if res else None,"err":err,"ev":ev},ensure_ascii=False)+"\n"); f.flush()
print("done",model)
