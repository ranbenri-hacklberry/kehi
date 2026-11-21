# Kehi admin MCP server

שרת MCP מרוחק לאדמינים של קהילת Kehi. כל קהילה מקבלת Worker משלה, על חשבון ה-Cloudflare שלה, מול פרויקט ה-Supabase שלה.

- **Endpoint:** `https://<worker>/mcp` (Streamable HTTP).
- **Auth:** OAuth 2.1 (`@cloudflare/workers-oauth-provider`): DCR ב-`/register`, CIMD, PKCE, ו-`/authorize` עם מסך הסכמה.
- **כניסה:** ה-Worker מעביר את המשתמש ל-Supabase Auth (`/auth/v1/authorize?provider=google`, PKCE), ומקבל אותו בחזרה ב-`/callback`.
- **הרשאה:** נכנסים רק משתמשים ש-`admin_whoami().is_admin` שלהם הוא true. הבדיקה חוזרת בכל קריאה לכלי ובכל רענון טוקן.
- **גישה לנתונים:** כל קריאה ל-DB נעשית עם ה-JWT של האדמין המחובר ועם מפתח ה-anon (הציבורי). ב-Worker אין service_role ואין סודות.
  - ה-JWT של Supabase נשמר מוצפן בתוך ה-grant, ומתרענן ב-`tokenExchangeCallback`.
- **יומן פעולות:** כל כלי שמשנה נתונים קורא קודם ל-`public.mcp_log`, שכותב ל-`private.mcp_audit` את מזהה האדמין, שם הכלי, תקציר הארגומנטים והזמן. אפשר לקרוא את היומן עם הכלי `read_audit_log`.
- **מיגרציה:** `migrations/020_mcp_admin.sql`.

## Supabase

ב-Auth → URL Configuration → Redirect URLs צריך להוסיף את `https://<worker>/**`. בלי זה Supabase יחזיר את המשתמש ל-Site URL, וההתחברות לא תושלם.

## Build & deploy

```sh
npm ci
npx wrangler deploy -c <private-config.jsonc> --dry-run --outdir dist --minify
node deploy/make-deploy.mjs <private-config.jsonc> > /tmp/deploy.js   # פונקציה ל-Cloudflare API (יוצרת KV, מעלה, מפעילה workers.dev)
```

הקונפיגורציות האמיתיות לא נכנסות ל-git. התבנית נמצאת ב-`wrangler.example.jsonc`.

## Local check

`npx wrangler dev test/harness.ts -c <config>` מריץ את ה-endpoint עם props מזויפים, כדי לבדוק `tools/list`. הוא לא נפרס.
