# Render admin/admin.html for one community. Reads community.config.json (not in git).
import json, sys, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
cfg = json.loads((ROOT / "community.config.json").read_text())
T = (ROOT / "admin" / "admin.html").read_text()
theme = cfg.get("theme") or {}
theme_css = (
    f"--bg:{theme.get('bg','#fbf6f1')};--panel:{theme.get('panel','#fffaf6')};"
    f"--field:{theme.get('panel','#fffaf6')};--ink:{theme.get('ink','#2b1c22')};"
    f"--soft:{theme.get('soft','#6b4f56')};--line:{theme.get('line','#ead7d1')};"
    f"--accent:{theme.get('accent','#b4454e')};--on-accent:#fff8f0;"
    f"--accent-bg:{theme.get('accent_bg','#f6e4e0')};--focus:#c98f3d;"
    f"--ok:#5f7a2e;--ok-bg:#eaeed2;--no:#a3305f;--no-bg:#f6dfe6;"
    f"--pend:#85601a;--pend-bg:#f7e6c4;"
    f"--head-font:{theme.get('head_font','"Noto Serif Hebrew",Georgia,serif')};--head-weight:600;"
    f"--body-font:{theme.get('body_font','Assistant,Arial,sans-serif')}"
)
payload = json.dumps({
    "url": cfg["supabase_url"],
    "key": cfg["publishable_key"],
    "storageKey": cfg.get("admin_storage_key") or "kehi-admin",
})
out = T
repl = {
    "__TITLE__": cfg.get("title") or cfg["brand"] + " · ניהול",
    "__BRAND__": cfg["brand"],
    "__ICON__": "/icons/mark.svg",
    "__FONTS__": cfg.get("fonts") or "family=Noto+Serif+Hebrew:wght@400;600&family=Assistant:wght@300;400;600",
    "__THEME__": theme_css,
    "__CFG__": payload,
}
for k, v in repl.items():
    out = out.replace(k, v)
for k in repl:
    if k in out:
        raise SystemExit("unreplaced " + k)
dest = ROOT / "admin" / ("out-" + cfg["community_id"] + ".html")
dest.write_text(out)
print("wrote", dest)
