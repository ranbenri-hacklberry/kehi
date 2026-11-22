#!/usr/bin/env python3
# Merge an mlx-lm LoRA adapter into the ORIGINAL Hugging Face checkpoint (keeps vision/audio towers intact),
# so `ollama create --quantize` can import it as a normal gemma4 safetensors model.
import json,sys,os,shutil,re
import mlx.core as mx
base,adapter,out=sys.argv[1:4]
cfg=json.load(open(os.path.join(adapter,'adapter_config.json'))); lp=cfg.get('lora_parameters',{}); scale=float(lp.get('scale',20.0))
A=mx.load(os.path.join(adapter,'adapters.safetensors'))
os.makedirs(out,exist_ok=True)
for f in os.listdir(base):
  if not f.endswith('.safetensors') and os.path.isfile(os.path.join(base,f)): shutil.copy(os.path.join(base,f),out)
files=[f for f in os.listdir(base) if f.endswith('.safetensors')]
W={}; owner={}
for f in files:
  d=mx.load(os.path.join(base,f)); W[f]=d
  for k in d: owner[k]=f
mods=sorted({k.rsplit('.lora_',1)[0] for k in A})
def find(mod):
  m=re.search(r'layers\.(\d+)\.(.+)$',mod); n,rest=m.group(1),m.group(2)
  c=[k for k in owner if k.endswith(f'layers.{n}.{rest}.weight') and 'language_model' in k and 'vision' not in k and 'audio' not in k]
  if len(c)!=1: raise SystemExit(f'ambiguous/missing for {mod}: {c[:4]}')
  return c[0]
for mod in mods:
  a=A[mod+'.lora_a'].astype(mx.float32); b=A[mod+'.lora_b'].astype(mx.float32)
  k=find(mod); f=owner[k]; w=W[f][k]
  delta=(scale*(a@b)).T
  assert delta.shape==w.shape,(k,delta.shape,w.shape)
  W[f][k]=(w.astype(mx.float32)+delta).astype(w.dtype)
print('merged',len(mods),'modules, scale',scale)
for f,d in W.items(): mx.save_safetensors(os.path.join(out,f),d,metadata={"format":"pt"})
print('saved',out)
