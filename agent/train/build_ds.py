#!/usr/bin/env python3
# labeled.jsonl + qa_distill.jsonl -> data/{train,valid}.jsonl (mlx-lm chat format) + dev_items.json (held-out generated set)
import json,random,collections,os
P=json.load(open('prompts_v3.json')); PL=json.load(open('prompts_lora.json')); R=random.Random(42)
rows=[json.loads(l) for l in open('labeled.jsonl')]; ok=[r for r in rows if r['status']=='ok']
by=collections.defaultdict(list)
for r in ok: by[r['label']].append(r)
DEVM={d[1] for d in json.load(open('dev_items.json'))}  # fixed held-out dev set (created before training)
train=[r for r in ok if r['msg'] not in DEVM]; dev=[r for r in ok if r['msg'] in DEVM]
def ex(sys_,user,ans): return {"messages":[{"role":"system","content":sys_},{"role":"user","content":user},{"role":"assistant","content":ans}]}
T=[]
for r in train:
  T.append(ex(PL['sys1'],r['msg'],json.dumps({"intent":r['label'],"confidence":0.95},ensure_ascii=False)))
  if r['label'] in P['stage2']:
    o=r['out']; st=P['stage2'][r['label']]; fields=st['format']['properties']['slots']['required']
    T.append(ex(st['system'],r['msg'],json.dumps({"variant":o['variant'],"slots":{f:o['slots'].get(f) for f in fields},"sensitive_detected":o['sensitive_detected']},ensure_ascii=False)))
qa=[json.loads(l) for l in open('qa_distill.jsonl')] if os.path.exists('qa_distill.jsonl') else []
QA=[ex(q['system'],q['user'],q['out']) for q in qa if q['good']]
T+=QA; R.shuffle(T); nv=max(20,len(T)//20)
os.makedirs('data',exist_ok=True)
open('data/valid.jsonl','w').write("\n".join(json.dumps(x,ensure_ascii=False) for x in T[:nv])+"\n")
open('data/train.jsonl','w').write("\n".join(json.dumps(x,ensure_ascii=False) for x in T[nv:])+"\n")
st=collections.Counter(r['status'] for r in rows)
print({"labeled":dict(st),"train_msgs":len(train),"dev_msgs":len(dev),"qa_good":len(QA),"qa_total":len(qa),"train_ex":len(T)-nv,"valid_ex":nv,"rescued":sum(1 for r in ok if r.get('rescued'))})
print(collections.Counter(r['label'] for r in ok))
