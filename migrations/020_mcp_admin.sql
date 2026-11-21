-- 020: שרת MCP לאדמינים. יומן פעולות MCP ופונקציות ניהול נוספות.
-- כל הפונקציות כאן: security definer, search_path ריק, ובודקות private.is_admin() (לא רק staff).
-- השרת קורא להן עם ה-JWT של האדמין המחובר ומפתח ה-anon בלבד. אין service_role בשרת.

-- ========== יומן פעולות MCP ==========
create table if not exists private.mcp_audit (
  id bigint generated always as identity primary key,
  actor uuid not null,
  actor_email text,
  tool text not null,
  args jsonb,
  at timestamptz not null default now()
);
create index if not exists mcp_audit_at_idx on private.mcp_audit (at desc);
alter table private.mcp_audit enable row level security;
revoke all on table private.mcp_audit from public, anon, authenticated;

create or replace function private.require_admin()
returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null or not coalesce((select private.is_admin()), false) then
    raise exception 'not admin' using errcode = '42501';
  end if;
  return uid;
end $$;
revoke all on function private.require_admin() from public, anon, authenticated;

create or replace function public.mcp_log(p_tool text, p_args jsonb default null)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_admin(); nid bigint; a jsonb := p_args;
begin
  if nullif(btrim(coalesce(p_tool, '')), '') is null or length(p_tool) > 80 then
    raise exception 'bad tool' using errcode = '22023';
  end if;
  -- תקציר בלבד: מגבילים את הגודל.
  if a is not null and length(a::text) > 4000 then
    a := jsonb_build_object('truncated', true, 'preview', left(a::text, 4000));
  end if;
  insert into private.mcp_audit (actor, actor_email, tool, args)
  values (uid, (select auth.jwt() ->> 'email'), btrim(p_tool), a)
  returning id into nid;
  return nid;
end $$;

create or replace function public.mcp_audit_list(p_limit integer default 50, p_tool text default null)
returns table (id bigint, actor uuid, actor_email text, tool text, args jsonb, at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return query
    select m.id, m.actor, m.actor_email, m.tool, m.args, m.at
      from private.mcp_audit m
     where p_tool is null or m.tool = p_tool
     order by m.at desc
     limit least(greatest(coalesce(p_limit, 50), 1), 500);
end $$;

-- ========== מקומות ==========
create or replace function public.mcp_admin_get_place(p_id text)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare pl public.places; res jsonb;
begin
  perform private.require_admin();
  select * into pl from public.places where id = p_id;
  if pl.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  res := jsonb_build_object(
    'place', to_jsonb(pl),
    'suggestions', coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc)
                               from public.place_suggestions s where s.place_id = p_id), '[]'::jsonb),
    'business_accounts', coalesce((select jsonb_agg(jsonb_build_object(
                               'user_id', b.user_id, 'business_name', b.business_name,
                               'claim_status', b.claim_status, 'status', b.status,
                               'subscription_tier', b.subscription_tier, 'is_comp', b.is_comp,
                               'linked_as', case when b.place_id = p_id then 'approved' else 'pending' end))
                               from public.business_accounts b
                              where b.place_id = p_id or b.pending_place_id = p_id), '[]'::jsonb)
  );
  return res;
end $$;

create or replace function public.mcp_admin_update_place_links(p_id text, p_patch jsonb)
returns public.places
language plpgsql security definer set search_path = '' as $$
declare res public.places; bad text;
begin
  perform private.require_admin();
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'bad patch' using errcode = '22023'; end if;
  select string_agg(k, ',') into bad from jsonb_object_keys(p_patch) k
   where k not in ('name_en','maps_url','google_maps_url','facebook_url','instagram_url','source_urls','lat','lng','hours_status','last_verified');
  if bad is not null then raise exception 'field not editable: %', bad using errcode = '22023'; end if;
  update public.places p set
    name_en         = case when p_patch ? 'name_en' then nullif(btrim(p_patch->>'name_en'), '') else p.name_en end,
    maps_url        = case when p_patch ? 'maps_url' then nullif(btrim(p_patch->>'maps_url'), '') else p.maps_url end,
    google_maps_url = case when p_patch ? 'google_maps_url' then nullif(btrim(p_patch->>'google_maps_url'), '') else p.google_maps_url end,
    facebook_url    = case when p_patch ? 'facebook_url' then nullif(btrim(p_patch->>'facebook_url'), '') else p.facebook_url end,
    instagram_url   = case when p_patch ? 'instagram_url' then nullif(btrim(p_patch->>'instagram_url'), '') else p.instagram_url end,
    source_urls     = case when p_patch ? 'source_urls' then
                        (select array_agg(x) from jsonb_array_elements_text(coalesce(p_patch->'source_urls', '[]'::jsonb)) x where btrim(x) <> '')
                      else p.source_urls end,
    lat             = case when p_patch ? 'lat' then (p_patch->>'lat')::double precision else p.lat end,
    lng             = case when p_patch ? 'lng' then (p_patch->>'lng')::double precision else p.lng end,
    hours_status    = case when p_patch ? 'hours_status' then nullif(btrim(p_patch->>'hours_status'), '') else p.hours_status end,
    last_verified   = case when p_patch ? 'last_verified' then (p_patch->>'last_verified')::date else p.last_verified end
  where p.id = p_id
  returning * into res;
  if res.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  return res;
end $$;

-- ========== משתמשים ==========
create or replace function public.mcp_admin_list_users(p_search text default null, p_limit integer default 200)
returns table (
  user_id uuid, email text, display_name text, created_at timestamptz, last_sign_in_at timestamptz,
  is_admin boolean, is_manager boolean, resident_status text, business_name text,
  subscription_tier text, business_status text, is_comp boolean
)
language plpgsql stable security definer set search_path = '' as $$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform private.require_admin();
  return query
    select u.id, u.email::text, pr.display_name, u.created_at, u.last_sign_in_at,
           exists (select 1 from private.admins a where a.user_id = u.id),
           exists (select 1 from private.managers m where m.user_id = u.id),
           r.status, b.business_name, b.subscription_tier, b.status, b.is_comp
      from auth.users u
      left join public.profiles pr on pr.user_id = u.id
      left join public.residents r on r.user_id = u.id
      left join public.business_accounts b on b.user_id = u.id
     where q is null
        or u.email::text ilike '%' || q || '%'
        or coalesce(pr.display_name, '') ilike '%' || q || '%'
        or coalesce(b.business_name, '') ilike '%' || q || '%'
     order by u.created_at desc
     limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end $$;

-- ========== מנויים עסקיים: מתנה (comp) ==========
create or replace function public.mcp_admin_set_business_comp(
  p_user uuid, p_comp boolean, p_tier text default 'pro_monthly', p_reason text default null, p_business_name text default null)
returns public.business_accounts
language plpgsql security definer set search_path = '' as $$
declare rec public.business_accounts; t text := coalesce(nullif(btrim(p_tier), ''), 'pro_monthly');
        nm text; comm text;
begin
  perform private.require_admin();
  if not exists (select 1 from auth.users u where u.id = p_user) then raise exception 'user not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.pricing_plans pp where pp.tier_id = t) then raise exception 'bad tier' using errcode = '22023'; end if;
  select * into rec from public.business_accounts b where b.user_id = p_user;
  if rec.user_id is null then
    if not p_comp then raise exception 'no business account' using errcode = 'P0002'; end if;
    nm := coalesce(nullif(btrim(p_business_name), ''),
                   (select nullif(btrim(pr.display_name), '') from public.profiles pr where pr.user_id = p_user),
                   'עסק');
    comm := coalesce((select r.community_id from public.residents r where r.user_id = p_user), (select private.default_community_id()));
    insert into public.business_accounts (user_id, community_id, business_name, status, subscription_tier, billing_cycle,
                                          is_comp, comp_reason, trial_started_at, trial_ends_at, subscription_expires_at)
    values (p_user, comm, nm, 'active', t, 'yearly', true, coalesce(nullif(btrim(p_reason), ''), 'admin comp'), null, null, null)
    returning * into rec;
    return rec;
  end if;
  if p_comp then
    update public.business_accounts
       set status = 'active', subscription_tier = t, is_comp = true,
           comp_reason = coalesce(nullif(btrim(p_reason), ''), 'admin comp'),
           trial_ends_at = null, subscription_expires_at = null,
           business_name = coalesce(nullif(btrim(p_business_name), ''), business_name)
     where user_id = p_user returning * into rec;
  else
    update public.business_accounts
       set is_comp = false, comp_reason = null, status = 'expired', subscription_expires_at = now()
     where user_id = p_user returning * into rec;
  end if;
  return rec;
end $$;

-- ========== אירועים ==========
create or replace function public.mcp_admin_create_event(p_event jsonb)
returns public.events
language plpgsql security definer set search_path = '' as $$
declare res public.events; bad text; st text := coalesce(nullif(btrim(p_event->>'status'), ''), 'pending_publish');
begin
  perform private.require_admin();
  if p_event is null or jsonb_typeof(p_event) <> 'object' then raise exception 'bad event' using errcode = '22023'; end if;
  select string_agg(k, ',') into bad from jsonb_object_keys(p_event) k
   where k not in ('title','starts_at','ends_at','start_date','when_text','venue_name','venue_place_id','address','price_text','organizer','description','source','status');
  if bad is not null then raise exception 'field not allowed: %', bad using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_event->>'title', '')), '') is null then raise exception 'title required' using errcode = '22023'; end if;
  if st not in ('published','pending_publish','hidden') then raise exception 'bad status' using errcode = '22023'; end if;
  insert into public.events (title, starts_at, ends_at, start_date, when_text, venue_name, venue_place_id, address,
                             price_text, organizer, description, source, status)
  values (btrim(p_event->>'title'),
          (p_event->>'starts_at')::timestamptz, (p_event->>'ends_at')::timestamptz,
          coalesce((p_event->>'start_date')::date, ((p_event->>'starts_at')::timestamptz at time zone 'Asia/Jerusalem')::date),
          nullif(btrim(p_event->>'when_text'), ''), nullif(btrim(p_event->>'venue_name'), ''),
          nullif(btrim(p_event->>'venue_place_id'), ''), nullif(btrim(p_event->>'address'), ''),
          nullif(btrim(p_event->>'price_text'), ''), nullif(btrim(p_event->>'organizer'), ''),
          nullif(btrim(p_event->>'description'), ''),
          coalesce(nullif(btrim(p_event->>'source'), ''), 'mcp:admin'),
          st::public.place_status)
  returning * into res;
  return res;
end $$;

create or replace function public.mcp_admin_delete_event(p_id text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform private.require_admin();
  delete from public.events where id = p_id;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- ========== סלוטים לקורסים וסדנאות ==========
create or replace function public.mcp_admin_upsert_slot(
  p_id bigint, p_post text, p_starts_at timestamptz, p_ends_at timestamptz, p_capacity integer,
  p_location text default null, p_note text default null)
returns public.post_slots
language plpgsql security definer set search_path = '' as $$
declare res public.post_slots; booked integer;
begin
  perform private.require_admin();
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then raise exception 'bad times' using errcode = '22023'; end if;
  if p_capacity is null or p_capacity < 1 or p_capacity > 500 then raise exception 'bad capacity' using errcode = '22023'; end if;
  if p_id is null then
    if not exists (select 1 from public.posts p where p.id = p_post and p.type = 'course') then
      raise exception 'course post not found' using errcode = 'P0002';
    end if;
    insert into public.post_slots (post_id, starts_at, ends_at, capacity, location, note)
    values (p_post, p_starts_at, p_ends_at, p_capacity, nullif(btrim(p_location), ''), nullif(btrim(p_note), ''))
    returning * into res;
  else
    select count(*) into booked from public.slot_bookings b where b.slot_id = p_id and b.status = 'booked';
    if p_capacity < booked then raise exception 'capacity below current bookings (%)', booked using errcode = '22023'; end if;
    update public.post_slots s
       set starts_at = p_starts_at, ends_at = p_ends_at, capacity = p_capacity,
           location = nullif(btrim(p_location), ''), note = nullif(btrim(p_note), '')
     where s.id = p_id
    returning * into res;
    if res.id is null then raise exception 'slot not found' using errcode = 'P0002'; end if;
  end if;
  return res;
end $$;

create or replace function public.mcp_admin_delete_slot(p_id bigint, p_force boolean default false)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare booked integer; n integer;
begin
  perform private.require_admin();
  select count(*) into booked from public.slot_bookings b where b.slot_id = p_id and b.status = 'booked';
  if booked > 0 and not coalesce(p_force, false) then
    raise exception 'slot has % active bookings; pass force to delete', booked using errcode = 'P0001';
  end if;
  delete from public.slot_bookings where slot_id = p_id;
  delete from public.post_slots where id = p_id;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- ========== יומן עסקי: תורים ==========
create or replace function public.mcp_admin_list_business_bookings(
  p_business uuid default null, p_from timestamptz default null, p_to timestamptz default null, p_status text default null)
returns table (
  id uuid, business_user_id uuid, business_name text, resident_user_id uuid, resident_name text,
  starts_at timestamptz, ends_at timestamptz, status text, resident_note text, owner_note text, created_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return query
    select bb.id, bb.business_user_id, ba.business_name, bb.resident_user_id, pr.display_name,
           bb.starts_at, bb.ends_at, bb.status, bb.resident_note, bb.owner_note, bb.created_at
      from public.business_bookings bb
      left join public.business_accounts ba on ba.user_id = bb.business_user_id
      left join public.profiles pr on pr.user_id = bb.resident_user_id
     where (p_business is null or bb.business_user_id = p_business)
       and (p_from is null or bb.ends_at >= p_from)
       and (p_to is null or bb.starts_at <= p_to)
       and (p_status is null or bb.status = p_status)
     order by bb.starts_at
     limit 1000;
end $$;

-- ========== סטטיסטיקה ==========
create or replace function public.mcp_admin_stats()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return jsonb_build_object(
    'places', (select jsonb_object_agg(s, c) from (select status::text s, count(*) c from public.places group by 1) x),
    'events', (select jsonb_object_agg(s, c) from (select status::text s, count(*) c from public.events group by 1) x),
    'posts', (select jsonb_object_agg(s, c) from (select status s, count(*) c from public.posts group by 1) x),
    'residents', (select jsonb_object_agg(s, c) from (select status s, count(*) c from public.residents group by 1) x),
    'users_total', (select count(*) from auth.users),
    'admins', (select count(*) from private.admins),
    'managers', (select count(*) from private.managers),
    'business_accounts', (select jsonb_object_agg(s, c) from (select coalesce(subscription_tier, 'none') || ':' || status s, count(*) c from public.business_accounts group by 1) x),
    'business_claims_pending', (select count(*) from public.business_accounts where claim_status = 'pending'),
    'course_slots_upcoming', (select count(*) from public.post_slots where starts_at > now()),
    'slot_bookings_active', (select count(*) from public.slot_bookings where status = 'booked'),
    'business_bookings', (select jsonb_object_agg(s, c) from (select status s, count(*) c from public.business_bookings group by 1) x),
    'place_suggestions_open', (select count(*) from public.place_suggestions where status = 'open'),
    'generated_at', now()
  );
end $$;

-- ========== הרשאות ==========
do $$
declare f text;
begin
  foreach f in array array[
    'public.mcp_log(text, jsonb)',
    'public.mcp_audit_list(integer, text)',
    'public.mcp_admin_get_place(text)',
    'public.mcp_admin_update_place_links(text, jsonb)',
    'public.mcp_admin_list_users(text, integer)',
    'public.mcp_admin_set_business_comp(uuid, boolean, text, text, text)',
    'public.mcp_admin_create_event(jsonb)',
    'public.mcp_admin_delete_event(text)',
    'public.mcp_admin_upsert_slot(bigint, text, timestamptz, timestamptz, integer, text, text)',
    'public.mcp_admin_delete_slot(bigint, boolean)',
    'public.mcp_admin_list_business_bookings(uuid, timestamptz, timestamptz, text)',
    'public.mcp_admin_stats()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
