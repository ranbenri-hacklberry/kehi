// Like postproc_v3.js but for any items file [[id,msg,...]]: node postproc_dev.js items.json in.jsonl out.jsonl
const fs=require('fs'); const P=require('../agent-pipeline.js');
const D=JSON.parse(fs.readFileSync(process.env.SCEN||'/workspace/community-scenarios/scenarios.json','utf8'));
const [,,items,inp,out]=process.argv; const msg=Object.fromEntries(JSON.parse(fs.readFileSync(items,'utf8')).map(r=>[r[0],r[1]]));
const lines=fs.readFileSync(inp,'utf8').trim().split('\n').map(l=>JSON.parse(l)).map(r=>{
  let c=null; try{c=JSON.parse(r.content)}catch(e){}
  if(c) c=P.postprocessIntent(c,msg[r.id],D.scenarios);
  return {...r, content: c?JSON.stringify(c):r.content};
});
fs.writeFileSync(out, lines.map(l=>JSON.stringify(l)).join('\n')+'\n');
