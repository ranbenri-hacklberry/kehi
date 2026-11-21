-- 010: מושבי קורס/סדנה והרשמה של תושבות/ים מאומתות/ים.
-- תלוי ב-009 (טבלת posts, תושבים עם status=verified, מנהל/ת קהילה).
-- קובץ זה מוכן ליישום אחרי אישור רן בלבד. לא הוחל על המסד.

-- סוג פרסום חדש
alter table public.posts drop constraint if exists posts_type_check;
alter table public.posts add constraint posts_type_check
  check (type in ('ride','giveaway','help','recommend','course'));

create table if not exists public.post_slots (
  id bigint generated always as identity primary key,
  post_id text not null references public.posts(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  capacity integer not null check (capacity > 0 and capacity <= 500),
  location text,
  note text,
  created_at timestamptz not null default now(),
  constraint post_slots_time_chk check (ends_at > starts_at)
);
create index if not exists post_slots_post_idx on public.post_slots (post_id, starts_at);

create table if not exists public.slot_bookings (
  id bigint generated always as identity primary key,
  slot_id bigint not null references public.post_slots(id) on delete cascade,
  resident_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'booked' check (status in ('booked','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists slot_bookings_one_active
  on public.slot_bookings (slot_id, resident_id) where status = 'booked';
create unique index if not exists slot_bookings_pair
  on public.slot_bookings (slot_id, resident_id);
create index if not exists slot_bookings_resident_idx on public.slot_bookings (resident_id, status);

alter table public.post_slots enable row level security;
alter table public.slot_bookings enable row level security;
revoke all on public.post_slots, public.slot_bookings from public, anon, authenticated;
grant select on public.post_slots to anon, authenticated;
grant select, insert, update, delete on public.post_slots to authenticated;
grant select on public.slot_bookings to authenticated;
-- אין grant insert/update ישיר על הרשמות: רק דרך RPC.

-- יומן
create or replace function private.slots_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_log (actor, action, entity, entity_id, before, after)
  values ((select auth.uid()), lower(tg_op), 'post_slots', coalesce(new.id, old.id)::text,
          case when tg_op = 'INSERT' then null else to_jsonb(old) end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) end);
  return coalesce(new, old);
end $$;
drop trigger if exists slots_audit on public.post_slots;
create trigger slots_audit after insert or update or delete on public.post_slots
  for each row execute function private.slots_audit();

create or replace function private.bookings_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_log (actor, action, entity, entity_id, before, after)
  values ((select auth.uid()), lower(tg_op), 'slot_bookings', coalesce(new.id, old.id)::text,
          case when tg_op = 'INSERT' then null else to_jsonb(old) end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) end);
  return coalesce(new, old);
end $$;
drop trigger if exists bookings_audit on public.slot_bookings;
create trigger bookings_audit after insert or update or delete on public.slot_bookings
  for each row execute function private.bookings_audit();

create or replace function private.bookings_before_update() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.id := old.id;
  new.slot_id := old.slot_id;
  new.resident_id := old.resident_id;
  new.created_at := old.created_at;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists bookings_before_update on public.slot_bookings;
create trigger bookings_before_update before update on public.slot_bookings
  for each row execute function private.bookings_before_update();

-- RLS: מושבים נראים בפרסום פתוח, או למחבר/צוות. כתיבה למחבר או צוות.
drop policy if exists slots_select on public.post_slots;
create policy slots_select on public.post_slots for select to anon, authenticated
  using (
    exists (
      select 1 from public.posts p
      where p.id = post_id
        and (
          (p.status = 'open' and (p.expires_at is null or p.expires_at > now()))
          or p.author_id = (select auth.uid())
          or coalesce((select private.is_staff()), false)
        )
    )
  );
drop policy if exists slots_write_author_or_staff on public.post_slots;
create policy slots_write_author_or_staff on public.post_slots for all to authenticated
  using (
    exists (select 1 from public.posts p where p.id = post_id and (p.author_id = (select auth.uid()) or coalesce((select private.is_staff()), false)))
  )
  with check (
    exists (select 1 from public.posts p where p.id = post_id and (p.author_id = (select auth.uid()) or coalesce((select private.is_staff()), false)))
  );

-- הרשמות: הרושם רואה את שלו; מחבר הפרסום והצוות רואים את כל הרשימה. אין כתיבה ישירה.
drop policy if exists bookings_select_own_author_staff on public.slot_bookings;
create policy bookings_select_own_author_staff on public.slot_bookings for select to authenticated
  using (
    resident_id = (select auth.uid())
    or coalesce((select private.is_staff()), false)
    or exists (
      select 1 from public.post_slots s
      join public.posts p on p.id = s.post_id
      where s.id = slot_id and p.author_id = (select auth.uid())
    )
  );

-- ========== RPC ==========
create or replace function public.list_post_slots(p_post text)
returns table (
  id bigint, post_id text, starts_at timestamptz, ends_at timestamptz,
  capacity integer, location text, note text,
  remaining integer, mine_status text
)
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if p_post is null then raise exception 'bad id' using errcode = '22023'; end if;
  if not exists (
    select 1 from public.posts p
    where p.id = p_post
      and (
        (p.status = 'open' and (p.expires_at is null or p.expires_at > now()))
        or p.author_id = uid
        or coalesce((select private.is_staff()), false)
      )
  ) then
    raise exception 'not found' using errcode = '42501';
  end if;
  return query
    select s.id, s.post_id, s.starts_at, s.ends_at, s.capacity, s.location, s.note,
           greatest(s.capacity - (select count(*)::int from public.slot_bookings b where b.slot_id = s.id and b.status = 'booked'), 0) as remaining,
           (select b.status from public.slot_bookings b where b.slot_id = s.id and b.resident_id = uid and b.status = 'booked' limit 1) as mine_status
    from public.post_slots s
    where s.post_id = p_post
    order by s.starts_at;
end $$;

create or replace function public.list_course_attendees(p_post text)
returns table (
  slot_id bigint, starts_at timestamptz, ends_at timestamptz,
  booking_id bigint, resident_id uuid, display_name text, booked_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if not exists (
    select 1 from public.posts p
    where p.id = p_post
      and (p.author_id = uid or coalesce((select private.is_staff()), false))
  ) then
    raise exception 'not author' using errcode = '42501';
  end if;
  return query
    select s.id, s.starts_at, s.ends_at, b.id, b.resident_id,
           coalesce(p.display_name, 'תושב/ת'), b.created_at
    from public.post_slots s
    join public.slot_bookings b on b.slot_id = s.id and b.status = 'booked'
    left join public.profiles p on p.user_id = b.resident_id
    where s.post_id = p_post
    order by s.starts_at, b.created_at;
end $$;

create or replace function public.list_my_bookings()
returns table (
  booking_id bigint, slot_id bigint, post_id text, title text,
  starts_at timestamptz, ends_at timestamptz, location text,
  status text, created_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  return query
    select b.id, s.id, s.post_id, p.title, s.starts_at, s.ends_at, s.location, b.status, b.created_at
    from public.slot_bookings b
    join public.post_slots s on s.id = b.slot_id
    join public.posts p on p.id = s.post_id
    where b.resident_id = uid
    order by s.starts_at;
end $$;

create or replace function public.book_slot(p_slot bigint)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  sl public.post_slots;
  pst public.posts;
  taken integer;
  bid bigint;
  rec public.slot_bookings;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if not coalesce((select private.is_verified_resident()), false) then
    raise exception 'not verified' using errcode = '42501';
  end if;
  if p_slot is null then raise exception 'bad slot' using errcode = '22023'; end if;

  select * into sl from public.post_slots where id = p_slot for update;
  if sl.id is null then raise exception 'not found' using errcode = '42501'; end if;
  select * into pst from public.posts where id = sl.post_id;
  if pst.id is null or pst.status <> 'open' or (pst.expires_at is not null and pst.expires_at <= now()) then
    raise exception 'not open' using errcode = '22023';
  end if;

  select count(*)::int into taken from public.slot_bookings where slot_id = p_slot and status = 'booked';
  select * into rec from public.slot_bookings where slot_id = p_slot and resident_id = uid;
  if rec.id is not null and rec.status = 'booked' then
    -- כבר רשום/ה
    return jsonb_build_object('booking_id', rec.id, 'slot_id', p_slot, 'status', 'booked',
      'remaining', greatest(sl.capacity - taken, 0));
  end if;
  if taken >= sl.capacity then raise exception 'full' using errcode = 'P0001'; end if;

  if rec.id is not null then
    update public.slot_bookings set status = 'booked' where id = rec.id returning id into bid;
  else
    insert into public.slot_bookings (slot_id, resident_id, status)
    values (p_slot, uid, 'booked')
    returning id into bid;
  end if;

  return jsonb_build_object('booking_id', bid, 'slot_id', p_slot, 'status', 'booked',
    'remaining', greatest(sl.capacity - taken - 1, 0));
end $$;

create or replace function public.cancel_booking(p_slot bigint)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  n integer;
  taken integer;
  cap integer;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if p_slot is null then raise exception 'bad slot' using errcode = '22023'; end if;
  update public.slot_bookings set status = 'cancelled'
   where slot_id = p_slot and resident_id = uid and status = 'booked';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'not found' using errcode = '42501'; end if;
  select s.capacity, (select count(*)::int from public.slot_bookings b where b.slot_id = s.id and b.status = 'booked')
    into cap, taken
    from public.post_slots s where s.id = p_slot;
  return jsonb_build_object('slot_id', p_slot, 'status', 'cancelled', 'remaining', greatest(cap - taken, 0));
end $$;

-- צוות יכול לבטל הרשמה (מודרציה)
create or replace function public.staff_cancel_booking(p_booking bigint)
returns integer
language plpgsql volatile security definer set search_path = '' as $$
declare n integer;
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  update public.slot_bookings set status = 'cancelled' where id = p_booking and status = 'booked';
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.create_course_post(p_title text, p_body text, p_slots jsonb, p_expires_at timestamptz default null)
returns public.posts
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  rec public.posts;
  el jsonb;
  st timestamptz; en timestamptz; cap integer;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if not coalesce((select private.is_verified_resident()), false) then
    raise exception 'not verified' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null then raise exception 'title required' using errcode = '22023'; end if;
  if p_slots is null or jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) < 1 or jsonb_array_length(p_slots) > 50 then
    raise exception 'slots required' using errcode = '22023';
  end if;

  insert into public.posts (community_id, author_id, type, title, body, status, expires_at)
  values (
    coalesce((select r.community_id from public.residents r where r.user_id = uid), 'your-community'),
    uid, 'course', btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), 'pending', p_expires_at
  ) returning * into rec;

  for el in select * from jsonb_array_elements(p_slots)
  loop
    st := (el->>'starts_at')::timestamptz;
    en := (el->>'ends_at')::timestamptz;
    cap := (el->>'capacity')::integer;
    if st is null or en is null or en <= st or cap is null then
      raise exception 'bad slot' using errcode = '22023';
    end if;
    insert into public.post_slots (post_id, starts_at, ends_at, capacity, location, note)
    values (rec.id, st, en, cap, nullif(btrim(coalesce(el->>'location','')), ''), nullif(btrim(coalesce(el->>'note','')), ''));
  end loop;
  return rec;
end $$;

revoke all on function
  public.list_post_slots(text), public.list_course_attendees(text), public.list_my_bookings(),
  public.book_slot(bigint), public.cancel_booking(bigint), public.staff_cancel_booking(bigint),
  public.create_course_post(text, text, jsonb, timestamptz)
  from public, anon;
grant execute on function
  public.list_post_slots(text), public.list_my_bookings(),
  public.book_slot(bigint), public.cancel_booking(bigint),
  public.create_course_post(text, text, jsonb, timestamptz)
  to authenticated;
-- list_post_slots also useful for published open posts to anon? remaining seats are public. grant to anon too.
grant execute on function public.list_post_slots(text) to anon, authenticated;
grant execute on function public.list_course_attendees(text), public.staff_cancel_booking(bigint) to authenticated;
