# kehi.love

**קהי** היא מערכת קוד פתוח שמאפשרת לכל קהילה או כפר בישראל לבנות לעצמה מדריך מקומי ואפליקציית קהילה.

Kehi is an open-source system for any community or village in Israel to build its own local guide and community app.

- דף הבית: [https://kehi.ranbenri.workers.dev](https://kehi.ranbenri.workers.dev) (זמני, עד לרכישת kehi.love)
- [מדיניות פרטיות](https://kehi.ranbenri.workers.dev/privacy) · [תנאי שימוש](https://kehi.ranbenri.workers.dev/terms)
- דוגמאות חיות: [נחת · מצפה רמון](https://nahat-app.ranbenri.workers.dev) · [כלילי · כליל](https://klili-app.klili.workers.dev)
- רישיון: MIT, © 2026 Ran Ben Ari

---

## עברית

### מה יש במערכת

- מדריך מקומות ואירועים, עם אישור ופרסום אצל הצוות
- פרסומי תושבים: טרמפים, נתינות, בקשות עזרה והמלצות
- מושבים לקורסים וסדנאות, הרשמה, ויומן Google או קובץ `.ics`
- כניסה עם Google (שם ותמונה מהחשבון)
- בקשת אימות תושב/ת, ואישור של מנהל/ת קהילה או אדמין
- תפקיד מנהל/ת קהילה (מתחת לאדמין)
- תשתית: Supabase + Cloudflare Workers, והגדרה לפי קהילה

### מבנה הריפו

```
app/            תבנית האפליקציה (HTML/JS, בלי נתונים)
admin/          דף הניהול המשותף
landing/        דף הנחיתה של קהי
deploy/build.js בונה סקריפט פרסום מ־community.config.json
migrations/     005–022 לפי הסדר
mcp/            שרת MCP לאדמין (רק wrangler.example.jsonc)
agent/          צינור הסוכן המקומי/קהילתי
relay/          ריליי לשאלות / WhatsApp
docs/           מדריך Google OAuth והערות Cardcom
community.config.example.json
```

`COMMUNITY_CONFIGS` בתוך `app/index.html` הוא אובייקט ההגדרות המשותף (כולל דוגמאות ציבוריות למצפה ולכליל, בלי מפתחות). בנייה מ־`community.config.json` ממלאת את שם הקהילה, הכתובות והמפתחות.

### התקנה

1. **פרויקט Supabase.** צרו פרויקט חדש. צריך כבר סכמה בסיסית של `places`, `events`, `profiles` ו־`audit_log` (עם RLS: הציבור רואה רק רשומות בסטטוס `published`). המיגרציות כאן (005–013) הן שכבת הניהול, התושבים, הפרסומים והקורסים. אם הקמתם קהילה חדשה לגמרי, התחילו מהסכמה הבסיסית הזו ואז הריצו 005→013 לפי הסדר, דרך Supabase (Dashboard או `apply_migration`). ב־009/010 ברירת המחדל ל־`community_id` היא `your-community` — החליפו למזהה שלכם.

2. **הגדרות.** העתיקו את הקובץ לדוגמה ומלאו אותו. **אל תעלו אותו לגיט.**

   ```bash
   cp community.config.example.json community.config.json
   ```

   מלאו: `community_id`, `brand`, `place_name`, כתובת האפליקציה, `supabase_url`, מפתח **publishable** (לא service role), מזהה חשבון Cloudflare ושם ה־Worker. המפתחות לא שייכים לריפו.

3. **Google OAuth.** לפי [`docs/GOOGLE_OAUTH_SETUP.md`](docs/GOOGLE_OAUTH_SETUP.md): מסך הסכמה, לקוח Web, כתובת ה־callback של הפרויקט (`https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback`), ו־Site URL / Redirect URLs של האפליקציה. את הסוד מדביקים ב־Supabase, לא כאן.

4. **אדמין ומנהל/ת קהילה.** אחרי המיגרציות, הוסיפו את המייל של האדמין לטבלת `private.admins` (רק דרך SQL בשרת). מנהל/ת קהילה מתווסף/ת מתוך דף הניהול (`/admin`), על ידי אדמין, ממשתמש/ת שכבר נכנס/ה ויש לו/לה פרופיל. אל תשמרו רשימות מיילים בגיט.

5. **בנייה ופרסום.**

   ```bash
   node deploy/build.js
   ```

   נוצר `deploy/deploy-<worker_name>.js` (מופיע ב־`.gitignore`). הסקריפט כולל השוואת `accountId` לחשבון שהוגדר אצלכם. פרסמו אותו בסביבת Cloudflare שלכם (API או הכלי שאתם עובדים איתו). דף הנחיתה של קהי עצמה נבנה מ־`landing/build.js` עם `CLOUDFLARE_ACCOUNT_ID`.

6. **קהילה נוספת.** העתיקו את התבנית, צרו פרויקט Supabase נפרד (או אותה סכמה עם `community_id` אחר, אם זה מתאים לכם), מלאו `community.config.json` חדש, ושנו עיצוב וטקסטים. שמרו על זהות ויזואלית נפרדת לכל קהילה.

### מה אין בריפו במכוון

אין מפתחות (גם לא publishable/anon), אין `supabase.config.json`, אין מזהי פרויקט או חשבון אמיתיים, אין מיילי אדמין, אין רשימות מקומות/אירועים או snapshot, אין גיבויים, ואין צילומי מסך של נתונים חיים. קבצי העיצוב של כליל לא כלולים.

---

## English

Kehi is a Hebrew-first, RTL community app: a local guide (places and events), resident posts, course slots, Google sign-in with staff-verified residents, a community-manager role, and an admin approval flow. It runs on Supabase and Cloudflare Workers. Each community has its own config, branding, and (usually) its own database.

Kehi is a Hebrew-first, RTL community platform that any village or neighborhood in Israel can deploy as its own local guide and community app. Residents browse published places and events, post rides / giveaways / help requests / recommendations, and book course or workshop slots (Google Calendar or `.ics`). Staff approve listings; a community-manager role sits under a global admin. Sign-in is Google via Supabase, with staff-verified residency.

Live deployments: [Nahat](https://nahat-app.ranbenri.workers.dev) (Mitzpe Ramon) and [Klili](https://klili-app.klili.workers.dev) (Klil). Landing page: [kehi.ranbenri.workers.dev](https://kehi.ranbenri.workers.dev).

### Tech Stack

- **App:** static Hebrew RTL PWA (`app/` — HTML/JS, service worker, manifest)
- **Data & auth:** Supabase (PostgreSQL, RLS, Google OAuth, RPCs). Public reads are limited to `published` / `open` rows
- **Edge:** Cloudflare Workers (per-community app worker, generated by `deploy/build.js`; landing via `landing/build.js`)
- **Admin MCP:** TypeScript Cloudflare Worker (`mcp/`) with OAuth 2.1, Supabase JWT (no service role), audit log
- **Also in-repo:** community agent pipeline (`agent/`), WhatsApp/ask relay (`relay/`), Cardcom billing migrations, admin UI (`admin/`)

### Architecture

Each community usually has its own config, branding, Cloudflare Worker, and Supabase project. `community.config.json` (gitignored) is compiled into a Worker deploy script; secrets never live in git. RLS and staff RPCs enforce who can publish. The admin MCP endpoint (`/mcp`) is OAuth-gated and uses the signed-in admin JWT; a separate read-only `/app/mcp` serves the in-app “ask the community” chat.

### Repo layout

```
app/        PWA template (no live data)
admin/      shared admin page
landing/    kehi.love marketing site
deploy/     build.js → gitignored Worker script
migrations/ 005–022 (apply in order)
mcp/        admin MCP Worker (wrangler.example.jsonc only)
agent/      local/community agent pipeline
relay/      ask/WhatsApp relay
docs/       Google OAuth and Cardcom notes
```

### Setup

1. Create a Supabase project. You need a base `places` / `events` / `profiles` / `audit_log` schema (public reads are RLS-limited to `published`). Then apply `migrations/005` through `013` in order. Change the `your-community` default `community_id` in 009/010.
2. Copy `community.config.example.json` to `community.config.json` and fill it in. Do not commit that file. Use the publishable key only, never the service role.
3. Enable Google in Supabase Auth. Follow `docs/GOOGLE_OAUTH_SETUP.md`. Paste the client secret in the Supabase dashboard, not in this repo.
4. Insert your admin email into `private.admins` via server-side SQL. Grant community managers from `/admin` after they have signed in and have a profile.
5. Run `node deploy/build.js` and deploy the generated, gitignored worker script to your Cloudflare account. The script checks `accountId` against the account in your config.
6. To add another community, use a new config (and usually a new Supabase project), and keep the visual identity distinct.

Live examples: [Nahat](https://nahat-app.ranbenri.workers.dev) (Mitzpe Ramon) and [Klili](https://klili-app.klili.workers.dev) (Klil).
