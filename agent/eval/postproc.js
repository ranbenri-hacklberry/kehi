// Apply the production guards (agent-pipeline.js) to raw model outputs: in.jsonl -> out.jsonl
const fs=require('fs'); const P=require('/workspace/community-scenarios/agent-pipeline.js');
const D=JSON.parse(fs.readFileSync('/workspace/community-scenarios/scenarios.json','utf8'));
const S=JSON.parse(fs.readFileSync('sets.json','utf8'));
const msg=Object.fromEntries(S.I.map(r=>[r[0],r[1]])), ctx=Object.fromEntries(S.Q.map(r=>[r[0],r[2]]));
const [,,inp,out]=process.argv; let i=0;
const lines=fs.readFileSync(inp,'utf8').trim().split('\n').map(l=>JSON.parse(l)).map(r=>{
  let c=null; try{c=JSON.parse(r.content)}catch(e){}
  if(c){ c = r.task==='intent' ? P.postprocessIntent(c,msg[r.id],D.scenarios) : P.postprocessAnswer(c,ctx[r.id]);
    if(r.task==='qa' && c.has_answer===false) c.reply_he = P.cleanReply(c.reply_he); }
  return {...r, content: c?JSON.stringify(c):r.content};
});
fs.writeFileSync(out, lines.map(l=>JSON.stringify(l)).join('\n')+'\n');
