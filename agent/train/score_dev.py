import json,sys,collections
# dev accuracy: res file (run_twostage_v3 output, post-processed) vs dev_items.json
items={i[0]:i for i in json.load(open(sys.argv[1]))}; R=collections.Counter(); conf=collections.Counter()
for l in open(sys.argv[2]):
  r=json.loads(l); g=items[r['id']]; c=json.loads(r['content']) if r['content'] else None
  R['n']+=1
  if c is None: R['json_bad']+=1; continue
  pi=c.get('intent') or 'none'; ok=pi==g[2]; R['ok']+=ok
  if not ok: conf[(g[2],pi)]+=1
  if g[3] and ok: R['var_n']+=1; R['var_ok']+=c.get('variant')==g[3]
print(dict(R),'acc',round(R['ok']/R['n'],3)); print(conf.most_common(12))
