-- 023: טרמפ — 'מתאים לי גם חלק מהדרך' (בקשה) / 'אפשר להצטרף גם לחלק מהדרך' (הצעה).
alter table public.posts add column if not exists partial_ok boolean not null default false;
