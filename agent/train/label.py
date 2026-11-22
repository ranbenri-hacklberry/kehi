#!/usr/bin/env python3
# Clean + verify + label synthetic messages with the local 12B teacher. Drops: PII, near-duplicates (internal and vs the held-out eval/QA),
# label disagreements (teacher classifier != generation label), variant disagreements. Slot values not grounded in the message become null.
import json,re,sys,difflib,random,urllib.request,concurrent.futures as cf
TEACHER=sys.argv[1]; INP=sys.argv[2]; OUT=sys.argv[3]
P=json.load(open('prompts_v3.json')); EV=json.load(open('heldout_texts.json'))
PII=re.compile(r'(\d{2,3}[- ]?\d{3}[- ]?\d{4}|\d{9,10}|@[a-z]|https?://|\bwww\.)',re.I)
def tri(s): s=re.sub(r'\s+',' ',s.strip()); return {s[i:i+3] for i in range(max(1,len(s)-2))}
EVT=[(e,tri(e)) for e in EV]
def near_eval(m):
  t=tri(m)
  for e,te in EVT:
    if len(t&te)/max(1,len(t|te))>0.3: return e
    if difflib.SequenceMatcher(None,m,e).ratio()>0.7: return e
  return None
def chat(system,user,fmt):
  body={"model":TEACHER,"stream":False,"think":False,"format":fmt,"options":{"temperature":0,"num_ctx":4096,"seed":7,"num_predict":384},
        "messages":[{"role":"system","content":system},{"role":"user","content":user}]}
  r=json.loads(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434/api/chat",data=json.dumps(body).encode(),headers={"content-type":"application/json"}),timeout=300).read())
  return json.loads(r["message"]["content"])
FILLER=re.compile(r'^(לא צוין|לא צויין|לא ידוע|לא רלוונטי|לא נאמר|לא הוזכר|ללא|אין|אנא|נא ל|n/a|none|null|-+|\?+)',re.I)
PFX=re.compile(r'^[ובהלמשכ]{1,2}(?=[\u05d0-\u05ea]{2,})')
def grounded(v,msg):
  v=str(v).strip(); msg=re.sub(r'[״"׳\']','',msg)
  if not v or FILLER.match(v): return False
  toks=[t for t in re.split(r'\s+',re.sub(r'[״"׳\'.,!?;:()\[\]]',' ',v)) if len(t)>=2 or re.search(r'\d',t)]
  if not toks: return False
  hit=sum(1 for t in toks if t in msg or PFX.sub('',t) in msg or (len(PFX.sub('',t))>=4 and PFX.sub('',t)[:-1] in msg))
  return hit/len(toks)>=0.6
rows=[json.loads(l) for l in open(INP)]
seen=[];keep=[];stats={"in":len(rows),"pii":0,"dup":0,"near_eval":0}
for r in rows:
  m=re.sub(r'\s+',' ',r['msg']).strip()
  if PII.search(m): stats['pii']+=1; continue
  if re.search(r'[A-Za-z\u0600-\u06FF\u0E00-\u0E7F\u0400-\u04FF\u3040-\u9FFF]',m) or len(re.findall(r'[\u05d0-\u05ea]',m))<8: stats['script']=stats.get('script',0)+1; continue
  t=tri(m)
  if any(len(t&s)/max(1,len(t|s))>0.6 for s in seen): stats['dup']+=1; continue
  if near_eval(m): stats['near_eval']+=1; continue
  seen.append(t); r['msg']=m; keep.append(r)
CONFUSED={'pet_adoption','housing','food_share','meal_train','yard_sale','item_giveaway','lost_item','found_item','lost_pet','found_pet','volunteers','tools','neighbor_help','business_vouch','service_request','community_alert'}
cap=lambda l: 60 if l=='none' else 20 if l=='emergency_redirect' else 40 if l in CONFUSED else 28
import collections,os
random.Random(9).shuffle(keep); cnt=collections.Counter(); sub=[]
for r in keep:
  if cnt[r['label']]<cap(r['label']): cnt[r['label']]+=1; sub.append(r)
done=set()
if os.path.exists(OUT):
  for l in open(OUT): done.add(json.loads(l)['msg'])
keep=[r for r in sub if r['msg'] not in done]
print(stats,'subset',len(sub),'todo',len(keep),flush=True)
def lab(r):
  try:
    a=chat(P['sys1'],r['msg'],P['fmt1'])
    if a['intent']!=r['label']:
      D=json.load(open('desc.json')); L=r['label']; T=a['intent']
      q=(f"הודעה: {r['msg']}\nאפשרות א ({L}): {D[L][0]}\nאפשרות ב ({T}): {D.get(T,[T])[0]}\n"
         "לאיזו אפשרות ההודעה שייכת בבירור? אם לא ברור, unclear.")
      v=chat("את בודקת תיוג של הודעות קהילתיות. עני רק לפי מה שכתוב.",q,{"type":"object","required":["answer"],"properties":{"answer":{"type":"string","enum":["א","ב","unclear"]}}})
      if v.get('answer')!='א': return dict(r,status='label_disagree',teacher=T)
      r=dict(r,rescued=True)
    out={"intent":r['label'],"variant":None,"slots":{},"sensitive_detected":False}
    if r['label'] in P['stage2']:
      st=P['stage2'][r['label']]; b=chat(st['system'],r['msg'],st['format'])
      vs=st['format']['properties']['variant'].get('enum') or [None]
      if r.get('variant') and len([v for v in vs if v])>1 and b.get('variant')!=r['variant']: return dict(r,status='variant_disagree',teacher=b.get('variant'))
      slots={k:(v if v is not None and grounded(v,r['msg']) else None) for k,v in (b.get('slots') or {}).items()}
      out.update(variant=b.get('variant') if len([v for v in vs if v])>1 else (vs[0] if vs[0] else None),slots=slots,sensitive_detected=bool(b.get('sensitive_detected')),
                 ungrounded=[k for k,v in (b.get('slots') or {}).items() if v is not None and slots[k] is None])
    return dict(r,status='ok',out=out)
  except Exception as e: return dict(r,status='err',err=str(e)[:150])
with open(OUT,'a') as f, cf.ThreadPoolExecutor(2) as ex:
  for i,x in enumerate(ex.map(lab,keep)):
    f.write(json.dumps(x,ensure_ascii=False)+"\n"); f.flush()
    if i%50==0: print(i,flush=True)
print('done')
