// Shared landing template. renderLanding(cfg) -> static HTML for /welcome; privacyJs(cfg) -> /js/privacy.js for the app
// (the in-chat 🔒 sheet and the "report a bad answer" confirm dialog). All copy comes from the community's landing-config.js.
// Zero third-party requests: system fonts, inline SVG icons, same-origin images only, no analytics.
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const ICONS = {
  home: '<path d="M3 11.5 12 4l9 7.5"/><path d="M5.5 10v9.5h13V10"/><path d="M10 19.5v-5h4v5"/>',
  lock: '<rect x="5" y="10.5" width="14" height="9.5" rx="2"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/><path d="M12 14.5v2"/>',
  check: '<path d="M4 12.5 9 17.5 20 6.5"/>',
  shield: '<path d="M12 3.5 19 6v5.5c0 4.3-3 7.8-7 9-4-1.2-7-4.7-7-9V6z"/><path d="m9 12 2 2 4-4"/>'
};
const icon = n => '<svg class="ic" viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICONS[n] || '') + '</svg>';
const hasContact = c => !!(c && c.label && (c.whatsapp || c.email));
function contactHref(c) { return c.whatsapp ? 'https://wa.me/' + String(c.whatsapp).replace(/\D/g, '') : 'mailto:' + c.email; }

function renderLanding(cfg) {
  const t = cfg.theme, L = cfg.local || {};
  const team = Array.isArray(L.team) && L.team.length ? '<ul class="team">' + L.team.map(p => '<li><b>' + esc(p.name) + '</b>' + (p.role ? ' · ' + esc(p.role) : '') + '</li>').join('') + '</ul>' : '';
  const contact = hasContact(L.contact) ? '<a class="btn ghost" href="' + esc(contactHref(L.contact)) + '" rel="noopener">' + esc(L.contact.label) + '</a>' : '';
  const faq = cfg.faq.items.map((f, i) => '<div class="qa"><h3><button type="button" class="qa-q" aria-expanded="false" aria-controls="faq-' + i + '" id="faq-b-' + i + '"><span>' + esc(f.q) + '</span><span class="chev" aria-hidden="true"></span></button></h3><div class="qa-a" id="faq-' + i + '" role="region" aria-labelledby="faq-b-' + i + '" hidden><p>' + esc(f.a) + '</p></div></div>').join('');
  return `<!doctype html>
<html lang="he" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(cfg.meta.title)}</title>
<meta name="description" content="${esc(cfg.meta.description)}">
<meta name="theme-color" content="${esc(t.bg)}">
<meta name="referrer" content="strict-origin-when-cross-origin">
<link rel="icon" href="${esc(cfg.logo_icon)}">
<link rel="manifest" href="/manifest.json">
<link rel="stylesheet" href="/fonts/fonts.css">
<style>
:root{--bg:${t.bg};--panel:${t.panel};--ink:${t.ink};--soft:${t.soft};--line:${t.line};--accent:${t.accent};--accent-bg:${t.accent_bg};--on-accent:${t.on_accent};--sand:${t.sand}}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.65 ${t.body_font || 'system-ui,-apple-system,"Segoe UI",Arial,sans-serif'};overflow-x:hidden}
main{max-width:980px;margin:0 auto;padding:0 20px}
a{color:var(--accent)}
:focus-visible{outline:3px solid var(--accent);outline-offset:3px;border-radius:8px}
.top{display:flex;align-items:center;gap:10px;padding:22px 0 0}
.logo{display:flex;align-items:center;gap:10px;font-size:26px;font-weight:600;color:var(--ink);text-decoration:none;letter-spacing:.01em}
.logo img{width:40px;height:40px;border-radius:50%}
h1,h2,h3{line-height:1.25;margin:0;font-family:${t.head_font || 'inherit'}}
.logo{font-family:${t.head_font || 'inherit'}}
.hero{padding:44px 0 36px}
.hero h1{font-size:clamp(32px,8vw,52px);font-weight:500;max-width:16ch}
.hero p{font-size:clamp(17px,4.4vw,20px);color:var(--soft);max-width:38ch;margin:16px 0 26px}
.btn{display:inline-flex;align-items:center;justify-content:center;min-height:52px;padding:12px 24px;border-radius:999px;font:inherit;font-weight:600;text-decoration:none;border:1.5px solid var(--accent);cursor:pointer;text-align:center}
.btn.main{background:var(--accent);color:var(--on-accent)}
.btn.ghost{background:transparent;color:var(--accent)}
.actions{display:flex;flex-direction:column;align-items:flex-start;gap:14px}
.sec-link{font-size:16px;color:var(--soft);text-underline-offset:4px}
section{padding:36px 0}
section h2{font-size:clamp(26px,6vw,36px);font-weight:500}
.lead{color:var(--soft);margin:10px 0 22px;max-width:52ch}
.cards{display:grid;grid-template-columns:1fr;gap:14px}
@media (min-width:720px){.cards{grid-template-columns:1fr 1fr}.actions{flex-direction:row;align-items:center}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:20px;padding:22px}
.card .ic{color:var(--accent);display:block;margin-bottom:10px}
.card h3{font-size:19px;font-weight:600;font-family:inherit;margin-bottom:8px}
.card p{margin:0;color:var(--ink)}
.callout{background:var(--ink);color:var(--bg);border-radius:24px;padding:34px 24px;margin:12px 0}
.callout h2{color:var(--bg)}
.callout p{margin:12px 0 0;max-width:56ch;opacity:.92}
.team{list-style:none;padding:0;margin:0 0 16px}
.faq .qa{border-bottom:1px solid var(--line)}
.qa-q{all:unset;box-sizing:border-box;display:flex;width:100%;justify-content:space-between;align-items:center;gap:12px;padding:18px 2px;font-size:18px;font-weight:600;cursor:pointer;color:var(--ink)}
.qa-q:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
.chev{flex:none;width:12px;height:12px;border-inline-start:2px solid var(--soft);border-bottom:2px solid var(--soft);transform:rotate(-45deg);transition:transform .2s}
.qa-q[aria-expanded="true"] .chev{transform:rotate(135deg)}
.qa-a p{margin:0 0 18px;color:var(--soft);max-width:60ch}
footer{text-align:center;padding:40px 20px calc(48px + env(safe-area-inset-bottom));border-top:1px solid var(--line);margin-top:24px}
footer p{color:var(--soft);font-size:15px;margin:16px 0 0}
</style>
</head>
<body>
<main>
  <header class="top"><a class="logo" href="/?welcome=1" data-enter><img src="${esc(cfg.logo_icon)}" alt="" width="40" height="40">${esc(cfg.logo_text)}</a></header>
  <section class="hero" aria-labelledby="h1">
    <h1 id="h1">${esc(cfg.hero.h1)}</h1>
    <p>${esc(cfg.hero.sub)}</p>
    <div class="actions">
      <a class="btn main" href="/?welcome=1#/ask" data-enter>${esc(cfg.hero.cta)}</a>
      <a class="sec-link" href="#privacy">${esc(cfg.hero.privacy_link)}</a>
    </div>
  </section>
  <section id="privacy" aria-labelledby="privacy-h">
    <h2 id="privacy-h">${esc(cfg.privacy.h2)}</h2>
    <p class="lead">${esc(cfg.privacy.sub)}</p>
    <div class="cards">${cfg.privacy.cards.map(c => '<article class="card">' + icon(c.icon) + '<h3>' + esc(c.title) + '</h3><p>' + esc(c.body) + '</p></article>').join('')}</div>
  </section>
  <section class="callout" aria-labelledby="callout-h">
    <h2 id="callout-h">${esc(cfg.callout.h2)}</h2>
    <p>${esc(cfg.callout.body)}</p>
  </section>
  <section aria-labelledby="local-h">
    <h2 id="local-h">${esc(L.h2)}</h2>
    <p class="lead">${esc(L.body)}</p>
    ${team}${contact}
  </section>
  <section class="faq" aria-labelledby="faq-h">
    <h2 id="faq-h">${esc(cfg.faq.h2)}</h2>
    ${faq}
  </section>
</main>
<footer>
  <a class="btn main" href="/?welcome=1" data-enter>${esc(cfg.footer.cta)}</a>
  <p>${esc(cfg.footer.line)}</p>
</footer>
<script>
(function(){
  var K=${JSON.stringify(cfg.welcome_key)};
  document.querySelectorAll('[data-enter]').forEach(function(a){a.addEventListener('click',function(){try{localStorage.setItem(K,'true')}catch(e){}})});
  document.querySelectorAll('.qa-q').forEach(function(b){b.addEventListener('click',function(){var open=b.getAttribute('aria-expanded')==='true';b.setAttribute('aria-expanded',String(!open));document.getElementById(b.getAttribute('aria-controls')).hidden=open;})});
})();
</script>
</body>
</html>
`;
}

// In-app: 🔒 sheet + report confirm dialog. Exposes window.kehiPrivacySheet() and window.kehiQaReport(...).
function privacyJs(cfg) {
  const C = { key: cfg.welcome_key, sheet: cfg.app_sheet, report: cfg.report, about: cfg.about_link };
  return `// Generated from landing-config.js (shared/landing/render.js). Chat Q&A is stored ONLY after the user confirms a report.
(function(){
var C=${JSON.stringify(C)};
function el(h){var d=document.createElement('div');d.innerHTML=h;return d.firstElementChild;}
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];});}
var css=document.createElement('style');
css.textContent='.kp-back{position:fixed;inset:0;background:rgba(20,14,10,.45);z-index:200;display:flex;align-items:flex-end;justify-content:center}'
 +'.kp-sheet{background:var(--panel,#fff);color:var(--ink,#222);width:100%;max-width:520px;border-radius:22px 22px 0 0;padding:22px 20px calc(22px + env(safe-area-inset-bottom));max-height:85vh;overflow:auto;box-shadow:0 -8px 30px rgba(0,0,0,.18)}'
 +'.kp-sheet h2{font-size:19px;margin:0 0 10px}.kp-sheet p{margin:0 0 14px;line-height:1.6}'
 +'.kp-row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:6px}'
 +'.kp-btn{min-height:46px;padding:10px 20px;border-radius:999px;font:inherit;font-weight:600;cursor:pointer;border:1.5px solid var(--accent,#a84d2b);background:var(--accent,#a84d2b);color:#fff}'
 +'.kp-btn.ghost{background:transparent;color:var(--accent,#a84d2b)}.kp-btn:disabled{opacity:.6;cursor:default}'
 +'.kp-q{background:var(--bg,#f6f1ea);border:1px solid var(--line,#ddd);border-radius:14px;padding:10px 12px;margin:0 0 10px;font-size:14.5px;white-space:pre-wrap;max-height:28vh;overflow:auto}'
 +'.kp-q b{display:block;font-size:12.5px;color:var(--soft,#666);margin-bottom:2px}'
 +'.kp-msg{font-size:14px;color:var(--soft,#666);min-height:1em}'
 +'.kp-trigger{display:block;margin:6px auto 0;background:none;border:0;color:var(--soft,#666);font:inherit;font-size:12.5px;text-decoration:underline;text-underline-offset:3px;cursor:pointer}';
document.head.appendChild(css);
var last=null;
function openModal(node,first){
  last=document.activeElement; document.body.appendChild(node); document.body.style.overflow='hidden';
  function close(){node.remove();document.body.style.overflow='';document.removeEventListener('keydown',key);if(last&&last.focus)last.focus();}
  function key(e){ if(e.key==='Escape'){close();return;} if(e.key==='Tab'){var f=[].slice.call(node.querySelectorAll('button,a[href]')).filter(function(x){return !x.disabled;}); if(!f.length)return; var a=f[0],z=f[f.length-1]; if(e.shiftKey&&document.activeElement===a){e.preventDefault();z.focus();} else if(!e.shiftKey&&document.activeElement===z){e.preventDefault();a.focus();}} }
  document.addEventListener('keydown',key);
  node.addEventListener('click',function(e){ if(e.target===node) close(); });
  setTimeout(function(){ (node.querySelector(first)||node.querySelector('button')).focus(); },30);
  return close;
}
window.kehiPrivacySheet=function(){
  var s=C.sheet, n=el('<div class="kp-back"><div class="kp-sheet" role="dialog" aria-modal="true" aria-labelledby="kp-st"><h2 id="kp-st">'+esc(s.title)+'</h2><p>'+esc(s.body)+'</p><div class="kp-row"><button type="button" class="kp-btn" data-ok>'+esc(s.ok)+'</button><a href="/welcome#privacy">'+esc(s.more)+'</a></div></div></div>');
  var close=openModal(n,'[data-ok]'); n.querySelector('[data-ok]').onclick=close;
};
window.kehiQaReport=function(a,q,ans,ids,source,t0){
  if(!a||!a.isConnected) return;
  var R=C.report, ms=Math.round(performance.now()-(t0||performance.now()));
  var b=document.createElement('button'); b.type='button'; b.className='qa-bad'; b.textContent=R.button;
  b.addEventListener('click',function(){
    var n=el('<div class="kp-back"><div class="kp-sheet" role="dialog" aria-modal="true" aria-labelledby="kp-rt"><h2 id="kp-rt">'+esc(R.title)+'</h2><p>'+esc(R.body)+'</p>'
      +'<div class="kp-q"><b>'+esc(R.q_label)+'</b>'+esc(q)+'</div><div class="kp-q"><b>'+esc(R.a_label)+'</b>'+esc(String(ans||'').replace(/\\s+/g,' ').trim())+'</div>'
      +'<div class="kp-row"><button type="button" class="kp-btn" data-send>'+esc(R.send)+'</button><button type="button" class="kp-btn ghost" data-cancel>'+esc(R.cancel)+'</button></div><p class="kp-msg" role="status" aria-live="polite"></p></div></div>');
    var close=openModal(n,'[data-cancel]'), send=n.querySelector('[data-send]'), msg=n.querySelector('.kp-msg');
    n.querySelector('[data-cancel]').onclick=close;
    send.onclick=function(){
      send.disabled=true; msg.textContent=R.sending;
      fetch('/api/qa-report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({q:String(q).slice(0,500),a:String(ans||'').replace(/\\s+/g,' ').trim().slice(0,2000),ids:(ids||[]).map(String).slice(0,12),source:source,ms:ms})})
        .then(function(r){return r.json().catch(function(){return {};}).then(function(j){return {ok:r.ok,j:j};});})
        .then(function(x){ if(x.ok&&x.j.ok){ close(); b.disabled=true; b.textContent=R.sent; } else { send.disabled=false; msg.textContent=(x.j&&x.j.error==='private_store_offline')?R.offline:R.failed; } })
        .catch(function(){ send.disabled=false; msg.textContent=R.failed; });
    };
  });
  a.appendChild(b);
};
document.addEventListener('DOMContentLoaded',function(){
  var n=document.querySelector('.qa-note'); if(!n) return;
  var t=document.createElement('button'); t.type='button'; t.className='kp-trigger'; t.textContent=C.sheet.trigger; t.setAttribute('aria-haspopup','dialog');
  t.onclick=window.kehiPrivacySheet; n.replaceWith(t);
});
})();
`;
}
module.exports = { renderLanding, privacyJs };
