-- 018: קישורי מקור/רשתות למקומות, פרו חינם לצוות, אונבורדינג, allowlist למייל צוות.
-- 017 כבר תפוס (cardcom_test_webhook). אין כתובות מייל בקובץ הזה.

-- ========== עמודות קישור למקומות ==========
alter table public.places add column if not exists source_urls text[];
alter table public.places add column if not exists facebook_url text;
alter table public.places add column if not exists instagram_url text;
alter table public.places add column if not exists google_maps_url text;

alter table public.business_accounts add column if not exists is_comp boolean not null default false;
alter table public.business_accounts add column if not exists comp_reason text;

alter table public.profiles add column if not exists onboarded_admin_at timestamptz;
alter table public.profiles add column if not exists onboarded_business_at timestamptz;

create table if not exists private.staff_email_allowlist (
  email text primary key,
  note text,
  added_at timestamptz not null default now(),
  constraint staff_email_allowlist_email_lc check (email = lower(btrim(email)))
);
alter table private.staff_email_allowlist enable row level security;
revoke all on table private.staff_email_allowlist from public, anon, authenticated;

-- ========== חילוץ קישורים מהנתונים הקיימים ==========
create or replace function private.extract_http_urls(p_text text)
returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(distinct u), '{}')
    from (
      select (m)[1] as u
        from regexp_matches(coalesce(p_text, ''), 'https?://[^\s<>\"'']+', 'g') as m
    ) s
   where u is not null
     and u !~* 'tachlis\.co\.il';
$$;
revoke all on function private.extract_http_urls(text) from public, anon, authenticated;

create or replace function private.backfill_place_links(p_id text default null)
returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer := 0;
  rec record;
  urls text[];
  fb text; ig text; gmaps text; u text;
begin
  for rec in
    select * from public.places p
     where p_id is null or p.id = p_id
  loop
    urls := '{}';
    urls := urls || private.extract_http_urls(rec.source);
    urls := urls || private.extract_http_urls(rec.note);
    urls := urls || private.extract_http_urls(rec.website);
    urls := urls || private.extract_http_urls(rec.maps_url);
    urls := urls || private.extract_http_urls(coalesce(rec.sources::text, ''));
    -- ייחוד וסינון תאכלס
    select coalesce(array_agg(distinct x), '{}') into urls
      from unnest(urls) x
     where x is not null and x !~* 'tachlis\.co\.il';

    fb := rec.facebook_url;
    ig := rec.instagram_url;
    gmaps := rec.google_maps_url;
    if gmaps is null and rec.maps_url ~* 'google\.[^[:space:]]*maps|maps\.google|goo\.gl/maps|maps\.app\.goo\.gl' then
      gmaps := rec.maps_url;
    end if;
    foreach u in array urls loop
      if fb is null and u ~* 'facebook\.com|//fb\.com|//www\.fb\.com' then fb := u; end if;
      if ig is null and u ~* 'instagram\.com|instagr\.am' then ig := u; end if;
      if gmaps is null and u ~* 'google\.[^[:space:]]*maps|maps\.google|goo\.gl/maps|maps\.app\.goo\.gl' then gmaps := u; end if;
    end loop;
    -- אתר שהוא דף פייסבוק/אינסטגרם (לא פרמטר source=facebook באתר אחר)
    if fb is null and rec.website ~* 'facebook\.com|//fb\.com|//www\.fb\.com' then fb := rec.website; end if;
    if ig is null and rec.website ~* 'instagram\.com|instagr\.am' then ig := rec.website; end if;

    update public.places
       set source_urls = case when urls = '{}' then source_urls else urls end,
           facebook_url = coalesce(facebook_url, fb),
           instagram_url = coalesce(instagram_url, ig),
           google_maps_url = coalesce(google_maps_url, gmaps)
     where id = rec.id
       and (
         (urls <> '{}' and source_urls is distinct from urls)
         or (fb is not null and facebook_url is null)
         or (ig is not null and instagram_url is null)
         or (gmaps is not null and google_maps_url is null)
       );
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;
revoke all on function private.backfill_place_links(text) from public, anon, authenticated;

select private.backfill_place_links(null);

-- ========== פרו חינם לצוות ==========
create or replace function private.ensure_staff_pro(p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  comm text;
  nm text;
  rec public.business_accounts;
  tier text;
begin
  if p_user is null then return; end if;
  if not (
    exists (select 1 from private.admins a where a.user_id = p_user)
    or exists (select 1 from private.managers m where m.user_id = p_user)
  ) then
    return;
  end if;

  comm := coalesce(
    (select r.community_id from public.residents r where r.user_id = p_user),
    (select c.community_id from public.business_accounts c where c.user_id = p_user),
    (select private.default_community_id())
  );
  if comm is null or comm not in ('mitzpe','klil') then
    comm := coalesce((select private.default_community_id()), 'mitzpe');
  end if;

  nm := coalesce(
    (select nullif(btrim(pr.display_name), '') from public.profiles pr where pr.user_id = p_user),
    'חשבון אדמין'
  );

  select * into rec from public.business_accounts b where b.user_id = p_user;
  if rec.user_id is null then
    insert into public.business_accounts (
      user_id, community_id, business_name, status, subscription_tier, billing_cycle,
      is_comp, comp_reason, trial_started_at, trial_ends_at, subscription_expires_at
    ) values (
      p_user, comm, nm, 'active', 'pro_monthly', 'yearly',
      true, 'staff', null, null, null
    );
    return;
  end if;

  tier := rec.subscription_tier;
  if tier is null or tier not in ('pro_monthly','founder_yearly') then
    tier := 'pro_monthly';
  end if;

  update public.business_accounts
     set status = 'active',
         subscription_tier = tier,
         is_comp = true,
         comp_reason = coalesce(comp_reason, 'staff'),
         trial_ends_at = null,
         subscription_expires_at = null
   where user_id = p_user;
end $$;
revoke all on function private.ensure_staff_pro(uuid) from public, anon, authenticated;

create or replace function private.grant_staff_from_allowlist(p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare em text;
begin
  if p_user is null then return; end if;
  select lower(btrim(u.email::text)) into em from auth.users u where u.id = p_user;
  if em is null then return; end if;
  if not exists (select 1 from private.staff_email_allowlist a where a.email = em) then
    return;
  end if;
  insert into private.admins (user_id) values (p_user) on conflict (user_id) do nothing;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='private' and p.proname='ensure_staff_resident') then
    perform private.ensure_staff_resident(p_user);
  end if;
  perform private.ensure_staff_pro(p_user);
end $$;
revoke all on function private.grant_staff_from_allowlist(uuid) from public, anon, authenticated;

-- הטריגרים על צוות
create or replace function private.admins_ensure_staff_extras()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='private' and p.proname='ensure_staff_resident') then
    perform private.ensure_staff_resident(new.user_id);
  end if;
  perform private.ensure_staff_pro(new.user_id);
  return new;
end $$;
drop trigger if exists admins_ensure_staff_extras on private.admins;
create trigger admins_ensure_staff_extras after insert or update on private.admins
  for each row execute function private.admins_ensure_staff_extras();
-- 015 already has admins_ensure_resident; this adds pro. Keep both.

drop trigger if exists managers_ensure_staff_extras on private.managers;
create trigger managers_ensure_staff_extras after insert or update on private.managers
  for each row execute function private.admins_ensure_staff_extras();

-- expire: לא לפוגג חשבון מקומפ
create or replace function private.expire_business_if_needed(p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.business_accounts
     set status = 'expired'
   where user_id = p_user
     and status = 'trial'
     and coalesce(is_comp, false) = false
     and trial_ends_at is not null
     and trial_ends_at < now();
  update public.business_accounts
     set status = 'expired'
   where user_id = p_user
     and status = 'active'
     and coalesce(is_comp, false) = false
     and subscription_expires_at is not null
     and subscription_expires_at < now();
end $$;
revoke all on function private.expire_business_if_needed(uuid) from public, anon, authenticated;

-- my_business_account: להבטיח פרו לצוות ואז להחזיר
create or replace function public.my_business_account()
returns public.business_accounts
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  rec public.business_accounts;
begin
  if uid is null then
    return rec;
  end if;
  perform private.grant_staff_from_allowlist(uid);
  if coalesce((select private.is_staff()), false) then
    perform private.ensure_staff_pro(uid);
  end if;
  perform private.expire_business_if_needed(uid);
  select * into rec from public.business_accounts b where b.user_id = uid;
  return rec;
end $$;
revoke all on function public.my_business_account() from public, anon;
grant execute on function public.my_business_account() to authenticated;

-- ensure_my_profile: allowlist + פרו לצוות (משמר את 015)
create or replace function public.ensure_my_profile(p_display_name text default null, p_avatar_url text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  insert into public.profiles (user_id, display_name, avatar_url)
  values (uid, nullif(btrim(coalesce(p_display_name, '')), ''), nullif(btrim(coalesce(p_avatar_url, '')), ''))
  on conflict (user_id) do update
    set display_name = coalesce(nullif(btrim(coalesce(p_display_name, '')), ''), public.profiles.display_name),
        avatar_url = coalesce(nullif(btrim(coalesce(p_avatar_url, '')), ''), public.profiles.avatar_url),
        updated_at = now(),
        version = public.profiles.version + 1;

  perform private.grant_staff_from_allowlist(uid);
  if coalesce((select private.is_staff()), false) then
    if exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='private' and p.proname='ensure_staff_resident') then
      perform private.ensure_staff_resident(uid);
    end if;
    perform private.ensure_staff_pro(uid);
  end if;
end $$;
revoke all on function public.ensure_my_profile(text, text) from public, anon;
grant execute on function public.ensure_my_profile(text, text) to authenticated;

-- start_business_trial: צוות מקבל פרו חינם (בלי ניסיון/תשלום); בעל עסק רגיל — ניסיון 14 יום מיד
-- (הגוף המלא נשמר; נוספת בדיקת צוות בתחילת הזרימה אחרי אימות השם)
-- נטען מחדש עם תוספת — נשתמש ב-create or replace ונשחזר את הלוגיקה מ-016 עם ענף צוות.

-- ========== אונבורדינג ==========
create or replace function public.my_onboarding_state()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  pr public.profiles;
  rec public.business_accounts;
  staff boolean := coalesce((select private.is_staff()), false);
  adm boolean := coalesce((select private.is_admin()), false);
  days integer;
begin
  if uid is null then
    return jsonb_build_object('ok', false);
  end if;
  select * into pr from public.profiles p where p.user_id = uid;
  select * into rec from public.business_accounts b where b.user_id = uid;
  if rec.trial_ends_at is not null then
    days := greatest(0, ceil(extract(epoch from (rec.trial_ends_at - now())) / 86400.0)::int);
  end if;
  return jsonb_build_object(
    'ok', true,
    'is_staff', staff,
    'is_admin', adm,
    'is_comp', coalesce(rec.is_comp, false),
    'need_admin', staff and pr.onboarded_admin_at is null,
    'need_business', (rec.status = 'trial' and coalesce(rec.is_comp,false) = false and pr.onboarded_business_at is null),
    'trial_status', rec.status,
    'trial_days_left', days,
    'trial_ending_soon', (rec.status = 'trial' and coalesce(rec.is_comp,false) = false and days is not null and days <= 3),
    'subscription_tier', rec.subscription_tier
  );
end $$;
revoke all on function public.my_onboarding_state() from public, anon;
grant execute on function public.my_onboarding_state() to authenticated;

create or replace function public.mark_onboarding_done(p_kind text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  k text := lower(btrim(coalesce(p_kind, '')));
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if k not in ('admin','business') then
    raise exception 'bad kind' using errcode = '22023';
  end if;
  if k = 'admin' then
    if not coalesce((select private.is_staff()), false) then
      raise exception 'not admin' using errcode = '42501';
    end if;
    update public.profiles set onboarded_admin_at = coalesce(onboarded_admin_at, now()), updated_at = now()
     where user_id = uid;
  else
    update public.profiles set onboarded_business_at = coalesce(onboarded_business_at, now()), updated_at = now()
     where user_id = uid;
  end if;
  return public.my_onboarding_state();
end $$;
revoke all on function public.mark_onboarding_done(text) from public, anon;
grant execute on function public.mark_onboarding_done(text) to authenticated;

-- ========== הרחבת staff_list_business_accounts עם פרטי המקום ==========
drop function if exists public.staff_list_business_accounts();
create function public.staff_list_business_accounts()
returns table (
  user_id uuid,
  display_name text,
  business_name text,
  place_id text,
  place_name text,
  pending_place_id text,
  pending_place_name text,
  claim_status text,
  claim_review_note text,
  status text,
  subscription_tier text,
  billing_cycle text,
  trial_ends_at timestamptz,
  subscription_expires_at timestamptz,
  community_id text,
  created_at timestamptz,
  is_comp boolean,
  category text,
  category_group text,
  address text,
  hours text,
  phone text,
  website text,
  note text,
  maps_url text,
  google_maps_url text,
  facebook_url text,
  instagram_url text,
  source text,
  source_urls text[]
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_staff()), false) then
    raise exception 'not admin' using errcode = '42501';
  end if;
  return query
    select b.user_id,
           pr.display_name,
           b.business_name,
           b.place_id,
           pl.name_he,
           b.pending_place_id,
           p2.name_he,
           b.claim_status,
           b.claim_review_note,
           b.status,
           b.subscription_tier,
           b.billing_cycle,
           b.trial_ends_at,
           b.subscription_expires_at,
           b.community_id,
           b.created_at,
           b.is_comp,
           coalesce(p2.category, pl.category),
           coalesce(p2.category_group, pl.category_group),
           coalesce(p2.address, pl.address),
           coalesce(p2.hours, pl.hours),
           coalesce(p2.phone, pl.phone),
           coalesce(p2.website, pl.website),
           coalesce(p2.note, pl.note),
           coalesce(p2.maps_url, pl.maps_url),
           coalesce(p2.google_maps_url, pl.google_maps_url),
           coalesce(p2.facebook_url, pl.facebook_url),
           coalesce(p2.instagram_url, pl.instagram_url),
           coalesce(p2.source, pl.source),
           coalesce(p2.source_urls, pl.source_urls)
      from public.business_accounts b
      left join public.profiles pr on pr.user_id = b.user_id
      left join public.places pl on pl.id = b.place_id
      left join public.places p2 on p2.id = b.pending_place_id
     order by
       case when b.claim_status = 'pending' then 0 else 1 end,
       b.created_at desc;
end $$;
revoke all on function public.staff_list_business_accounts() from public, anon;
grant execute on function public.staff_list_business_accounts() to authenticated;

-- backfill פרו לצוות קיים
do $$
declare r record;
begin
  for r in
    select user_id from private.admins
    union
    select user_id from private.managers
  loop
    perform private.ensure_staff_pro(r.user_id);
  end loop;
end $$;

-- start_business_trial: צוות מקבל פרו חינם; משתמש רגיל מתחיל 14 יום ניסיון מיד (תשלום רק בסוף).
create or replace function public.start_business_trial(p_tier_id text, p_business_name text, p_place_id text default null)
returns public.business_accounts
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  rec public.business_accounts;
  plan public.pricing_plans;
  place public.places;
  comm text;
  taken integer;
  name text := nullif(btrim(coalesce(p_business_name, '')), '');
  place_id text := nullif(btrim(coalesce(p_place_id, '')), '');
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if name is null then
    raise exception 'business name required' using errcode = '22023';
  end if;

  perform private.grant_staff_from_allowlist(uid);

  if coalesce((select private.is_staff()), false) then
    perform private.ensure_staff_pro(uid);
    if place_id is not null then
      select * into place from public.places pl where pl.id = place_id;
      if place.id is null then
        raise exception 'place not found' using errcode = '22023';
      end if;
    end if;
    update public.business_accounts
       set business_name = name,
           pending_place_id = coalesce(place_id, pending_place_id),
           claim_status = case
             when place_id is not null and claim_status is distinct from 'approved' then 'pending'
             else claim_status
           end,
           is_comp = true,
           comp_reason = coalesce(comp_reason, 'staff'),
           status = 'active',
           trial_ends_at = null,
           subscription_expires_at = null
     where user_id = uid
     returning * into rec;
    return rec;
  end if;

  select * into plan from public.pricing_plans p where p.tier_id = p_tier_id and p.active;
  if plan.tier_id is null or plan.billing_cycle = 'free' or coalesce(plan.price_ils, 0) <= 0 then
    raise exception 'not a paid plan' using errcode = '22023';
  end if;

  perform private.expire_business_if_needed(uid);
  select * into rec from public.business_accounts b where b.user_id = uid;
  if rec.user_id is not null then
    if rec.trial_started_at is not null then
      raise exception 'trial already used' using errcode = 'P0001';
    end if;
    raise exception 'already has a business account' using errcode = 'P0001';
  end if;

  if place_id is not null then
    select * into place from public.places pl where pl.id = place_id;
    if place.id is null then
      raise exception 'place not found' using errcode = '22023';
    end if;
  end if;

  comm := coalesce(place.community_id, (select private.caller_community_id()), (select private.default_community_id()));

  if plan.tier_id = 'founder_yearly' then
    select count(*)::integer into taken
      from public.business_accounts b
     where b.community_id is not distinct from comm
       and b.subscription_tier = 'founder_yearly'
       and b.status is distinct from 'cancelled';
    if taken >= coalesce(plan.founder_limit, 0) then
      raise exception 'founder plan is full' using errcode = 'P0001';
    end if;
  end if;

  insert into public.business_accounts (
    user_id, community_id, business_name, pending_place_id, claim_status,
    status, subscription_tier, billing_cycle,
    trial_started_at, trial_ends_at, subscription_expires_at, is_comp
  ) values (
    uid, comm, name, place_id, case when place_id is not null then 'pending' else null end,
    'trial', plan.tier_id, plan.billing_cycle,
    now(), now() + interval '14 days', now() + interval '14 days', false
  ) returning * into rec;
  return rec;
end $$;
revoke all on function public.start_business_trial(text, text, text) from public, anon;
grant execute on function public.start_business_trial(text, text, text) to authenticated;
