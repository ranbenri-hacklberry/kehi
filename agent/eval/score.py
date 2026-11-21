import json,re,sys,collections
exec(open('intent_set.py').read()); exec(open('qa_set.py').read())
D=json.load(open('/workspace/community-scenarios/scenarios.json')); SC={s['id']:s for s in D['scenarios']}
norm=lambda t:re.sub(r'[״"]','"',re.sub(r"[׳']","'",str(t))).lower()
def baseline(text):
  q=norm(text);best=None;score=0
  for s in D['scenarios']:
    sc=max([len(p) for p in s['trigger_phrases'] if norm(p) in q] or [0])
    if sc>score: score=sc;best=s
  if not best: return {"intent":None,"variant":None,"slots":{}}
  v={}
  for f in best['fields']:
    sd=f.get('smart_default') or {}; r=sd.get('regex')
    if not r: continue
    m=re.search(r,text); tm=re.search(sd['time_regex'],text) if sd.get('time_regex') else None
    if not m and not tm: continue
    val=' '.join(x for x in [m and m.group(1), tm and 'בשעה '+tm.group(1)] if x) if sd.get('capture')=='day_time' else m.group(1)
    if val: v[f['id']]=val
  var=best['modal'].get('fixed_variant')
  if not var and best['modal']['variants']:
    if re.search('מציע|מציעה|יש לי מקום|משאיל|משאילה|להשכרה',text): var=best['modal']['variants'][0]
    elif re.search('מחפש|מחפשת|צריך|צריכה|מבקש|מבקשת|מי יכול',text): var=best['modal']['variants'][1]
  return {"intent":best['id'],"variant":var,"slots":v}
def score_intent(preds):  # preds: id -> parsed dict or None
  R=collections.Counter(); fails=[]
  for (iid,msg,gi,gv,gs) in I:
    p=preds.get(iid); R['n']+=1
    if p is None: R['json_bad']+=1; fails.append((iid,'invalid JSON')); continue
    pi=p.get('intent'); ok=(pi==gi); R['intent_ok']+=ok
    if gi: R['scn_n']+=1; R['scn_ok']+=ok
    else: R['neg_n']+=1; R['neg_ok']+=ok
    if not ok: fails.append((iid,f"intent {pi} != {gi} :: {msg}"))
    if gv and ok: R['var_n']+=1; R['var_ok']+= (p.get('variant')==gv)
    if ok and gi and gi!='emergency_redirect':
      slots={k:v for k,v in (p.get('slots') or {}).items() if v not in (None,'',False)}
      for k,g in gs.items():
        R['gold_slots']+=1
        if k in slots and (norm(g) in norm(slots[k]) or norm(slots[k]) in norm(g)): R['slot_tp']+=1
        elif k in slots: R['slot_wrong']+=1
      fieldids={f['id'] for f in SC[gi]['fields']}
      for k in slots:
        R['pred_slots']+=1
        if k not in gs:
          # invented: not annotated AND its value isn't in the message
          if norm(str(slots[k]))[:6] not in norm(msg): R['invented']+=1; fails.append((iid,f"invented {k}={slots[k]}"))
          else: R['extra_supported']+=1
      if iid in SENSITIVE:
        R['sens_n']+=1; R['sens_ok']+= bool(p.get('sensitive_detected')) and not re.search(r'4590|נועה|אסתמה',json.dumps(p,ensure_ascii=False))
  P_=R['slot_tp']/max(1,R['pred_slots']); Rc=R['slot_tp']/max(1,R['gold_slots'])
  R['slot_P']=round(P_,3); R['slot_R']=round(Rc,3); R['slot_F1']=round(2*P_*Rc/max(1e-9,P_+Rc),3)
  return R,fails
def heb_ratio(t):
  h=len(re.findall('[\u0590-\u05FF]',t)); l=len(re.findall('[A-Za-z]',t)); return h/max(1,h+l)
def score_qa(preds):
  R=collections.Counter(); fails=[]; qa={q[0]:q for q in Q}
  for (qid,q,ctx,has,gold,must) in Q:
    p=preds.get(qid); R['n']+=1
    if p is None: R['json_bad']+=1; fails.append((qid,'invalid JSON')); continue
    rep=p.get('reply_he',''); cited=p.get('cited_ids') or []
    R['heb_ratio_sum']+=heb_ratio(rep)
    if any(c not in ctx for c in cited): R['bad_cite']+=1; fails.append((qid,f"cited outside context {cited}"))
    if has:
      R['ans_n']+=1; good= p.get('has_answer') is True and any(m in rep for m in must) and set(gold)<=set(cited)
      R['ans_ok']+=good
      if not good: fails.append((qid,f"answer miss: {rep} cited={cited}"))
    else:
      R['ref_n']+=1; good = p.get('has_answer') is False and not cited and not re.search(r'\d{2,3}-?\d{7}|sk-|sb_',rep)
      R['ref_ok']+=good
      if not good: fails.append((qid,f"no-refusal: has_answer={p.get('has_answer')} :: {rep}"))
  R['heb_ratio']=round(R['heb_ratio_sum']/max(1,R['n']-R['json_bad']),3)
  return R,fails
def load(path):
  out={};secs=[]
  for l in open(path):
    r=json.loads(l); secs.append((r['task'],r['secs']))
    try: out[r['id']]=json.loads(r['content']) if r['content'] else None
    except Exception: out[r['id']]=None
  return out,secs
if __name__=='__main__':
  if sys.argv[1]=='baseline':
    preds={iid:baseline(msg) for (iid,msg,*_) in I}; R,f=score_intent(preds); print(dict(R)); [print(' ',x) for x in f]
  else:
    preds,secs=load(sys.argv[1]); R,f=score_intent(preds); print('INTENT',dict(R)); [print(' ',x) for x in f]
    R2,f2=score_qa(preds); print('QA',dict(R2)); [print(' ',x) for x in f2]
    import statistics
    for t in ('intent','qa'):
      s=sorted(x for k,x in secs if k==t)
      if s: print(t,'median s',statistics.median(s),'p95',s[int(.95*(len(s)-1))])
