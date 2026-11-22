-- 025: «או ממליצים על מישהו» — תושב/ת מאומת/ת מציע/ה מקום/עסק. נוצר מקום בסטטוס pending_publish שמחכה לאישור אדמין
-- (לשונית «מקומות» בניהול). מי שהציע/ה נשמר/ת רק ב־place_suggestions (קריאה: רק אותו משתמש או אדמין), לא בטבלת המקומות.
-- טלפונים ומיילים נמחקים מהטקסט החופשי; טלפון נשמר רק בשדה «טלפון העסק».
create or replace function public.resident_suggest_place(p_name text, p_category_group text, p_note text,
  p_phone text default null, p_website text default null, p_address text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); cid text; pid text; n text; nt text; ph text; web text; addr text; recent int;
  phone_re constant text := '\+?\d[\d\s\-–]{7,}\d';
  mail_re constant text := '[^\s@]+@[^\s@]+\.[^\s@]+';
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  select r.community_id into cid from public.residents r where r.user_id = uid and r.status = 'verified';
  if cid is null then raise exception 'not verified' using errcode = '42501'; end if;
  select count(*) into recent from public.place_suggestions s where s.user_id = uid and s.created_at > now() - interval '1 day';
  if recent >= 5 then raise exception 'too many suggestions today' using errcode = '54000'; end if;
  n := btrim(regexp_replace(regexp_replace(left(btrim(coalesce(p_name, '')), 120), phone_re, '', 'g'), mail_re, '', 'g'));
  if char_length(n) < 2 then raise exception 'name required' using errcode = '22023'; end if;
  nt := btrim(regexp_replace(regexp_replace(left(coalesce(p_note, ''), 600), phone_re, '[הוסר]', 'g'), mail_re, '[הוסר]', 'g'));
  ph := nullif(regexp_replace(coalesce(p_phone, ''), '[^\d+]', '', 'g'), '');
  if ph is not null and ph !~ '^\+?\d{9,13}$' then raise exception 'bad phone' using errcode = '22023'; end if;
  web := nullif(btrim(coalesce(p_website, '')), '');
  if web is not null and web !~* '^(https?://)?[a-z0-9.-]+\.[a-z]{2,}(/\S*)?$' then raise exception 'bad website' using errcode = '22023'; end if;
  addr := nullif(btrim(regexp_replace(left(coalesce(p_address, ''), 160), phone_re, '', 'g')), '');
  pid := 'rec-' || encode(extensions.gen_random_bytes(6), 'hex');
  insert into public.places (id, name_he, category_group, note, phone, website, address, source, status, community_id, search_only, updated_by)
  values (pid, n, nullif(left(btrim(coalesce(p_category_group, '')), 60), ''), nullif(nt, ''), ph, web, addr,
          'המלצת תושב/ת', 'pending_publish'::public.place_status, cid, false, null);
  insert into public.place_suggestions (place_id, user_id, fields, note, status)
  values (pid, uid, jsonb_build_object('kind', 'new_place', 'name_he', n, 'category_group', p_category_group), 'new_place', 'open');
  return jsonb_build_object('id', pid, 'status', 'pending_publish');
end $$;
revoke all on function public.resident_suggest_place(text, text, text, text, text, text) from public, anon;
grant execute on function public.resident_suggest_place(text, text, text, text, text, text) to authenticated;

-- ההמלצות שלי (רק של המשתמש המחובר), עם הסטטוס הנוכחי של המקום.
create or replace function public.my_place_suggestions()
returns table (place_id text, name_he text, category_group text, status text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select s.place_id, p.name_he, p.category_group, p.status::text, s.created_at
    from public.place_suggestions s join public.places p on p.id = s.place_id
   where s.user_id = (select auth.uid()) and s.note = 'new_place'
   order by s.created_at desc limit 50
$$;
revoke all on function public.my_place_suggestions() from public, anon;
grant execute on function public.my_place_suggestions() to authenticated;
