/* Kehi agent pipeline: deterministic guards around the local model (and the keyword engine).
   Pure functions, no network, no storage. Used by the app chat and by the eval scorer. */
(function (root) {
  const DAY = { 'א': 'ראשון', 'ב': 'שני', 'ג': 'שלישי', 'ד': 'רביעי', 'ה': 'חמישי', 'ו': 'שישי', 'ש': 'שבת' };
  // "א-ה", "א׳–ה׳", "ו'", "יום ו:" -> full day names. Only stand-alone day letters (with optional geresh) are touched.
  function expandDays(text) {
    if (text == null) return text;
    const L = "([אבגדהוש])['׳]?";
    const B = "(^|[\\s,;:(·/|])";
    const A = "(?=$|[\\s,;:)·/|\\d])";
    let t = String(text);
    t = t.replace(new RegExp(B + L + "\\s*[-–—]\\s*" + L + A, 'g'), (m, b, x, y) => b + DAY[x] + ' עד ' + DAY[y]);
    t = t.replace(new RegExp(B + L + "\\s*[-–—]\\s*שבת", 'g'), (m, b, x) => b + DAY[x] + ' עד שבת');
    t = t.replace(new RegExp(B + L + A, 'g'), (m, b, x) => b + DAY[x]);
    t = t.replace(/(^|[\s,;(])שבת['׳]/g, '$1שבת');
    return t;
  }
  function expandRecordDays(rec) {
    if (!rec || typeof rec !== 'object') return rec;
    const o = Object.assign({}, rec);
    for (const k of ['hours', 'when_text', 'note', 'opening_hours']) if (typeof o[k] === 'string') o[k] = expandDays(o[k]);
    return o;
  }

  // ---- sensitive details: health, children's names, IDs, entry/parcel codes ----
  const HEALTH = /(אסתמה|סכרת|אפילפס|סרטן|כימותרפ|דיכאון|חרדה|הפרע(ה|ת)|אוטיז|ADHD|לקות|נכות|תרופ(ה|ות)|ניתוח|הריון|בהריון|מחל(ה|ת)|אשפוז|פסיכיאטר|HIV)/i;
  const IDS = /(ת["״]ז|תעודת זהות|מספר זהות|קוד (כניסה|הכניסה|לבניין|חבילה|איסוף)|סיסמ|קוד\s*\d{3,}|\b\d{9}\b)/;
  const CHILD = /(?:ה|ל|ש)?(?:בת|בן|ילד|ילדה|ילדים|תינוק|תינוקת|נכד|נכדה)\s+(?:שלי|שלנו)\s+([\u05d0-\u05ea]{2,})/g;
  const NOT_NAME = new Set(['בת', 'בן', 'שיש', 'שהיא', 'שהוא', 'צריכה', 'צריך', 'אוהבת', 'אוהב', 'לומדת', 'לומד', 'ביום', 'מחר', 'היום']);
  const ALLOW_HEALTH_FIELDS = new Set(['allergens', 'diet']); // food allergens / diet are part of the form, not private health data
  function sensitiveScan(text) {
    const names = [];
    let m; const re = new RegExp(CHILD.source, 'g');
    while ((m = re.exec(String(text || '')))) if (!NOT_NAME.has(m[1])) names.push(m[1]);
    return { health: HEALTH.test(text || ''), ids: IDS.test(text || ''), names };
  }
  function stripSensitive(slots, message, flagged) {
    const scan = sensitiveScan(message);
    const out = {}; const removed = [];
    for (const [k, v] of Object.entries(slots || {})) {
      if (v == null || v === '') { out[k] = v; continue; }
      const s = String(v);
      const bad = (HEALTH.test(s) && !ALLOW_HEALTH_FIELDS.has(k)) || IDS.test(s) || scan.names.some(n => s.includes(n));
      if (bad) { out[k] = null; removed.push(k); } else out[k] = v;
    }
    return { slots: out, removed, sensitive: !!(flagged || scan.health || scan.ids || scan.names.length || removed.length) };
  }


  // ---- grounding: a slot value must come from the message; filler like "לא צוין" becomes null ----
  const FILLER = /^(לא צוין|לא צויין|לא ידוע|לא רלוונטי|לא נאמר|לא הוזכר|ללא פרטים|אין פרטים|אנא|נא ל|יש לציין|n\/a|none|null|unknown|-+|\?+)/i;
  const PFX = /^[ובהלמשכ]{1,2}(?=[\u05d0-\u05ea]{2,})/;
  function grounded(value, message) {
    const v = String(value).trim(); if (!v) return false;
    if (FILLER.test(v)) return false;
    const msg = String(message || '').replace(/[״"׳']/g, '');
    const toks = v.replace(/[״"׳'.,!?;:()\[\]]/g, ' ').split(/\s+/).filter(t => t.length >= 2 || /\d/.test(t));
    if (!toks.length) return false;
    let hit = 0;
    for (const t of toks) { const b = t.replace(PFX, ''); if (msg.includes(t) || msg.includes(b) || (b.length >= 4 && msg.includes(b.slice(0, -1)))) hit++; }
    return hit / toks.length >= 0.6;
  }
  function groundSlots(slots, message) {
    const out = {}; const dropped = [];
    for (const [k, v] of Object.entries(slots || {})) {
      if (v == null || v === '') { out[k] = v; continue; }
      if (grounded(v, message)) out[k] = v; else { out[k] = null; dropped.push(k); }
    }
    return { slots: out, dropped };
  }

  // ---- variant: only the scenario's own list ----
  const OFFER = /^(הצעה|מציע|מציעה|השאלה|מסירה|יש לי)/, ASK = /^(בקשה|מבקש|חיפוש|מחפש|צריך|בקשה להשאלה)/;
  function restrictVariant(scn, v) {
    if (!scn) return null;
    const m = scn.modal || {};
    if (m.fixed_variant) return m.fixed_variant;
    const allowed = m.variants || [];
    if (!allowed.length) return null;
    if (v && allowed.includes(v)) return v;
    if (v && ASK.test(v)) return allowed[1] || null;
    if (v && OFFER.test(v)) return allowed[0];
    return null;
  }


  // Message cues decide offer vs ask when they are unambiguous (small models often get this wrong).
  const ASK_CUE = /(?<![\u05d0-\u05ea])(מחפש|מחפשת|מחפשים|צריך|צריכה|צריכים|מבקש|מבקשת|מבקשים|מי יכול|מי יכולה|יש למישהו|למישהו יש|מישהו נוסע|מישהי נוסעת|דרוש|דרושה|דרושים)(?![\u05d0-\u05ea])/;
  const OFFER_CUE = /(?<![\u05d0-\u05ea])(מציע|מציעה|מציעים|יש לי|יש לנו|מתפנה|מתפנית|להשכרה|פנוי|פנויה|פנויים|אשמח לעזור|אשמח להסיע|משאיל|משאילה|נוסע ל|נוסעת ל|יוצא|יוצאת)(?![\u05d0-\u05ea])/;
  function cueVariant(scn, message) {
    const v = (scn && scn.modal && scn.modal.variants) || [];
    if (v.length !== 2 || (scn.modal && scn.modal.fixed_variant)) return undefined;
    const m = String(message || ''); const a = ASK_CUE.test(m), o = OFFER_CUE.test(m);
    if (a && !o) return v[1]; if (o && !a) return v[0]; return undefined;
  }

  // Deterministic overrides (model-independent): emergencies always go to emergency_redirect; prompt-injection gets no intent.
  const EMERGENCY = /(שריפה|שרפה|האש מתקרבת|דליקה|פצוע|פיגוע|מחבל|חדירה|אמבולנס|לא נושם|מתעלף|התקף לב|דימום|נפל ולא קם|מד"א)/;
  const INJECTION = /(תתעלמ|התעלמ|ignore (all|previous|the)|system prompt|intent\s*=|הוראות הקודמות|תחזיר[יו]? intent)/i;
  function guardIntent(message, o) {
    const m = String(message || '');
    if (EMERGENCY.test(m)) { o.intent = 'emergency_redirect'; o.confidence = 1; o.variant = null; o.slots = {}; o.guard = 'emergency'; return true; }
    if (INJECTION.test(m)) { o.intent = null; o.confidence = 0; o.variant = null; o.slots = {}; o.guard = 'injection'; return true; }
    return false;
  }

  function postprocessIntent(out, message, scenarios) {
    const o = Object.assign({}, out || {});
    if (guardIntent(message, o)) { o.missing_required = []; o.sensitive_detected = false; return o; }
    const scn = (scenarios || []).find(s => s.id === o.intent) || null;
    if (o.intent && o.intent !== 'emergency_redirect' && !scn) { o.intent = null; o.confidence = 0; }
    o.variant = restrictVariant(scn, o.variant);
    const cv = cueVariant(scn, message); if (cv !== undefined && cv !== o.variant) { o.variant = cv; o.variant_by = 'cue'; }
    const fields = scn ? new Set(scn.fields.map(f => f.id)) : new Set();
    const slots = {}; for (const [k, v] of Object.entries(o.slots || {})) if (fields.has(k)) slots[k] = v;
    const gr = groundSlots(slots, message); o.ungrounded = gr.dropped;
    const st = stripSensitive(gr.slots, message, o.sensitive_detected);
    o.slots = st.slots; o.sensitive_detected = st.sensitive; o.stripped = st.removed;
    if (scn) o.missing_required = scn.fields.filter(f => f.required && (o.slots[f.id] == null || o.slots[f.id] === '')).map(f => f.id);
    return o;
  }

  // ---- reply hygiene ----
  const LEAK = /\s*\b(has_answer|cited_ids|reply_he|intent|confidence|missing_required|sensitive_detected|slots)\b\s*[=:]\s*(\[[^\]]*\]|"[^"]*"|[^\s.,]+)[.,]?/g;
  const W0 = '(?<![\u05d0-\u05ea])', W1 = '(?![\u05d0-\u05ea])';
  const w = (x) => new RegExp(W0 + x + W1, 'g');
  const NEUTRAL = [
    [w('את יכולה'), 'אפשר'], [w('אתה יכול'), 'אפשר'], [w('תוכלי'), 'אפשר'], [w('תוכל'), 'אפשר'],
    [w('פני'), 'פנו'], [w('שאלי'), 'שאלו'], [w('נסי'), 'נסו'], [w('בדקי'), 'בדקו'], [w('כתבי'), 'כתבו'],
    [w('לך'), 'לכם'], [w('שלך'), 'שלכם'],
  ];
  function cleanReply(text) {
    let t = String(text || '').replace(LEAK, '').replace(/```[\s\S]*?```/g, '').replace(/\{[^{}]*"[a-z_]+"\s*:[^{}]*\}/g, '');
    for (const [re, to] of NEUTRAL) t = t.replace(re, to);
    return t.replace(/\s{2,}/g, ' ').replace(/\s+([.,!?])/g, '$1').trim();
  }
  const REFUSALS = [
    'אין לי עדיין מידע מאושר על זה. אפשר לשאול את הקהילה בלוח.',
    'על זה עוד אין במאגר שום דבר מאושר. שווה לשאול בלוח הקהילה, אולי מישהו יודע.',
    'לא מצאתי על זה מידע מאושר. כשמישהו יוסיף ויאושר, זה יופיע כאן.',
    'בינתיים אין לי תשובה מאושרת לזה. אפשר לפרסם שאלה בלוח ושכנים יענו.',
  ];
  const TAILS = ['אפשר לשאול את הקהילה בלוח.', 'שווה לשאול בלוח הקהילה, אולי מישהו יודע.', 'כשמשהו יאושר, הוא יופיע כאן.', 'אפשר לפרסם שאלה בלוח ושכנים יענו.'];
  let tIdx = 0;
  // Keep the model's own first sentence (it names the topic) and rotate the closing suggestion.
  function varyRefusal(text) {
    const t = String(text || '').trim();
    const parts = t.split(/(?<=[.!?])\s+/);
    const first = parts[0] && !/בלוח|לשאול/.test(parts[0]) ? parts[0] : 'אין לי עדיין מידע מאושר על זה.';
    return first + ' ' + TAILS[(tIdx++) % TAILS.length];
  }
  let rIdx = 0;
  function refusal(seed) {
    const i = typeof seed === 'number' ? seed : (rIdx++);
    return REFUSALS[Math.abs(i) % REFUSALS.length];
  }
  function postprocessAnswer(out, contextIds) {
    const o = Object.assign({}, out || {});
    const ids = new Set(contextIds || []);
    o.cited_ids = (o.cited_ids || []).filter(x => ids.has(x));
    o.reply_he = cleanReply(o.reply_he);
    if (o.has_answer === true && !o.cited_ids.length) o.has_answer = false;
    if (!o.reply_he) o.reply_he = refusal();
    else if (o.has_answer === false) o.reply_he = varyRefusal(o.reply_he);
    return o;
  }
  const API = { groundSlots, cueVariant, varyRefusal, expandDays, expandRecordDays, sensitiveScan, stripSensitive, restrictVariant, postprocessIntent, cleanReply, refusal, REFUSALS, postprocessAnswer };
  if (typeof module !== 'undefined' && module.exports) module.exports = API; else root.KehiPipeline = API;
})(typeof window !== 'undefined' ? window : globalThis);
