-- 005: סטטוס "נדחה" + הערת בדיקה (סיבת דחייה). תוספת בלבד.
alter type public.place_status add value if not exists 'rejected';
alter table public.places add column if not exists review_note text;
alter table public.events add column if not exists review_note text;
