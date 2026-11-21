const fs=require('fs'); const P=require('/workspace/community-scenarios/agent-pipeline.js');
const S=JSON.parse(fs.readFileSync('sets.json','utf8')); const pr=JSON.parse(fs.readFileSync('/workspace/community-scenarios/prompts.v2.json','utf8'));
const old=JSON.parse(fs.readFileSync('jobs.json','utf8'));
const intentSys0=old.find(j=>j.task==='intent').system; const intentFmt=old.find(j=>j.task==='intent').format; const qaFmt=old.find(j=>j.task==='qa').format;
const cut=intentSys0.indexOf('\n\nרשימת התרחישים');
const intentSys=intentSys0.slice(0,cut)+pr.intent_rules_extra+intentSys0.slice(cut);
const jobs=[];
for (const [id,msg] of S.I) jobs.push({task:'intent',id,system:intentSys,user:msg,format:intentFmt});
for (const [id,q,ctx] of S.Q) { const cx=ctx.map(c=>P.expandRecordDays(S.P[c])); jobs.push({task:'qa',id,system:pr.qa_system,user:'CONTEXT:\n'+JSON.stringify(cx)+'\n\nשאלה: '+q,format:qaFmt}); }
fs.writeFileSync('jobs_v2.json',JSON.stringify(jobs)); console.log(jobs.length, jobs.find(j=>j.id==='q1').user);
