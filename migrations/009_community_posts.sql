-- 009: פרסומי תושבים, community_id, ותפקיד מנהל/ת קהילה.
-- קובץ זה מוכן ליישום אחרי אישור רן בלבד. לא הוחל על המסד.

-- ========== יישוב ==========
alter table public.places add column if not exists community_id text not null default 'your-community';
alter table public.events add column if not exists community_id text not null default 'your-community';
create index if not exists places_community_idx on public.places (community_id, status);
create index if not exists events_community_idx on public.events (community_id, status);

-- ========== תושבים (לאישור מנהל/ת קהילה) ==========
create table if not exists public.residents (
  user_id uuid primary key references auth.users(id) on delete cascade,
  community_id text not null default 'your-community',
  status text not null default 'pending' check (status in ('pending','verified','rejected')),
  request_note text,
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
create index if not exists residents_community_status_idx on public.residents (community_id, status);
alter table public.residents enable row level security;

-- אין יצירת תושב אוטומטית בפרופיל חדש. התושב/ת לוחץ/ת «בקשת אימות תושב» (request_resident_verification).
drop trigger if exists profiles_after_insert_resident on public.profiles;
drop function if exists private.profiles_after_insert_resident();

create or replace function private.is_verified_resident() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.residents r where r.user_id = (select auth.uid()) and r.status = 'verified') $$;
revoke all on function private.is_verified_resident() from public, anon;
grant execute on function private.is_verified_resident() to authenticated;

-- ========== פרסומים, תגובות, סימון קריאה ==========
create table if not exists public.posts (
  id text primary key default ('pst-'::text || substr((gen_random_uuid())::text, 1, 8)),
  community_id text not null default 'your-community',
  author_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  type text not null check (type in ('ride','giveaway','help','recommend')),
  title text not null,
  body text,
  status text not null default 'pending' check (status in ('pending','open','closed','hidden','rejected')),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  review_note text,
  version integer not null default 1
);
create index if not exists posts_feed_idx on public.posts (community_id, status, created_at desc);
create index if not exists posts_author_idx on public.posts (author_id, status);

create table if not exists public.post_replies (
  id bigint generated always as identity primary key,
  post_id text not null references public.posts(id) on delete cascade,
  author_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null,
  status text not null default 'published' check (status in ('published','pending','hidden','rejected')),
  created_at timestamptz not null default now()
);
create index if not exists post_replies_post_idx on public.post_replies (post_id, created_at);

create table if not exists public.post_reads (
  user_id uuid not null references auth.users(id) on delete cascade,
  post_id text not null references public.posts(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

alter table public.posts enable row level security;
alter table public.post_replies enable row level security;
alter table public.post_reads enable row level security;

-- ========== מנהל/ת קהילה ==========
create table if not exists private.managers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now(),
  added_by uuid references auth.users(id) on delete set null
);
alter table private.managers enable row level security;
revoke all on private.managers from public, anon, authenticated;

create or replace function private.is_manager() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from private.managers m where m.user_id = (select auth.uid())) $$;
revoke all on function private.is_manager() from public, anon;
grant execute on function private.is_manager() to authenticated;

create or replace function private.is_staff() returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce((select private.is_admin()), false) or coalesce((select private.is_manager()), false) $$;
revoke all on function private.is_staff() from public, anon;
grant execute on function private.is_staff() to authenticated;

-- ========== טריגרים ויומן ==========
create or replace function private.posts_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.author_id := coalesce(new.author_id, (select auth.uid()));
    new.community_id := coalesce(nullif(new.community_id, ''), 'your-community');
    new.created_at := now();
    new.updated_at := now();
    new.version := 1;
    -- מחבר לא יכול לפרסם ישירות; רק ממתין. צוות יכול לאשר מיד.
    if not coalesce((select private.is_staff()), false) then
      new.status := 'pending';
    end if;
    return new;
  end if;
  new.id := old.id;
  new.author_id := old.author_id;
  new.community_id := old.community_id;
  new.created_at := old.created_at;
  new.version := old.version + 1;
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  if not coalesce((select private.is_staff()), false) then
    -- מחבר: רק סגירה, או עדכון תוכן כשהוא עדיין ממתין
    if new.status not in ('pending','open','closed') then
      raise exception 'not allowed' using errcode = '42501';
    end if;
    if old.status = 'open' and new.status not in ('open','closed') then
      raise exception 'not allowed' using errcode = '42501';
    end if;
    if old.status = 'pending' and new.status not in ('pending','closed') then
      raise exception 'not allowed' using errcode = '42501';
    end if;
    if old.status in ('hidden','rejected','closed') and new.status is distinct from old.status then
      raise exception 'not allowed' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists posts_before_write on public.posts;
create trigger posts_before_write before insert or update on public.posts
  for each row execute function private.posts_before_write();

create or replace function private.posts_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_log (actor, action, entity, entity_id, before, after)
  values ((select auth.uid()), lower(tg_op), 'posts', coalesce(new.id, old.id),
          case when tg_op = 'INSERT' then null else to_jsonb(old) end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) end);
  return coalesce(new, old);
end $$;
drop trigger if exists posts_audit on public.posts;
create trigger posts_audit after insert or update or delete on public.posts
  for each row execute function private.posts_audit();

create or replace function private.replies_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_log (actor, action, entity, entity_id, before, after)
  values ((select auth.uid()), lower(tg_op), 'post_replies', coalesce(new.id, old.id)::text,
          case when tg_op = 'INSERT' then null else to_jsonb(old) end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) end);
  return coalesce(new, old);
end $$;
drop trigger if exists replies_audit on public.post_replies;
create trigger replies_audit after insert or update or delete on public.post_replies
  for each row execute function private.replies_audit();

create or replace function private.residents_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_log (actor, action, entity, entity_id, before, after)
  values ((select auth.uid()), lower(tg_op), 'residents', coalesce(new.user_id, old.user_id)::text,
          case when tg_op = 'INSERT' then null else to_jsonb(old) end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) end);
  return coalesce(new, old);
end $$;
-- audit after; updated_at on before
create or replace function private.residents_before_update() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.user_id := old.user_id;
  new.community_id := old.community_id;
  new.created_at := old.created_at;
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  return new;
end $$;
drop trigger if exists residents_before_update on public.residents;
create trigger residents_before_update before update on public.residents
  for each row execute function private.residents_before_update();
drop trigger if exists residents_audit on public.residents;
create trigger residents_audit after insert or update or delete on public.residents
  for each row execute function private.residents_audit();

create or replace function private.managers_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_log (actor, action, entity, entity_id, before, after)
  values ((select auth.uid()), lower(tg_op), 'managers', coalesce(new.user_id, old.user_id)::text,
          case when tg_op = 'INSERT' then null else to_jsonb(old) end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) end);
  return coalesce(new, old);
end $$;
drop trigger if exists managers_audit on private.managers;
create trigger managers_audit after insert or update or delete on private.managers
  for each row execute function private.managers_audit();

-- ========== RLS ==========
-- תושבים: המשתמש רואה את עצמו; צוות רואה הכל. אין כתיבה ישירה — רק דרך RPC.
drop policy if exists residents_select_own_or_staff on public.residents;
create policy residents_select_own_or_staff on public.residents for select to authenticated
  using (user_id = (select auth.uid()) or coalesce((select private.is_staff()), false));

-- פרסומים: ציבור רואה פתוחים ולא פגי־תוקף; מחבר רואה את שלו; צוות רואה הכל.
drop policy if exists posts_select_public on public.posts;
create policy posts_select_public on public.posts for select to anon, authenticated
  using (
    (status = 'open' and (expires_at is null or expires_at > now()))
    or (select auth.uid()) = author_id
    or coalesce((select private.is_staff()), false)
  );
drop policy if exists posts_insert_resident on public.posts;
create policy posts_insert_resident on public.posts for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and exists (select 1 from public.residents r where r.user_id = (select auth.uid()) and r.status = 'verified')
  );
drop policy if exists posts_update_author_or_staff on public.posts;
create policy posts_update_author_or_staff on public.posts for update to authenticated
  using (author_id = (select auth.uid()) or coalesce((select private.is_staff()), false))
  with check (author_id = (select auth.uid()) or coalesce((select private.is_staff()), false));
-- אין מדיניות DELETE: אף אחד (כולל מנהל/ת קהילה) לא מוחק פרסומים דרך RLS. אדמין יכול דרך SQL בשרת בלבד.

drop policy if exists replies_select on public.post_replies;
create policy replies_select on public.post_replies for select to anon, authenticated
  using (
    status = 'published'
    or author_id = (select auth.uid())
    or exists (select 1 from public.posts p where p.id = post_id and p.author_id = (select auth.uid()))
    or coalesce((select private.is_staff()), false)
  );
drop policy if exists replies_insert on public.post_replies;
create policy replies_insert on public.post_replies for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and exists (select 1 from public.posts p where p.id = post_id and p.status = 'open'
      and (p.expires_at is null or p.expires_at > now()))
  );
drop policy if exists replies_update_staff on public.post_replies;
create policy replies_update_staff on public.post_replies for update to authenticated
  using (coalesce((select private.is_staff()), false) or author_id = (select auth.uid()))
  with check (coalesce((select private.is_staff()), false) or author_id = (select auth.uid()));

drop policy if exists reads_own on public.post_reads;
create policy reads_own on public.post_reads for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

grant select on public.posts, public.post_replies to anon, authenticated;
grant select, insert, update on public.posts to authenticated;
grant select, insert, update on public.post_replies to authenticated;
grant select, insert, update, delete on public.post_reads to authenticated;
grant select on public.residents to authenticated;
-- אין grant delete על places/events/posts

-- ========== עדכון פונקציות אדמין קיימות: צוות (אדמין או מנהל/ת קהילה) ==========
create or replace function public.admin_whoami() returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare adm boolean := coalesce((select private.is_admin()), false);
        mgr boolean := coalesce((select private.is_manager()), false);
begin
  return jsonb_build_object(
    'is_admin', adm,
    'is_manager', mgr,
    'role', case when adm then 'admin' when mgr then 'manager' else null end,
    'email', (select auth.jwt() ->> 'email')
  );
end $$;

create or replace function public.admin_list_places() returns setof public.places
language plpgsql stable security invoker set search_path = '' as $$
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query select * from public.places order by name_he;
end $$;

create or replace function public.admin_list_events() returns setof public.events
language plpgsql stable security invoker set search_path = '' as $$
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query select * from public.events order by coalesce(starts_at, start_date::timestamptz) nulls last, title;
end $$;

create or replace function public.admin_set_status(p_kind text, p_ids text[], p_status text, p_reason text default null)
returns integer language plpgsql volatile security invoker set search_path = '' as $$
declare n integer; r text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
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
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
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
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
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

-- כניסת קוד במייל גם למנהל/ת קהילה (בלי לגעת בהגדרות otp_settings)
create or replace function private.admin_uid_for(p_email text) returns uuid
language sql stable security definer set search_path = '' as $$
  select u.id from auth.users u
   where lower(u.email) = lower(trim(p_email))
     and (
       exists (select 1 from private.admins a where a.user_id = u.id)
       or exists (select 1 from private.managers m where m.user_id = u.id)
     )
   limit 1
$$;
revoke all on function private.admin_uid_for(text) from public, anon, authenticated;

-- ========== RPC חדשות לצוות (פרסומים, תגובות, תושבים) ==========
create or replace function public.staff_list_posts() returns setof public.posts
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query select * from public.posts order by created_at desc;
end $$;

create or replace function public.staff_list_replies(p_post_id text default null)
returns setof public.post_replies
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  if p_post_id is null then
    return query select * from public.post_replies order by created_at desc;
  end if;
  return query select * from public.post_replies where post_id = p_post_id order by created_at;
end $$;

create or replace function public.staff_set_post_status(p_ids text[], p_status text, p_reason text default null)
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare n integer; r text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  if p_status not in ('pending','open','closed','hidden','rejected') then raise exception 'bad status' using errcode = '22023'; end if;
  if p_status in ('rejected','hidden') and r is null then raise exception 'reason required' using errcode = '22023'; end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 or array_length(p_ids, 1) > 500 then raise exception 'bad ids' using errcode = '22023'; end if;
  update public.posts set status = p_status, review_note = r where id = any(p_ids);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.staff_set_reply_status(p_ids bigint[], p_status text)
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare n integer;
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  if p_status not in ('published','pending','hidden','rejected') then raise exception 'bad status' using errcode = '22023'; end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 or array_length(p_ids, 1) > 500 then raise exception 'bad ids' using errcode = '22023'; end if;
  update public.post_replies set status = p_status where id = any(p_ids);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.staff_list_residents()
returns table (user_id uuid, community_id text, status text, request_note text, review_note text, created_at timestamptz, updated_at timestamptz, display_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query
    select r.user_id, r.community_id, r.status, r.request_note, r.review_note, r.created_at, r.updated_at, p.display_name
    from public.residents r
    left join public.profiles p on p.user_id = r.user_id
    order by r.created_at desc;
end $$;

create or replace function public.staff_set_resident_status(p_ids uuid[], p_status text, p_reason text default null)
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare n integer; r text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not coalesce((select private.is_staff()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  if p_status not in ('pending','verified','rejected') then raise exception 'bad status' using errcode = '22023'; end if;
  if p_status = 'rejected' and r is null then raise exception 'reason required' using errcode = '22023'; end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 or array_length(p_ids, 1) > 500 then raise exception 'bad ids' using errcode = '22023'; end if;
  update public.residents set status = p_status, review_note = r where user_id = any(p_ids);
  get diagnostics n = row_count;
  return n;
end $$;

-- ========== ניהול תפקיד מנהל/ת קהילה — אדמין בלבד ==========
create or replace function public.admin_list_managers()
returns table (user_id uuid, email text, display_name text, added_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query
    select m.user_id, u.email::text, p.display_name, m.added_at
    from private.managers m
    join auth.users u on u.id = m.user_id
    left join public.profiles p on p.user_id = m.user_id
    order by m.added_at;
end $$;

create or replace function public.admin_list_manager_candidates()
returns table (user_id uuid, email text, display_name text, is_manager boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query
    select p.user_id, u.email::text, p.display_name,
           exists (select 1 from private.managers m where m.user_id = p.user_id) as is_manager
    from public.profiles p
    join auth.users u on u.id = p.user_id
    where not exists (select 1 from private.admins a where a.user_id = p.user_id)
    order by coalesce(p.display_name, u.email::text);
end $$;

create or replace function public.admin_grant_manager(p_user uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  if p_user is null then raise exception 'bad user' using errcode = '22023'; end if;
  if exists (select 1 from private.admins a where a.user_id = p_user) then
    raise exception 'cannot grant manager to an admin' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p where p.user_id = p_user) then
    raise exception 'user has no profile' using errcode = '22023';
  end if;
  insert into private.managers (user_id, added_by) values (p_user, (select auth.uid()))
  on conflict (user_id) do nothing;
end $$;

create or replace function public.admin_revoke_manager(p_user uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  if exists (select 1 from private.admins a where a.user_id = p_user) then
    raise exception 'cannot revoke an admin' using errcode = '42501';
  end if;
  delete from private.managers where user_id = p_user;
end $$;

revoke all on function public.staff_list_posts(), public.staff_list_replies(text),
  public.staff_set_post_status(text[], text, text), public.staff_set_reply_status(bigint[], text),
  public.staff_list_residents(), public.staff_set_resident_status(uuid[], text, text),
  public.admin_list_managers(), public.admin_list_manager_candidates(),
  public.admin_grant_manager(uuid), public.admin_revoke_manager(uuid)
  from public, anon;
grant execute on function public.staff_list_posts(), public.staff_list_replies(text),
  public.staff_set_post_status(text[], text, text), public.staff_set_reply_status(bigint[], text),
  public.staff_list_residents(), public.staff_set_resident_status(uuid[], text, text)
  to authenticated;
grant execute on function public.admin_list_managers(), public.admin_list_manager_candidates(),
  public.admin_grant_manager(uuid), public.admin_revoke_manager(uuid)
  to authenticated;

-- מחבר: סגירת פרסום פתוח משלו (גם בלי להיות צוות)
create or replace function public.close_own_post(p_id text) returns public.posts
language plpgsql volatile security invoker set search_path = '' as $$
declare res public.posts;
begin
  update public.posts set status = 'closed'
   where id = p_id and author_id = (select auth.uid()) and status = 'open'
  returning * into res;
  if res.id is null then raise exception 'not found' using errcode = '42501'; end if;
  return res;
end $$;
revoke all on function public.close_own_post(text) from public, anon;
grant execute on function public.close_own_post(text) to authenticated;
