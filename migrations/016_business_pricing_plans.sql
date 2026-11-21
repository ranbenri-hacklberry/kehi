-- 016: מסלולי מחירים (כולל מע״מ), חשבון עסק, ניסיון 14 יום, וטבלת תשלומים.
-- storage_gb: אחסון אישי במסלול (פרו 64, מייסד 128, עסקי/קהילה ללא). ניתן לעריכה.
-- אין סליקה פעילה: קוד Cardcom נכתב בנפרד ולא הופעל. אין מפתחות בסביבה.
-- community_id נלקח מברירת-המחדל של public.residents.

-- ========== תוכניות מחיר (מקור לעריכת אדמין בהמשך) ==========
create table if not exists public.pricing_plans (
  tier_id text primary key,
  name_he text not null,
  family text not null check (family in ('community','business','pro','founder')),
  price_ils numeric,
  monthly_equivalent_ils numeric,
  storage_gb integer,
  billing_cycle text not null check (billing_cycle in ('free','monthly','yearly')),
  allow_bit_applepay boolean not null default false,
  features jsonb not null default '[]'::jsonb,
  highlight_he text,
  savings_ils numeric,
  founder_limit integer,
  sort_order integer not null default 0,
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
alter table public.pricing_plans enable row level security;

drop policy if exists pricing_plans_select on public.pricing_plans;
create policy pricing_plans_select on public.pricing_plans for select to anon, authenticated
  using (active = true or coalesce((select private.is_staff()), false));

revoke all on table public.pricing_plans from public, anon, authenticated;
grant select on table public.pricing_plans to anon, authenticated;

insert into public.pricing_plans
  (tier_id, name_he, family, price_ils, monthly_equivalent_ils, storage_gb, billing_cycle, allow_bit_applepay, features, highlight_he, savings_ils, founder_limit, sort_order)
values
  ('community', 'קהילה', 'community', 0, 0, null, 'free', false,
   '[{"text":"צפייה מלאה וחיפוש חכם ב«שאלו את נחת»"},{"text":"פרסומים קהילתיים קצרים (טרמפים, מסירות/יד שנייה, עזרה, אירועים חינמיים) ותגובות"},{"text":"ניהול פרסומים פתוחים מהבית"}]'::jsonb,
   null, null, null, 10),
  ('business_monthly', 'אהבה', 'business', 17, 17, null, 'monthly', false,
   '[{"text":"כל מה שבמסלול הקהילה"},{"text":"דף עסק מלא בקטגוריות ובתשובות «שאלו את נחת»"},{"text":"פרסום אירועים, סדנאות בתשלום ומבצעים באירועים הקרובים"},{"text":"שעות פתיחה חיות ברצועת «פתוח עכשיו / קורה היום»"},{"text":"כפתור יצירת קשר ישיר בוואטסאפ או בטלפון"}]'::jsonb,
   null, null, null, 20),
  ('business_yearly', 'אהבה', 'business', 156, 13, null, 'yearly', true,
   '[{"text":"כל מה שבמסלול הקהילה"},{"text":"דף עסק מלא בקטגוריות ובתשובות «שאלו את נחת»"},{"text":"פרסום אירועים, סדנאות בתשלום ומבצעים באירועים הקרובים"},{"text":"שעות פתיחה חיות ברצועת «פתוח עכשיו / קורה היום»"},{"text":"כפתור יצירת קשר ישיר בוואטסאפ או בטלפון"}]'::jsonb,
   'חוסכים 48 ₪ בשנה', 48, null, 21),
  ('pro_monthly', 'פרו', 'pro', 73, 73, 64, 'monthly', false,
   '[{"text":"כל מה שבמסלול אהבה"},{"text":"סטודיו AI לתמונות ועיצוב (Mac Studio)","soon":true},{"text":"אחסון אישי 64GB","soon":true},{"text":"מסנן רעש למייל עם כתובת העברה אישית בדומיין הקהילה (התראות דחופות לוואטסאפ, סיכום יומי, השתקת ניוזלטרים)","soon":true},{"text":"תיוק אוטומטי ב-OCR של חשבוניות וקבלות","soon":true},{"text":"יצירת תוכן ב-AI ותרגום לאנגלית","soon":true}]'::jsonb,
   'הכי משתלם לעסקים פעילים', null, null, 30),
  ('founder_yearly', 'מייסד', 'founder', 730, 60.83, 128, 'yearly', true,
   '[{"text":"כל מה שבמסלול פרו"},{"text":"פגישת התנעה של 45 דקות עם רן, כולל ראיון AI באפליקציה להכנת תוכנית פעולה","soon":true},{"text":"עד 3 פגישות המשך בשנה בהנחת מייסד","soon":true},{"text":"אחסון אישי 128GB","soon":true},{"text":"תג «מייסד» ו«זרקור מייסדים» (בלי להטות את החיפוש האורגני)","soon":true},{"text":"גישה מוקדמת","soon":true}]'::jsonb,
   'שנתי, חודשיים חינם על פרו', 146, 20, 40)
on conflict (tier_id) do nothing;

-- ========== חשבונות עסק ==========
create table if not exists public.business_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  community_id text not null,
  business_name text not null,
  place_id text references public.places(id) on delete set null,
  pending_place_id text references public.places(id) on delete set null,
  claim_status text check (claim_status is null or claim_status in ('pending','approved','rejected')),
  claim_review_note text,
  status text not null default 'trial' check (status in ('trial','active','expired','cancelled')),
  subscription_tier text not null references public.pricing_plans(tier_id),
  billing_cycle text not null check (billing_cycle in ('monthly','yearly')),
  trial_started_at timestamptz,
  trial_ends_at timestamptz,
  subscription_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
create index if not exists business_accounts_community_tier_idx
  on public.business_accounts (community_id, subscription_tier, status);
alter table public.business_accounts enable row level security;

do $$
declare d text;
begin
  select pg_get_expr(ad.adbin, ad.adrelid) into d
    from pg_attribute a
    join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
   where a.attrelid = 'public.residents'::regclass and a.attname = 'community_id';
  if d is not null then
    execute format('alter table public.business_accounts alter column community_id set default %s', d);
  end if;
end $$;

drop policy if exists business_accounts_select_own_or_staff on public.business_accounts;
create policy business_accounts_select_own_or_staff on public.business_accounts for select to authenticated
  using (user_id = (select auth.uid()) or coalesce((select private.is_staff()), false));

revoke all on table public.business_accounts from public, anon, authenticated;
grant select on table public.business_accounts to authenticated;

create or replace function private.business_accounts_before_update()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.user_id := old.user_id;
  new.created_at := old.created_at;
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  return new;
end $$;
revoke all on function private.business_accounts_before_update() from public, anon, authenticated;
drop trigger if exists business_accounts_before_update on public.business_accounts;
create trigger business_accounts_before_update before update on public.business_accounts
  for each row execute function private.business_accounts_before_update();

-- ========== תשלומים (כתיבה רק דרך פונקציות מגדירות אבטחה) ==========
create table if not exists public.payments (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null default 'cardcom',
  amount_ils numeric not null,
  currency text not null default 'ILS',
  status text not null check (status in ('pending','paid','failed','refunded')),
  subscription_tier text references public.pricing_plans(tier_id),
  billing_cycle text check (billing_cycle in ('monthly','yearly')),
  cardcom_lowprofile_id text unique,
  cardcom_tranzaction_id text,
  cardcom_token text,
  invoice_doc_number text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  raw_result jsonb
);
create index if not exists payments_user_idx on public.payments (user_id, created_at desc);
alter table public.payments enable row level security;

drop policy if exists payments_select_own_or_staff on public.payments;
create policy payments_select_own_or_staff on public.payments for select to authenticated
  using (user_id = (select auth.uid()) or coalesce((select private.is_staff()), false));

revoke all on table public.payments from public, anon, authenticated;
grant select on table public.payments to authenticated;

-- ========== עזרים ==========
create or replace function private.default_community_id()
returns text
language plpgsql stable security definer set search_path = '' as $$
declare d text; v text;
begin
  select pg_get_expr(ad.adbin, ad.adrelid) into d
    from pg_attribute a
    join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
   where a.attrelid = 'public.residents'::regclass and a.attname = 'community_id';
  if d is null then return null; end if;
  execute format('select %s', d) into v;
  return v;
end $$;
revoke all on function private.default_community_id() from public, anon, authenticated;

create or replace function private.caller_community_id()
returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select b.community_id from public.business_accounts b where b.user_id = (select auth.uid())),
    (select r.community_id from public.residents r where r.user_id = (select auth.uid())),
    (select private.default_community_id())
  )
$$;
revoke all on function private.caller_community_id() from public, anon, authenticated;

create or replace function private.expire_business_if_needed(p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.business_accounts
     set status = 'expired'
   where user_id = p_user
     and status = 'trial'
     and trial_ends_at is not null
     and trial_ends_at < now();
  update public.business_accounts
     set status = 'expired'
   where user_id = p_user
     and status = 'active'
     and subscription_expires_at is not null
     and subscription_expires_at < now();
end $$;
revoke all on function private.expire_business_if_needed(uuid) from public, anon, authenticated;

-- ========== RPC ציבוריים ==========
create or replace function public.list_pricing_plans()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  comm text := (select private.caller_community_id());
  lim integer;
  taken integer;
begin
  select p.founder_limit into lim from public.pricing_plans p where p.tier_id = 'founder_yearly';
  select count(*)::integer into taken
    from public.business_accounts b
   where b.community_id is not distinct from comm
     and b.subscription_tier = 'founder_yearly'
     and b.status is distinct from 'cancelled';
  return jsonb_build_object(
    'plans', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.sort_order)
        from public.pricing_plans p
       where p.active
    ), '[]'::jsonb),
    'community_id', comm,
    'founder_limit', lim,
    'founder_taken', taken,
    'founder_remaining', greatest(coalesce(lim, 0) - coalesce(taken, 0), 0)
  );
end $$;
revoke all on function public.list_pricing_plans() from public;
grant execute on function public.list_pricing_plans() to anon, authenticated;

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
  perform private.expire_business_if_needed(uid);
  select * into rec from public.business_accounts b where b.user_id = uid;
  return rec;
end $$;
revoke all on function public.my_business_account() from public, anon;
grant execute on function public.my_business_account() to authenticated;

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
    trial_started_at, trial_ends_at, subscription_expires_at
  ) values (
    uid, comm, name, place_id, case when place_id is not null then 'pending' else null end,
    'trial', plan.tier_id, plan.billing_cycle,
    now(), now() + interval '14 days', now() + interval '14 days'
  ) returning * into rec;
  return rec;
end $$;
revoke all on function public.start_business_trial(text, text, text) from public, anon;
grant execute on function public.start_business_trial(text, text, text) to authenticated;

-- ========== צוות ==========
create or replace function public.staff_list_business_accounts()
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
  created_at timestamptz
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
           b.created_at
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

create or replace function public.staff_review_business_claim(p_user uuid, p_decision text, p_note text default null)
returns public.business_accounts
language plpgsql security definer set search_path = '' as $$
declare
  rec public.business_accounts;
  decision text := lower(btrim(coalesce(p_decision, '')));
  note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not coalesce((select private.is_staff()), false) then
    raise exception 'not admin' using errcode = '42501';
  end if;
  if decision not in ('approved','rejected') then
    raise exception 'bad decision' using errcode = '22023';
  end if;
  perform private.expire_business_if_needed(p_user);
  select * into rec from public.business_accounts b where b.user_id = p_user;
  if rec.user_id is null then
    raise exception 'not found' using errcode = 'P0002';
  end if;
  if rec.claim_status is distinct from 'pending' then
    raise exception 'claim is not pending' using errcode = 'P0001';
  end if;
  if decision = 'approved' then
    if rec.pending_place_id is null then
      raise exception 'no place to approve' using errcode = 'P0001';
    end if;
    update public.business_accounts
       set place_id = pending_place_id,
           claim_status = 'approved',
           claim_review_note = note
     where user_id = p_user
    returning * into rec;
  else
    update public.business_accounts
       set claim_status = 'rejected',
           claim_review_note = note
     where user_id = p_user
    returning * into rec;
  end if;
  return rec;
end $$;
revoke all on function public.staff_review_business_claim(uuid, text, text) from public, anon;
grant execute on function public.staff_review_business_claim(uuid, text, text) to authenticated;

create or replace function public.admin_update_pricing_plan(p_tier_id text, p_patch jsonb)
returns public.pricing_plans
language plpgsql security definer set search_path = '' as $$
declare rec public.pricing_plans;
begin
  if not coalesce((select private.is_admin()), false) then
    raise exception 'not admin' using errcode = '42501';
  end if;
  update public.pricing_plans
     set name_he = coalesce(p_patch->>'name_he', name_he),
         price_ils = case when p_patch ? 'price_ils' then nullif(p_patch->>'price_ils','')::numeric else price_ils end,
         monthly_equivalent_ils = case when p_patch ? 'monthly_equivalent_ils' then nullif(p_patch->>'monthly_equivalent_ils','')::numeric else monthly_equivalent_ils end,
         storage_gb = case when p_patch ? 'storage_gb' then nullif(p_patch->>'storage_gb','')::integer else storage_gb end,
         allow_bit_applepay = case when p_patch ? 'allow_bit_applepay' then (p_patch->>'allow_bit_applepay')::boolean else allow_bit_applepay end,
         features = case when p_patch ? 'features' then p_patch->'features' else features end,
         highlight_he = case when p_patch ? 'highlight_he' then nullif(p_patch->>'highlight_he','') else highlight_he end,
         savings_ils = case when p_patch ? 'savings_ils' then nullif(p_patch->>'savings_ils','')::numeric else savings_ils end,
         founder_limit = case when p_patch ? 'founder_limit' then nullif(p_patch->>'founder_limit','')::integer else founder_limit end,
         active = case when p_patch ? 'active' then (p_patch->>'active')::boolean else active end,
         updated_at = now(),
         updated_by = (select auth.uid())
   where tier_id = p_tier_id
  returning * into rec;
  if rec.tier_id is null then
    raise exception 'not found' using errcode = 'P0002';
  end if;
  return rec;
end $$;
revoke all on function public.admin_update_pricing_plan(text, jsonb) from public, anon;
grant execute on function public.admin_update_pricing_plan(text, jsonb) to authenticated;

-- החלת תשלום מאומת (שירות בלבד; יקרא מ-webhook אחרי GetLpResult כשCardcom יופעל)
create or replace function private.apply_cardcom_payment(
  p_user uuid,
  p_amount numeric,
  p_tier_id text,
  p_billing_cycle text,
  p_lowprofile_id text,
  p_tranzaction_id text,
  p_token text default null,
  p_invoice_doc_number text default null,
  p_raw jsonb default null
)
returns public.payments
language plpgsql security definer set search_path = '' as $$
declare
  pay public.payments;
  rec public.business_accounts;
  expires timestamptz;
begin
  if p_user is null or p_lowprofile_id is null then
    raise exception 'missing payment identifiers' using errcode = '22023';
  end if;
  select * into pay from public.payments p where p.cardcom_lowprofile_id = p_lowprofile_id;
  if pay.id is not null then
    return pay;
  end if;

  expires := case
    when p_billing_cycle = 'yearly' then now() + interval '1 year'
    else now() + interval '1 month'
  end;

  insert into public.payments (
    user_id, provider, amount_ils, status, subscription_tier, billing_cycle,
    cardcom_lowprofile_id, cardcom_tranzaction_id, cardcom_token, invoice_doc_number, raw_result
  ) values (
    p_user, 'cardcom', p_amount, 'paid', p_tier_id, p_billing_cycle,
    p_lowprofile_id, p_tranzaction_id, p_token, p_invoice_doc_number, p_raw
  ) returning * into pay;

  perform private.expire_business_if_needed(p_user);
  select * into rec from public.business_accounts b where b.user_id = p_user;
  if rec.user_id is not null then
    update public.business_accounts
       set status = 'active',
           subscription_tier = coalesce(p_tier_id, subscription_tier),
           billing_cycle = coalesce(p_billing_cycle, billing_cycle),
           subscription_expires_at = expires
     where user_id = p_user;
  end if;
  return pay;
end $$;
revoke all on function private.apply_cardcom_payment(uuid, numeric, text, text, text, text, text, text, jsonb)
  from public, anon, authenticated;
