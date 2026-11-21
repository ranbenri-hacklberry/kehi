-- 017: אימות webhook לסליקת בדיקה (Cardcom demo). אין service_role אצל ה-Worker.
-- הסוד עצמו לא נשמר במסד — רק SHA-256. ה-RPC פתוח ל-anon ומאמת את ההאש.

create table if not exists private.pay_webhook_config (
  id boolean primary key default true check (id),
  secret_sha256 text check (secret_sha256 is null or secret_sha256 ~ '^[0-9a-f]{64}$'),
  enabled boolean not null default false,
  mode text not null default 'test' check (mode in ('test','live')),
  community_id text,
  updated_at timestamptz not null default now()
);
alter table private.pay_webhook_config enable row level security;
revoke all on table private.pay_webhook_config from public, anon, authenticated;
insert into private.pay_webhook_config (id, enabled, mode) values (true, false, 'test')
  on conflict (id) do nothing;

-- רושם תשלום מאומת אחרי GetLpResult. רק כשהסוד תואם והמצב enabled.
create or replace function public.apply_cardcom_test_payment(
  p_secret text,
  p_user uuid,
  p_amount numeric,
  p_tier_id text,
  p_billing_cycle text,
  p_lowprofile_id text,
  p_tranzaction_id text default null,
  p_token text default null,
  p_invoice_doc_number text default null,
  p_raw jsonb default null
)
returns public.payments
language plpgsql security definer set search_path = '' as $$
declare
  cfg private.pay_webhook_config;
  pay public.payments;
  rec public.business_accounts;
  expires timestamptz;
  secret text := nullif(btrim(coalesce(p_secret, '')), '');
begin
  select * into cfg from private.pay_webhook_config where id = true;
  if cfg.id is null or not cfg.enabled or cfg.secret_sha256 is null or secret is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if encode(extensions.digest(secret, 'sha256'), 'hex') <> cfg.secret_sha256 then
    raise exception 'not allowed' using errcode = '42501';
  end if;
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
    p_user, 'cardcom-test', p_amount, 'paid', p_tier_id, p_billing_cycle,
    p_lowprofile_id, p_tranzaction_id, p_token, p_invoice_doc_number, p_raw
  ) returning * into pay;

  if exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='private' and p.proname='expire_business_if_needed') then
    perform private.expire_business_if_needed(p_user);
  end if;

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

revoke all on function public.apply_cardcom_test_payment(text, uuid, numeric, text, text, text, text, text, text, jsonb)
  from public;
grant execute on function public.apply_cardcom_test_payment(text, uuid, numeric, text, text, text, text, text, text, jsonb)
  to anon, authenticated;
