-- 024: טרמפ — השתתפות בדלק (בקשה: מוכן/ה להשתתף; הצעה: מבקש/ת השתתפות). בלי סכומים ובלי תשלום.
alter table public.posts add column if not exists fuel_share boolean not null default false;
