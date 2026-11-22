# Stage-1 dev accuracy directly in MLX (adapter on the QLoRA base), to separate training quality from export/template effects.
import json,re
from mlx_lm import load,generate
P=json.load(open('prompts_lora.json')); items=json.load(open('dev_items.json'))
m,t=load('models/qlora',adapter_path='adapter')
ok=0; bad=[]
for iid,msg,lab,var in items:
  p=t.apply_chat_template([{"role":"system","content":P['sys1']},{"role":"user","content":msg}],add_generation_prompt=True,tokenize=False)
  o=generate(m,t,prompt=p,max_tokens=30,verbose=False)
  mm=re.search(r'"intent":\s*"([a-z_]+)"',o); pi=mm.group(1) if mm else 'PARSE'
  ok+=pi==lab
  if pi!=lab: bad.append((lab,pi))
print('mlx stage1 dev acc',ok,len(items),round(ok/len(items),3)); print(bad)
print('TEMPLATE_SAMPLE',repr(t.apply_chat_template([{"role":"system","content":"S"},{"role":"user","content":"U"}],add_generation_prompt=True,tokenize=False)))
