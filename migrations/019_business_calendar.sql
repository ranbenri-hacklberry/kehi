-- 019: יומן עסק פנימי (שעות, אירועים, תורים) + עדכון רשימות «מה כלול» במסלולים.
-- בלי OAuth לגוגל. סנכרון דו-כיווני עם גוגל יומן מסומן «בקרוב» לפרו בלבד.
-- מועדי קורס/סדנה נשארים ב-010 (post_slots / book_slot); כאן יומן תורים של העסק.

-- ---------- טבלאות ----------
create table if not exists public.business_calendar_settings (
  user_id uuid primary key references public.business_accounts(user_id) on delete cascade,
  slot_minutes integer not null default 60 check (slot_minutes in (30, 45, 60, 90, 120)),
  horizon_days integer not null default 14 check (horizon_days between 1 and 90),
  buffer_minutes integer not null default 0 check (buffer_minutes between 0 and 180),
  is_accepting boolean not null default true,
  timezone text not null default 'Asia/Jerusalem',
  updated_at timestamptz not null default now()
);

create table if not exists public.business_hours (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.business_accounts(user_id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  start_time time,
  end_time time,
  is_closed boolean not null default false,
  created_at timestamptz not null default now(),
  constraint business_hours_time_chk check (is_closed or (start_time is not null and end_time is not null and end_time > start_time))
);
create index if not exists business_hours_user_idx on public.business_hours (user_id, weekday);

create table if not exists public.business_calendar_exceptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.business_accounts(user_id) on delete cascade,
  on_date date not null,
  is_closed boolean not null default false,
  start_time time,
  end_time time,
  note text,
  created_at timestamptz not null default now(),
  constraint business_exceptions_uniq unique (user_id, on_date),
  constraint business_exceptions_time_chk check (is_closed or (start_time is null and end_time is null) or (start_time is not null and end_time is not null and end_time > start_time))
);
create index if not exists business_exceptions_user_idx on public.business_calendar_exceptions (user_id, on_date);

create table if not exists public.business_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.business_accounts(user_id) on delete cascade,
  title text not null,
  description text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  is_public boolean not null default true,
  blocks_bookings boolean not null default true,
  created_at timestamptz not null default now(),
  constraint business_events_time_chk check (ends_at > starts_at)
);
create index if not exists business_events_user_idx on public.business_events (user_id, starts_at);

create table if not exists public.business_bookings (
  id uuid primary key default gen_random_uuid(),
  business_user_id uuid not null references public.business_accounts(user_id) on delete cascade,
  resident_user_id uuid not null references auth.users(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null check (status in ('requested', 'confirmed', 'rejected', 'cancelled')),
  resident_note text,
  owner_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_bookings_time_chk check (ends_at > starts_at)
);
create index if not exists business_bookings_biz_idx on public.business_bookings (business_user_id, starts_at);
create index if not exists business_bookings_res_idx on public.business_bookings (resident_user_id, status);

create table if not exists public.app_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  title text not null,
  body text,
  payload jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists app_notifications_user_idx on public.app_notifications (user_id, created_at desc);

alter table public.business_calendar_settings enable row level security;
alter table public.business_hours enable row level security;
alter table public.business_calendar_exceptions enable row level security;
alter table public.business_events enable row level security;
alter table public.business_bookings enable row level security;
alter table public.app_notifications enable row level security;

revoke all on table
  public.business_calendar_settings,
  public.business_hours,
  public.business_calendar_exceptions,
  public.business_events,
  public.business_bookings,
  public.app_notifications
  from public, anon, authenticated;

-- ---------- עזר ----------
create or replace function private.calendar_eligible(p_user uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.business_accounts a
    where a.user_id = p_user
      and (coalesce(a.is_comp, false) or a.status in ('trial', 'active'))
  );
$$;
revoke all on function private.calendar_eligible(uuid) from public, anon, authenticated;

create or replace function private.ensure_calendar_settings(p_user uuid)
returns public.business_calendar_settings
language plpgsql volatile security definer set search_path = '' as $$
declare rec public.business_calendar_settings;
begin
  insert into public.business_calendar_settings (user_id)
  values (p_user)
  on conflict (user_id) do nothing;
  select * into rec from public.business_calendar_settings where user_id = p_user;
  return rec;
end $$;
revoke all on function private.ensure_calendar_settings(uuid) from public, anon, authenticated;

create or replace function private.notify_user(p_user uuid, p_kind text, p_title text, p_body text, p_payload jsonb)
returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_user is null then return; end if;
  insert into public.app_notifications (user_id, kind, title, body, payload)
  values (p_user, p_kind, p_title, p_body, coalesce(p_payload, '{}'::jsonb));
end $$;
revoke all on function private.notify_user(uuid, text, text, text, jsonb) from public, anon, authenticated;

create or replace function private.slot_overlaps_busy(p_user uuid, p_start timestamptz, p_end timestamptz, p_ignore uuid default null)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.business_bookings b
    where b.business_user_id = p_user
      and b.status in ('requested', 'confirmed')
      and (p_ignore is null or b.id <> p_ignore)
      and b.starts_at < p_end and b.ends_at > p_start
  ) or exists (
    select 1 from public.business_events e
    where e.user_id = p_user
      and e.blocks_bookings
      and e.starts_at < p_end and e.ends_at > p_start
  );
$$;
revoke all on function private.slot_overlaps_busy(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;

create or replace function private.list_open_slots(p_user uuid, p_from date, p_to date)
returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  stg public.business_calendar_settings;
  d date;
  tz text := 'Asia/Jerusalem';
  rec record;
  ex public.business_calendar_exceptions;
  slot_start timestamptz;
  slot_end timestamptz;
  mins int;
  win_start time;
  win_end time;
  closed boolean;
begin
  select * into stg from public.business_calendar_settings s where s.user_id = p_user;
  mins := coalesce(stg.slot_minutes, 60);
  if stg.user_id is not null and not stg.is_accepting then return; end if;
  if p_from is null or p_to is null or p_to < p_from then return; end if;
  if p_to > ((now() at time zone tz)::date + coalesce(stg.horizon_days, 14)) then
    p_to := (now() at time zone tz)::date + coalesce(stg.horizon_days, 14);
  end if;
  if p_from < (now() at time zone tz)::date then
    p_from := (now() at time zone tz)::date;
  end if;

  d := p_from;
  while d <= p_to loop
    closed := false;
    win_start := null;
    win_end := null;
    select * into ex from public.business_calendar_exceptions e where e.user_id = p_user and e.on_date = d;
    if found then
      if ex.is_closed then
        closed := true;
      else
        win_start := ex.start_time;
        win_end := ex.end_time;
      end if;
    end if;
    if not closed and win_start is null then
      for rec in
        select h.start_time, h.end_time, h.is_closed
        from public.business_hours h
        where h.user_id = p_user and h.weekday = extract(dow from d)::int
      loop
        if rec.is_closed then
          closed := true;
        else
          -- תומך בטווח אחד ליום ב-UI; אם יש כמה שורות פתוחות, כל אחת מייצרת תורים
          slot_start := ((d::timestamp + rec.start_time) at time zone tz);
          while slot_start + make_interval(mins => mins) <= ((d::timestamp + rec.end_time) at time zone tz) loop
            slot_end := slot_start + make_interval(mins => mins);
            if slot_start >= now() and not private.slot_overlaps_busy(p_user, slot_start, slot_end, null) then
              starts_at := slot_start;
              ends_at := slot_end;
              return next;
            end if;
            slot_start := slot_end + make_interval(mins => coalesce(stg.buffer_minutes, 0));
          end loop;
        end if;
      end loop;
    elsif not closed and win_start is not null then
      slot_start := ((d::timestamp + win_start) at time zone tz);
      while slot_start + make_interval(mins => mins) <= ((d::timestamp + win_end) at time zone tz) loop
        slot_end := slot_start + make_interval(mins => mins);
        if slot_start >= now() and not private.slot_overlaps_busy(p_user, slot_start, slot_end, null) then
          starts_at := slot_start;
          ends_at := slot_end;
          return next;
        end if;
        slot_start := slot_end + make_interval(mins => coalesce(stg.buffer_minutes, 0));
      end loop;
    end if;
    d := d + 1;
  end loop;
end $$;
revoke all on function private.list_open_slots(uuid, date, date) from public, anon, authenticated;

-- ---------- RPCs לבעל/ת העסק ----------
create or replace function public.my_business_calendar()
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  acc public.business_accounts;
  stg public.business_calendar_settings;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  select * into acc from public.business_accounts a where a.user_id = uid;
  if acc.user_id is null then raise exception 'no business account' using errcode = '42501'; end if;
  if not private.calendar_eligible(uid) then raise exception 'calendar not included' using errcode = '42501'; end if;
  stg := private.ensure_calendar_settings(uid);
  return jsonb_build_object(
    'eligible', true,
    'settings', to_jsonb(stg),
    'business_name', acc.business_name,
    'place_id', acc.place_id,
    'is_comp', coalesce(acc.is_comp, false),
    'tier', acc.subscription_tier,
    'hours', coalesce((select jsonb_agg(to_jsonb(h) order by h.weekday, h.start_time) from public.business_hours h where h.user_id = uid), '[]'::jsonb),
    'exceptions', coalesce((select jsonb_agg(to_jsonb(e) order by e.on_date) from public.business_calendar_exceptions e where e.user_id = uid and e.on_date >= (now() at time zone 'Asia/Jerusalem')::date - 1), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(ev) order by ev.starts_at) from public.business_events ev where ev.user_id = uid and ev.ends_at >= now() - interval '1 day'), '[]'::jsonb),
    'bookings', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id,
        'starts_at', b.starts_at,
        'ends_at', b.ends_at,
        'status', b.status,
        'resident_note', b.resident_note,
        'owner_note', b.owner_note,
        'display_name', coalesce(p.display_name, 'תושב/ת'),
        'created_at', b.created_at
      ) order by b.starts_at)
      from public.business_bookings b
      left join public.profiles p on p.user_id = b.resident_user_id
      where b.business_user_id = uid and b.status in ('requested', 'confirmed') and b.ends_at >= now() - interval '1 day'
    ), '[]'::jsonb),
    'open_slots', coalesce((
      select jsonb_agg(jsonb_build_object('starts_at', s.starts_at, 'ends_at', s.ends_at) order by s.starts_at)
      from private.list_open_slots(uid, (now() at time zone 'Asia/Jerusalem')::date, (now() at time zone 'Asia/Jerusalem')::date + stg.horizon_days) s
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.my_business_calendar() from public, anon;
grant execute on function public.my_business_calendar() to authenticated;

create or replace function public.upsert_calendar_settings(p_slot_minutes integer, p_horizon_days integer, p_is_accepting boolean, p_buffer_minutes integer default 0)
returns public.business_calendar_settings
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  rec public.business_calendar_settings;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if not private.calendar_eligible(uid) then raise exception 'calendar not included' using errcode = '42501'; end if;
  rec := private.ensure_calendar_settings(uid);
  update public.business_calendar_settings
     set slot_minutes = coalesce(p_slot_minutes, slot_minutes),
         horizon_days = coalesce(p_horizon_days, horizon_days),
         is_accepting = coalesce(p_is_accepting, is_accepting),
         buffer_minutes = coalesce(p_buffer_minutes, buffer_minutes),
         updated_at = now()
   where user_id = uid
  returning * into rec;
  return rec;
end $$;
revoke all on function public.upsert_calendar_settings(integer, integer, boolean, integer) from public, anon;
grant execute on function public.upsert_calendar_settings(integer, integer, boolean, integer) to authenticated;

create or replace function public.set_business_hours(p_hours jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  el jsonb;
  wd int; st time; en time; cl boolean;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if not private.calendar_eligible(uid) then raise exception 'calendar not included' using errcode = '42501'; end if;
  if p_hours is null or jsonb_typeof(p_hours) <> 'array' then
    raise exception 'hours required' using errcode = '22023';
  end if;
  delete from public.business_hours where user_id = uid;
  for el in select * from jsonb_array_elements(p_hours)
  loop
    wd := (el->>'weekday')::int;
    cl := coalesce((el->>'is_closed')::boolean, false);
    st := nullif(el->>'start_time','')::time;
    en := nullif(el->>'end_time','')::time;
    if wd is null or wd < 0 or wd > 6 then raise exception 'bad weekday' using errcode = '22023'; end if;
    insert into public.business_hours (user_id, weekday, start_time, end_time, is_closed)
    values (uid, wd, st, en, cl);
  end loop;
  return coalesce((select jsonb_agg(to_jsonb(h) order by h.weekday, h.start_time) from public.business_hours h where h.user_id = uid), '[]'::jsonb);
end $$;
revoke all on function public.set_business_hours(jsonb) from public, anon;
grant execute on function public.set_business_hours(jsonb) to authenticated;

create or replace function public.upsert_business_event(p_id uuid, p_title text, p_description text, p_starts_at timestamptz, p_ends_at timestamptz, p_is_public boolean default true, p_blocks boolean default true)
returns public.business_events
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  rec public.business_events;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if not private.calendar_eligible(uid) then raise exception 'calendar not included' using errcode = '42501'; end if;
  if nullif(btrim(coalesce(p_title,'')), '') is null then raise exception 'title required' using errcode = '22023'; end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then raise exception 'bad times' using errcode = '22023'; end if;
  if p_id is not null then
    update public.business_events
       set title = btrim(p_title),
           description = nullif(btrim(coalesce(p_description,'')), ''),
           starts_at = p_starts_at,
           ends_at = p_ends_at,
           is_public = coalesce(p_is_public, true),
           blocks_bookings = coalesce(p_blocks, true)
     where id = p_id and user_id = uid
    returning * into rec;
    if rec.id is null then raise exception 'not found' using errcode = '42501'; end if;
    return rec;
  end if;
  insert into public.business_events (user_id, title, description, starts_at, ends_at, is_public, blocks_bookings)
  values (uid, btrim(p_title), nullif(btrim(coalesce(p_description,'')), ''), p_starts_at, p_ends_at, coalesce(p_is_public, true), coalesce(p_blocks, true))
  returning * into rec;
  return rec;
end $$;
revoke all on function public.upsert_business_event(uuid, text, text, timestamptz, timestamptz, boolean, boolean) from public, anon;
grant execute on function public.upsert_business_event(uuid, text, text, timestamptz, timestamptz, boolean, boolean) to authenticated;

create or replace function public.delete_business_event(p_id uuid)
returns integer
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); n int;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  delete from public.business_events where id = p_id and user_id = uid;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.delete_business_event(uuid) from public, anon;
grant execute on function public.delete_business_event(uuid) to authenticated;

create or replace function public.review_business_booking(p_id uuid, p_decision text, p_note text default null)
returns public.business_bookings
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  rec public.business_bookings;
  new_st text;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if not private.calendar_eligible(uid) then raise exception 'calendar not included' using errcode = '42501'; end if;
  new_st := case p_decision
    when 'approved' then 'confirmed'
    when 'rejected' then 'rejected'
    when 'cancelled' then 'cancelled'
    else null end;
  if new_st is null then raise exception 'bad decision' using errcode = '22023'; end if;
  select * into rec from public.business_bookings b where b.id = p_id and b.business_user_id = uid for update;
  if rec.id is null then raise exception 'not found' using errcode = '42501'; end if;
  if new_st = 'confirmed' and rec.status <> 'requested' then raise exception 'not requested' using errcode = '22023'; end if;
  if new_st = 'confirmed' and private.slot_overlaps_busy(uid, rec.starts_at, rec.ends_at, rec.id) then
    raise exception 'overlap' using errcode = 'P0001';
  end if;
  update public.business_bookings
     set status = new_st,
         owner_note = nullif(btrim(coalesce(p_note, '')), ''),
         updated_at = now()
   where id = rec.id
  returning * into rec;
  if new_st = 'confirmed' then
    perform private.notify_user(rec.resident_user_id, 'booking_approved', 'התור אושר', 'בעל/ת העסק אישר/ה את התור שביקשת.', jsonb_build_object('booking_id', rec.id));
  elsif new_st = 'rejected' then
    perform private.notify_user(rec.resident_user_id, 'booking_rejected', 'התור לא אושר', 'בעל/ת העסק דחה/תה את בקשת התור.', jsonb_build_object('booking_id', rec.id));
  elsif new_st = 'cancelled' then
    perform private.notify_user(rec.resident_user_id, 'booking_cancelled', 'התור בוטל', 'בעל/ת העסק ביטל/ה את התור.', jsonb_build_object('booking_id', rec.id));
  end if;
  return rec;
end $$;
revoke all on function public.review_business_booking(uuid, text, text) from public, anon;
grant execute on function public.review_business_booking(uuid, text, text) to authenticated;

-- ---------- RPCs לתושבות/ים ----------
create or replace function public.place_public_calendar(p_place_id text, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  acc public.business_accounts;
  stg public.business_calendar_settings;
  d0 date;
  d1 date;
begin
  if p_place_id is null then raise exception 'bad id' using errcode = '22023'; end if;
  select a.* into acc
  from public.business_accounts a
  join public.places pl on pl.id = a.place_id
  where a.place_id = p_place_id
    and pl.status = 'published'
    and private.calendar_eligible(a.user_id)
  limit 1;
  if acc.user_id is null then
    return jsonb_build_object('eligible', false);
  end if;
  select * into stg from public.business_calendar_settings s where s.user_id = acc.user_id;
  d0 := coalesce(p_from, (now() at time zone 'Asia/Jerusalem')::date);
  d1 := coalesce(p_to, d0 + coalesce(stg.horizon_days, 14));
  return jsonb_build_object(
    'eligible', true,
    'accepting', coalesce(stg.is_accepting, true),
    'slot_minutes', coalesce(stg.slot_minutes, 60),
    'business_user_id', acc.user_id,
    'business_name', acc.business_name,
    'hours', coalesce((select jsonb_agg(jsonb_build_object('weekday', h.weekday, 'start_time', h.start_time, 'end_time', h.end_time, 'is_closed', h.is_closed) order by h.weekday) from public.business_hours h where h.user_id = acc.user_id), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'description', e.description, 'starts_at', e.starts_at, 'ends_at', e.ends_at) order by e.starts_at)
      from public.business_events e
      where e.user_id = acc.user_id and e.is_public and e.ends_at >= now() and e.starts_at < (d1 + 1)
    ), '[]'::jsonb),
    'open_slots', case when coalesce(stg.is_accepting, true) then coalesce((
      select jsonb_agg(jsonb_build_object('starts_at', s.starts_at, 'ends_at', s.ends_at) order by s.starts_at)
      from private.list_open_slots(acc.user_id, d0, d1) s
    ), '[]'::jsonb) else '[]'::jsonb end,
    'my_bookings', case when uid is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('id', b.id, 'starts_at', b.starts_at, 'ends_at', b.ends_at, 'status', b.status) order by b.starts_at)
      from public.business_bookings b
      where b.business_user_id = acc.user_id and b.resident_user_id = uid and b.status in ('requested', 'confirmed') and b.ends_at >= now()
    ), '[]'::jsonb) end
  );
end $$;
revoke all on function public.place_public_calendar(text, date, date) from public;
grant execute on function public.place_public_calendar(text, date, date) to anon, authenticated;

create or replace function public.request_business_slot(p_business_user_id uuid, p_starts_at timestamptz, p_ends_at timestamptz, p_note text default null)
returns public.business_bookings
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  rec public.business_bookings;
  stg public.business_calendar_settings;
  ok boolean := false;
  s record;
  acc public.business_accounts;
  bname text;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if not coalesce((select private.is_verified_resident()), false) then
    raise exception 'not verified' using errcode = '42501';
  end if;
  if p_business_user_id is null or p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'bad slot' using errcode = '22023';
  end if;
  if p_starts_at < now() then raise exception 'past' using errcode = '22023'; end if;
  if not private.calendar_eligible(p_business_user_id) then raise exception 'calendar not included' using errcode = '42501'; end if;
  select * into acc from public.business_accounts a where a.user_id = p_business_user_id;
  stg := private.ensure_calendar_settings(p_business_user_id);
  if not stg.is_accepting then raise exception 'not accepting' using errcode = '22023'; end if;
  for s in select * from private.list_open_slots(p_business_user_id, (p_starts_at at time zone 'Asia/Jerusalem')::date, (p_starts_at at time zone 'Asia/Jerusalem')::date)
  loop
    if s.starts_at = p_starts_at and s.ends_at = p_ends_at then ok := true; exit; end if;
  end loop;
  if not ok then raise exception 'not available' using errcode = 'P0001'; end if;
  if exists (
    select 1 from public.business_bookings b
    where b.business_user_id = p_business_user_id and b.resident_user_id = uid
      and b.status in ('requested', 'confirmed') and b.starts_at = p_starts_at
  ) then
    select * into rec from public.business_bookings b
    where b.business_user_id = p_business_user_id and b.resident_user_id = uid
      and b.status in ('requested', 'confirmed') and b.starts_at = p_starts_at;
    return rec;
  end if;
  insert into public.business_bookings (business_user_id, resident_user_id, starts_at, ends_at, status, resident_note)
  values (p_business_user_id, uid, p_starts_at, p_ends_at, 'requested', nullif(btrim(coalesce(p_note,'')), ''))
  returning * into rec;
  bname := coalesce(acc.business_name, 'העסק');
  perform private.notify_user(p_business_user_id, 'booking_requested', 'בקשת תור חדשה', 'תושב/ת ביקש/ה תור אצל «' || bname || '».', jsonb_build_object('booking_id', rec.id));
  return rec;
end $$;
revoke all on function public.request_business_slot(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.request_business_slot(uuid, timestamptz, timestamptz, text) to authenticated;

create or replace function public.cancel_my_business_booking(p_id uuid)
returns public.business_bookings
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  rec public.business_bookings;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  select * into rec from public.business_bookings b where b.id = p_id and b.resident_user_id = uid for update;
  if rec.id is null then raise exception 'not found' using errcode = '42501'; end if;
  if rec.status not in ('requested', 'confirmed') then raise exception 'not cancellable' using errcode = '22023'; end if;
  if rec.starts_at <= now() then raise exception 'already started' using errcode = '22023'; end if;
  update public.business_bookings set status = 'cancelled', updated_at = now() where id = rec.id returning * into rec;
  perform private.notify_user(rec.business_user_id, 'booking_cancelled', 'תור בוטל', 'תושב/ת ביטל/ה תור.', jsonb_build_object('booking_id', rec.id));
  return rec;
end $$;
revoke all on function public.cancel_my_business_booking(uuid) from public, anon;
grant execute on function public.cancel_my_business_booking(uuid) to authenticated;

create or replace function public.list_my_business_bookings()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.id,
      'business_user_id', b.business_user_id,
      'business_name', a.business_name,
      'starts_at', b.starts_at,
      'ends_at', b.ends_at,
      'status', b.status,
      'kind', 'business'
    ) order by b.starts_at)
    from public.business_bookings b
    join public.business_accounts a on a.user_id = b.business_user_id
    where b.resident_user_id = uid and b.status in ('requested', 'confirmed') and b.ends_at >= now() - interval '1 day'
  ), '[]'::jsonb);
end $$;
revoke all on function public.list_my_business_bookings() from public, anon;
grant execute on function public.list_my_business_bookings() to authenticated;

create or replace function public.my_notifications()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  return jsonb_build_object(
    'unread', (select count(*) from public.app_notifications n where n.user_id = uid and n.read_at is null),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'payload', n.payload,
        'read_at', n.read_at, 'created_at', n.created_at
      ) order by n.created_at desc)
      from (
        select * from public.app_notifications n where n.user_id = uid order by n.created_at desc limit 30
      ) n
    ), '[]'::jsonb)
  );
end $$;
revoke all on function public.my_notifications() from public, anon;
grant execute on function public.my_notifications() to authenticated;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns integer
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); n int;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if p_ids is null then
    update public.app_notifications set read_at = now() where user_id = uid and read_at is null;
  else
    update public.app_notifications set read_at = now() where user_id = uid and read_at is null and id = any(p_ids);
  end if;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

-- ---------- מה כלול במסלולים ----------
-- קהילה: הרשמה/פרסום קורסים וסדנאות (010). בלי יומן עסק.
-- אהבה (חודשי/שנתי): מועדי קורס/סדנה + יומן עסק פנימי ו-ics.
-- פרו: כל מה שבאהבה + סנכרון דו-כיווני עם גוגל יומן (בקרוב).
-- מייסד: יורש את פרו.

update public.pricing_plans
   set features = '[
      {"text":"צפייה מלאה וחיפוש חכם ב«שאלו את נחת»"},
      {"text":"פרסומים קהילתיים קצרים (טרמפים, מסירות/יד שנייה, עזרה, אירועים חינמיים) ותגובות"},
      {"text":"ניהול פרסומים פתוחים מהבית"},
      {"text":"הרשמה לקורסים, סדנאות ומפגשים עם מועדים בקהילה"},
      {"text":"פרסום קורס או סדנה עם מועדים (אחרי אישור צוות)"}
    ]'::jsonb
 where family = 'community';

update public.pricing_plans
   set features = '[
      {"text":"כל מה שבמסלול הקהילה"},
      {"text":"דף עסק מלא בקטגוריות ובתשובות «שאלו את נחת»"},
      {"text":"פרסום אירועים, סדנאות בתשלום ומבצעים באירועים הקרובים"},
      {"text":"פרסום קורסים וסדנאות עם מועדים, הרשמה ומקום פנוי בזמן אמת"},
      {"text":"יומן עסק פנימי: שעות פעילות, אירועים ותורים. תושבים רואים זמינות ומבקשים תור, ואתם מאשרים באפליקציה"},
      {"text":"כפתור «הוסף ליומן שלי» — קובץ ‎.ics שעובד בגוגל ובאפל, בלי הרשאות"},
      {"text":"שעות פתיחה חיות ברצועת «פתוח עכשיו / קורה היום»"},
      {"text":"כפתור יצירת קשר ישיר בוואטסאפ או בטלפון"}
    ]'::jsonb
 where family = 'business';

update public.pricing_plans
   set features = '[
      {"text":"כל מה שבמסלול אהבה"},
      {"text":"סנכרון דו-כיווני עם גוגל יומן","soon":true},
      {"text":"סטודיו AI לתמונות ועיצוב (Mac Studio)","soon":true},
      {"text":"אחסון אישי 64GB","soon":true},
      {"text":"מסנן רעש למייל עם כתובת העברה אישית בדומיין הקהילה (התראות דחופות לוואטסאפ, סיכום יומי, השתקת ניוזלטרים)","soon":true},
      {"text":"תיוק אוטומטי ב-OCR של חשבוניות וקבלות","soon":true},
      {"text":"יצירת תוכן ב-AI ותרגום לאנגלית","soon":true}
    ]'::jsonb
 where family = 'pro';

update public.pricing_plans
   set features = '[
      {"text":"כל מה שבמסלול פרו"},
      {"text":"פגישת התנעה של 45 דקות עם רן, כולל ראיון AI באפליקציה להכנת תוכנית פעולה","soon":true},
      {"text":"עד 3 פגישות המשך בשנה בהנחת מייסד","soon":true},
      {"text":"אחסון אישי 128GB","soon":true},
      {"text":"תג «מייסד» ו«זרקור מייסדים» (בלי להטות את החיפוש האורגני)","soon":true},
      {"text":"גישה מוקדמת","soon":true}
    ]'::jsonb
 where family = 'founder';
