-- 012: מדיניות RLS של posts/replies קוראת ל-private.is_staff().
-- בלי EXECUTE ל-anon, בחירת פרסומים פתוחים נכשלת ב-permission denied.
-- הפונקציות הן SECURITY DEFINER ומחזירות רק boolean לפי auth.uid(); ל-anon התוצאה תמיד false.

grant execute on function private.is_staff() to anon, authenticated;
grant execute on function private.is_manager() to anon, authenticated;
grant execute on function private.is_verified_resident() to anon, authenticated;
