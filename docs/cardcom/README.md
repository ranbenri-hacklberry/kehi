# Cardcom (v11 LowProfile) — עדיין לא מופעל

הקוד בתיקייה הזו מוכן לחיבור סליקה, אבל **לא נפרס ולא הוגדר**. אין בקבצים ובסביבה מספר מסוף, מפתחות או סיסמאות. לא מוסיפים סודות בלי אישור מפורש של רן.

מחירי המסלולים כוללים מע״מ. תשלום שנתי (`business_yearly`, `founder_yearly`) נוצר כ-`ChargeOnly`; תשלום חודשי (`business_monthly`, `pro_monthly`) כ-`ChargeAndCreateToken` לצורך הוראת קבע. Bit ו-Apple Pay מוצגים באפליקציה רק במסלולים שנתיים. כרגע כפתור «לתשלום» באפליקציה מציג «התשלום ייפתח בקרוב». ניסיון של 14 יום עובד בלי כרטיס.

## מה רן צריך לספק כדי להפעיל

1. **מסוף Cardcom (TerminalNumber)** — המסוף הפנימי, לא מסוף שב״א. משתנה: `CARDCOM_TERMINAL`.
2. **ApiName** — שם המשתמש לממשק. משתנה: `CARDCOM_API_NAME`.
3. **ApiPassword** — סיסמת API (נדרשת להפקת מסמכים/זיכויים לפי התיעוד). משתנה: `CARDCOM_API_PASSWORD`.
4. **מודולים במסוף:** Low Profile, Documents (חשבוניות), Tokens (להוראת קבע חודשית), ו-Bit / Apple Pay אם רוצים אותם במסלולים השנתיים.
5. **כתובת המייל של paperless.tax** להעתק חשבונית מס-קבלה. משתנה: `CARDCOM_PAPERLESS_TAX_EMAIL` (משאירים placeholder עד שתהיה כתובת).
6. **סביבת בדיקות (sandbox)** מצוות התמיכה של Cardcom (03-9436100 / support@secure.cardcom.co.il), ואחר כך מסוף ייצור.
7. **אישור מפורש לפרוס** את ה-Worker ולהדביק את המשתנים בעצמו (לא לכתוב ערכים בצ'אט או בקבצים).
8. לפרוס יידרשו גם: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (להפעלת `private.apply_cardcom_payment` אחרי אימות), `PAYMENT_SUCCESS_URL`, `PAYMENT_FAILED_URL`, וכתובת ציבורית ל-webhook (`CARDCOM_WEBHOOK_PUBLIC_URL`).

## API שנעשה בו שימוש (v11)

תיעוד: https://kb.cardcom.solutions/apijosn/en/articles/503/create-payment-page-retrieve-transaction-details  
Swagger: https://secure.cardcom.solutions/Api/v11/Docs

- יצירת דף תשלום: `POST https://secure.cardcom.solutions/api/v11/LowProfile/Create`  
  שדות עיקריים: `TerminalNumber`, `ApiName`, `Operation`, `Amount`, `ReturnValue`, `SuccessRedirectUrl`, `FailedRedirectUrl`, `WebHookUrl`, `Language` (`he`), `ISOCoinId` (`1` = ₪), `ProductName`, ו-`Document`.
- אימות תוצאה (חובה, לא סומכים על ה-webhook לבדו): `POST https://secure.cardcom.solutions/api/v11/LowProfile/GetLpResult` עם `TerminalNumber`, `ApiName`, `LowProfileId`. הצלחה: `ResponseCode === 0`. מזהה עסקה: `TranzactionId`.
- חשבונית מס קבלה: אובייקט `Document` בבקשת Create, `TypeToCreate`: `TaxInvoiceAndReceipt`. `Email` יכול לכלול כמה כתובות מופרדות בנקודה-פסיק (לקוח + `CARDCOM_PAPERLESS_TAX_EMAIL`). `IsSendByEmail`: true. סכום המוצרים חייב להתאים ל-`Amount`.
- Bit: כשמופעל במסוף, התשובה כוללת `UrlToBit`. Apple Pay מגיע כשיטת תשלום חיצונית בתוצאת העסקה, לא כפרמטר יצירה נפרד.
- `ApiPassword` לפי התיעוד נדרש בעיקר לזיכויים / `Documents/CreateDocument`, לא ליצירת דף LowProfile.

## איך ה-Worker אמור לעבוד (אחרי פריסה)

`worker.js` הוא Cloudflare Worker לדוגמה. **לא מועלה לחשבון ולא רץ.**

- `POST /pay/create` — אם אחד ממשתני Cardcom חסר, מחזיר 503. אחרת יוצר LowProfile ומחזיר את כתובת הדף.
- `POST /pay/webhook` — קורא `GetLpResult`, ורק אם `ResponseCode === 0` קורא ל-`private.apply_cardcom_payment` עם מפתח השירות. אם השרת לא מחזיר 200, Cardcom מנסה שוב.

אל תדביקו ערכים של משתנים כאן או בקוד.
