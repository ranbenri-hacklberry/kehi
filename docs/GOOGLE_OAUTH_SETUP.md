# כניסת תושבות ותושבים עם Google

המסמך הזה מיועד לרן. אפשר להשלים את ההגדרה בלי לשלוח את הסוד (Client Secret) בצ'אט — מדביקים אותו רק בלוח הבקרה של Supabase.

יש שני פרויקטי Supabase נפרדים:

- מצפה / נחת: `YOUR_PROJECT_REF`
- כליל / כלילי: `YOUR_PROJECT_REF`

## 1. מסך הסכמה ב-Google Cloud Console

1. נכנסים ל-[Google Cloud Console](https://console.cloud.google.com/) ובוחרים פרויקט, או יוצרים פרויקט חדש (אפשר פרויקט אחד לשתי הקהילות).
2. עוברים ל-**APIs & Services → OAuth consent screen**.
3. בוחרים User Type: **External** (התושבות והתושבים לא חייבים להיות בארגון Google Workspace).
4. ממלאים:
   - **App name**: למשל «נחת / כלילי» (או שם נפרד אם יוצרים לקוח לכל קהילה).
   - **User support email**: כתובת המייל של רן (חובה).
   - **Developer contact email**: אותה כתובת, או נוספת.
5. בשלב Scopes משאירים את ברירת המחדל: `email`, `profile`, `openid`. לא מוסיפים הרשאות ליומן Google.
6. ב-Test users, כל עוד האפליקציה בסטטוס Testing, מוסיפים את כתובות המייל שיבדקו כניסה. אחרי הבדיקה אפשר לשלוח ל-Production / Verification לפי הצורך.
7. שומרים.

## 2. יצירת לקוח Web OAuth

1. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Application type: **Web application**.
3. Name: למשל «Nahat + Klili Supabase».
4. ב-**Authorized redirect URIs** מוסיפים בדיוק את שני אלה:

   ```
   https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback
   https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback
   ```

   (אלה כתובות הקולבק של Supabase, לא כתובת האפליקציה עצמה.)

5. שומרים. Google מציג **Client ID** ו-**Client Secret**. את הסוד שומרים אצל רן בלבד — לא שולחים אותו בצ'אט ולא שמים אותו בקוד האפליקציה.

### לקוח אחד או שניים?

**מומלץ: לקוח Web אחד** שמכיל את שני ה-Redirect URIs, ואת אותו Client ID + Secret מדביקים בשני פרויקטי Supabase. זה פשוט יותר לתחזוקה, ורן מפעיל את שתי הקהילות.

לחלופין אפשר ליצור לקוח נפרד לכל יישוב (שם אפליקציה «נחת» מול «כלילי» במסך ההסכמה, ו-URI אחד לכל לקוח). זה שווה את העבודה רק אם רוצים מיתוג נפרד לגמרי במסך Google.

## 3. הדבקה ב-Supabase — לכל פרויקט בנפרד

עבור **מצפה** ואז שוב עבור **כליל**:

1. נכנסים ל-[לוח הבקרה של Supabase](https://supabase.com/dashboard) ובוחרים את הפרויקט.
2. **Authentication → Sign In / Providers → Google** (לפעמים מופיע תחת Authentication → Providers).
3. מדליקים את Enable Sign in with Google.
4. מדביקים את **Client ID** ואת **Client Secret** מהלקוח שיצרתם ב-Google Cloud.
5. שומרים. את הסוד מדביק רן בעצמו, ולא שולחים אותו בשיחה.

## 4. כתובות האפליקציה (URL Configuration)

שוב, לכל פרויקט בנפרד: **Authentication → URL Configuration**.

### מצפה / נחת (`YOUR_PROJECT_REF`)

- **Site URL:** `https://nahat-app.ranbenri.workers.dev`
- **Redirect URLs** (כל שורה בנפרד):
  - `https://nahat-app.ranbenri.workers.dev`
  - `https://nahat-app.ranbenri.workers.dev/**`

### כליל / כלילי (`YOUR_PROJECT_REF`)

- **Site URL:** `https://klili-app.klili.workers.dev`
- **Redirect URLs:**
  - `https://klili-app.klili.workers.dev`
  - `https://klili-app.klili.workers.dev/**`

אם יתווסף דומיין מותאם (למשל כתובת האפליקציה הרשמית), מוסיפים גם אותו כ-Site URL / Redirect URL באותו מסך.

האפליקציה שולחת `redirectTo` לכתובת שבה המשתמש נמצא. בלי לרשום אותה כאן, Google/Supabase יחזירו שגיאה אחרי ההתחברות.

## 5. (אופציונלי) כיבוי הרשמה במייל

אם רוצים שתושבות ותושבים ייכנסו רק עם Google, באותו מסך Providers אפשר לכבות את Email (או לבטל Sign-ups ולהשאיר כניסה למייל רק למנהלים דרך ה-OTP של `/admin`). לא חובה לפני הבדיקה הראשונה.

## 6. בדיקה מהירה

1. אחרי שמירת הספק, פותחים את האפליקציה בטאב **שלי** ולוחצים «כניסה עם Google».
2. אם הספק עדיין כבוי או שהסוד חסר, הכפתור מציג הודעה בעברית ולא נשבר.
3. אחרי כניסה מוצלחת מופיעים השם והתמונה מחשבון Google, וסטטוס התושב (אין בקשה / ממתין / מאומת / נדחה). «בקשת אימות תושב» נשלחת למסד (`public.residents` בבקשת 009) ומחכה לאישור מנהל/ת או מנהל/ת קהילה.

ההרשמה למושבי קורס/סדנה והפרסום בקהילה זמינים רק לתושב/ת עם סטטוס **מאומת** (`verified`).
