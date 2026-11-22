#!/usr/bin/env python3
# Generate synthetic Hebrew community messages per scenario with the local 12B teacher (Ollama on this machine only).
import json,random,sys,urllib.request,concurrent.futures as cf
TEACHER=sys.argv[1] if len(sys.argv)>1 else "gemma4:12b-it-qat"; OUT=sys.argv[2] if len(sys.argv)>2 else "gen_raw.jsonl"
D=json.load(open('scenarios.json')); SC={s['id']:s for s in D['scenarios']}; DESC=json.load(open('desc.json'))
STYLES=["קצרה מאוד, שורה אחת","ארוכה עם הרבה פרטים","בלי סימני פיסוק, כמו בווטסאפ","עם אימוג'י אחד או שניים","בלשון נקבה","בלשון זכר","בלשון רבים (אנחנו)","חסרים בה רוב הפרטים","עם יום ושעה מדויקים","עם שגיאת כתיב קלה אחת","בשפה יומיומית וסלנג","מנומסת ורשמית","שמתחילה בברכה לקבוצה","בצורת שאלה לקבוצה"]
CONF={"pet_adoption":["housing","lost_pet"],"housing":["pet_adoption"],"food_share":["meal_train","produce"],"meal_train":["food_share"],"yard_sale":["item_giveaway"],"item_giveaway":["yard_sale","neighbor_help"],"lost_item":["found_item"],"found_item":["lost_item"],"lost_pet":["found_pet","pet_adoption"],"found_pet":["lost_pet"],"volunteers":["tools","neighbor_help"],"tools":["volunteers","neighbor_help"],"neighbor_help":["item_giveaway","gig","volunteers"],"business_vouch":["service_request","tools"],"service_request":["business_vouch"],"community_alert":["none","emergency_redirect"],"event":["workshop"],"workshop":["event"],"gig":["neighbor_help"],"produce":["food_share","group_purchase"],"group_purchase":["produce"],"house_sitting":["babysitting"],"babysitting":["house_sitting"],"ride":["school_carpool"],"school_carpool":["ride"],"parcel_favor":["neighbor_help"],"emergency_redirect":["community_alert"],"none":["community_alert","service_request"]}
def chat(prompt,seed):
  body={"model":TEACHER,"stream":False,"think":False,"format":{"type":"object","required":["messages"],"properties":{"messages":{"type":"array","items":{"type":"string"}}}},
        "options":{"temperature":0.95,"top_p":0.95,"seed":seed,"num_ctx":4096,"num_predict":1400},"messages":[{"role":"user","content":prompt}]}
  r=json.loads(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434/api/chat",data=json.dumps(body).encode(),headers={"content-type":"application/json"}),timeout=600).read())
  return json.loads(r["message"]["content"])["messages"]
RULES="""כללים: כל הודעה שונה מהאחרות בניסוח ובפרטים. בלי שמות של אנשים פרטיים, בלי מספרי טלפון, בלי כתובות מדויקות. מקומות כלליים בלבד (כליל, מצפה רמון, הגליל, המרכז הקהילתי, החורשה, הצומת, המכולת וכו'). כתבי רק את ההודעות עצמן, בעברית טבעית של תושבים בקבוצת יישוב."""
def job(sid,variant,style,hard,seed):
  if sid=="none":
    p=f"""כתבי 8 הודעות קצרות שתושבים כותבים לעוזר הדיגיטלי של היישוב, שאינן פרסום של מודעה: שאלות על מקומות ושעות פתיחה, מזג אוויר, ברכות ותודות, שיחה כללית, שאלות על איך משתמשים באפליקציה, וגם 2 ניסיונות להורות לעוזר להתעלם מההוראות שלו. סגנון: {style}.\n{RULES}"""
  elif sid=="emergency_redirect":
    p=f"""כתבי 8 הודעות דחופות של תושבים על סכנה מיידית לחיים שקורה עכשיו (אש פעילה, אדם פצוע או מחוסר הכרה, תאונה עם נפגעים, מישהו לא נושם). סגנון: {style}.\n{RULES}"""
  else:
    s=SC[sid]; f="; ".join(f"{x['label_he']}" for x in s['fields'])
    v=f"\nכל ההודעות מסוג \"{variant}\"." if variant else ""
    h=""
    if hard: h=f"\n4 מתוך ההודעות צריכות להיות מקרים קשים שעלולים להתבלבל עם: {DESC[hard][0]} — אבל הן בבירור שייכות לתרחיש הזה."
    p=f"""כתבי 8 הודעות שונות שתושבים כותבים בקבוצת היישוב, כולן מהתרחיש: {s['name_he']} — {DESC[sid][0]}.{v}
פרטים אפשריים (לא חייבים את כולם, בחלק מההודעות חסרים פרטים): {f}.{h}
סגנון: {style}.\n{RULES}"""
  try: msgs=chat(p,seed)
  except Exception as e: return []
  return [{"label":sid,"variant":variant,"hard":hard,"style":style,"seed":seed,"msg":m.strip()} for m in msgs if isinstance(m,str) and 8<len(m.strip())<400]
jobs=[];rnd=random.Random(11);seed=1000
for sid in list(SC)+["none","emergency_redirect"]:
  vs=(SC[sid]['modal']['variants'] if sid in SC and SC[sid]['modal']['variants'] else [None])
  nb=4 if sid in CONF and sid not in ("none","emergency_redirect") else 3
  if sid=="none": nb=8
  for b in range(nb*(2 if len(vs)==1 else 1) if len(vs)==1 else nb):
    for v in vs:
      seed+=1; hard=rnd.choice(CONF.get(sid,[None])) if b%2==0 and sid in CONF else None
      jobs.append((sid,v,rnd.choice(STYLES),hard,seed))
print("jobs",len(jobs),flush=True)
with open(OUT,"w") as f, cf.ThreadPoolExecutor(int(sys.argv[3]) if len(sys.argv)>3 else 2) as ex:
  for i,res in enumerate(ex.map(lambda j:job(*j),jobs)):
    for r in res: f.write(json.dumps(r,ensure_ascii=False)+"\n")
    f.flush()
    if i%10==0: print(i,flush=True)
print("done")
