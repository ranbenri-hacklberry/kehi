-- 006: פעולות אדמין. כל הפונקציות SECURITY INVOKER: ה־RLS הקיים (places_admin_* / events_admin_*) הוא האכיפה,
-- ובנוסף כל פונקציה בודקת private.is_admin(). anon לא יכול להריץ אותן. כל שינוי נרשם ב־audit_log ע"י הטריגרים הקיימים.

create or replace function public.admin_whoami() returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
begin
  return jsonb_build_object('is_admin', coalesce((select private.is_admin()), false),
                            'email', (select auth.jwt() ->> 'email'));
end $$;

create or replace function public.admin_list_places() returns setof public.places
language plpgsql stable security invoker set search_path = '' as $$
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query select * from public.places order by name_he;
end $$;

create or replace function public.admin_list_events() returns setof public.events
language plpgsql stable security invoker set search_path = '' as $$
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query select * from public.events order by coalesce(starts_at, start_date::timestamptz) nulls last, title;
end $$;

create or replace function public.admin_set_status(p_kind text, p_ids text[], p_status text, p_reason text default null)
returns integer language plpgsql volatile security invoker set search_path = '' as $$
declare n integer; r text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  if p_status not in ('published', 'pending_publish', 'rejected', 'hidden') then raise exception 'bad status %', p_status using errcode = '22023'; end if;
  if p_status = 'rejected' and r is null then raise exception 'reason required' using errcode = '22023'; end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 or array_length(p_ids, 1) > 500 then raise exception 'bad ids' using errcode = '22023'; end if;
  if p_kind = 'places' then
    update public.places set status = p_status::public.place_status, review_note = r where id = any(p_ids);
  elsif p_kind = 'events' then
    update public.events set status = p_status::public.place_status, review_note = r where id = any(p_ids);
  else
    raise exception 'bad kind' using errcode = '22023';
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.admin_update_place(p_id text, p_patch jsonb, p_version integer default null)
returns public.places language plpgsql volatile security invoker set search_path = '' as $$
declare res public.places; bad text;
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  select string_agg(k, ',') into bad from jsonb_object_keys(p_patch) k
    where k not in ('name_he','category_group','category','note','hours','phone','website','address','badge','search_only');
  if bad is not null then raise exception 'field not editable: %', bad using errcode = '22023'; end if;
  if p_patch ? 'name_he' and nullif(btrim(p_patch->>'name_he'), '') is null then raise exception 'name required' using errcode = '22023'; end if;
  update public.places p set
    name_he        = case when p_patch ? 'name_he' then btrim(p_patch->>'name_he') else p.name_he end,
    category_group = case when p_patch ? 'category_group' then nullif(btrim(p_patch->>'category_group'), '') else p.category_group end,
    category       = case when p_patch ? 'category' then nullif(btrim(p_patch->>'category'), '') else p.category end,
    note           = case when p_patch ? 'note' then nullif(btrim(p_patch->>'note'), '') else p.note end,
    hours          = case when p_patch ? 'hours' then nullif(btrim(p_patch->>'hours'), '') else p.hours end,
    phone          = case when p_patch ? 'phone' then nullif(btrim(p_patch->>'phone'), '') else p.phone end,
    website        = case when p_patch ? 'website' then nullif(btrim(p_patch->>'website'), '') else p.website end,
    address        = case when p_patch ? 'address' then nullif(btrim(p_patch->>'address'), '') else p.address end,
    badge          = case when p_patch ? 'badge' then nullif(btrim(p_patch->>'badge'), '') else p.badge end,
    search_only    = case when p_patch ? 'search_only' then coalesce((p_patch->>'search_only')::boolean, false) else p.search_only end
  where p.id = p_id and (p_version is null or p.version = p_version)
  returning * into res;
  if res.id is null then raise exception 'not found or changed by someone else' using errcode = '40001'; end if;
  return res;
end $$;

create or replace function public.admin_update_event(p_id text, p_patch jsonb, p_version integer default null)
returns public.events language plpgsql volatile security invoker set search_path = '' as $$
declare res public.events; bad text;
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  select string_agg(k, ',') into bad from jsonb_object_keys(p_patch) k
    where k not in ('title','when_text','venue_name','address','price_text','organizer','description','start_date','starts_at','ends_at');
  if bad is not null then raise exception 'field not editable: %', bad using errcode = '22023'; end if;
  if p_patch ? 'title' and nullif(btrim(p_patch->>'title'), '') is null then raise exception 'title required' using errcode = '22023'; end if;
  update public.events e set
    title       = case when p_patch ? 'title' then btrim(p_patch->>'title') else e.title end,
    when_text   = case when p_patch ? 'when_text' then nullif(btrim(p_patch->>'when_text'), '') else e.when_text end,
    venue_name  = case when p_patch ? 'venue_name' then nullif(btrim(p_patch->>'venue_name'), '') else e.venue_name end,
    address     = case when p_patch ? 'address' then nullif(btrim(p_patch->>'address'), '') else e.address end,
    price_text  = case when p_patch ? 'price_text' then nullif(btrim(p_patch->>'price_text'), '') else e.price_text end,
    organizer   = case when p_patch ? 'organizer' then nullif(btrim(p_patch->>'organizer'), '') else e.organizer end,
    description = case when p_patch ? 'description' then nullif(btrim(p_patch->>'description'), '') else e.description end,
    start_date  = case when p_patch ? 'start_date' then nullif(p_patch->>'start_date', '')::date else e.start_date end,
    starts_at   = case when p_patch ? 'starts_at' then nullif(p_patch->>'starts_at', '')::timestamptz else e.starts_at end,
    ends_at     = case when p_patch ? 'ends_at' then nullif(p_patch->>'ends_at', '')::timestamptz else e.ends_at end
  where e.id = p_id and (p_version is null or e.version = p_version)
  returning * into res;
  if res.id is null then raise exception 'not found or changed by someone else' using errcode = '40001'; end if;
  return res;
end $$;

revoke all on function public.admin_whoami(), public.admin_list_places(), public.admin_list_events(),
  public.admin_set_status(text, text[], text, text), public.admin_update_place(text, jsonb, integer),
  public.admin_update_event(text, jsonb, integer) from public, anon;
grant execute on function public.admin_whoami(), public.admin_list_places(), public.admin_list_events(),
  public.admin_set_status(text, text[], text, text), public.admin_update_place(text, jsonb, integer),
  public.admin_update_event(text, jsonb, integer) to authenticated;

-- יצירת משתמש אדמין (רק מצד השרת, סכמה פרטית; לא נגיש ל־anon/authenticated).
-- יוצר משתמש מאומת עם זהות email (כך signInWithOtp עם shouldCreateUser:false עובד), ומוסיף ל־private.admins.
create or replace function private.create_admin_user(p_email text) returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare e text := lower(btrim(p_email)); uid uuid;
begin
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'bad email'; end if;
  select id into uid from auth.users where lower(email) = e;
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      email_change_token_current, phone_change, phone_change_token, reauthentication_token)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', e, '', now(),
      '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
      '', '', '', '', '', '', '', '');
    insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
    values (uid::text, uid, jsonb_build_object('sub', uid::text, 'email', e, 'email_verified', true, 'phone_verified', false),
      'email', now(), now());
  end if;
  insert into private.admins (user_id) values (uid) on conflict do nothing;
  return uid;
end $$;
revoke all on function private.create_admin_user(text) from public, anon, authenticated;
