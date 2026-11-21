-- 007: our own admin email-code login, sent through Resend from the database (pg_net).
-- Secret: the Resend API key lives ONLY in Supabase Vault (name 'resend_api_key'). Never in client, worker or docs.
-- Until that secret + private.otp_settings.from_addr exist, admin_otp_request returns 'not_configured'
-- and the admin page falls back to the built-in Supabase email code.
create extension if not exists pg_net with schema extensions;

create table if not exists private.otp_settings (
  id boolean primary key default true check (id),
  site_name text not null,
  from_addr text,               -- e.g. 'כלילי <no-reply@example.com>'; null = not configured
  accent text not null default '#4d6b2f'
);
create table if not exists private.admin_otp (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  code_hash text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  attempts int not null default 0,
  used_at timestamptz,
  mail_request_id bigint
);
create index if not exists admin_otp_user_idx on private.admin_otp(user_id, created_at desc);
create table if not exists private.admin_login_pw (
  user_id uuid primary key references auth.users(id) on delete cascade,
  set_at timestamptz not null default now()
);
alter table private.otp_settings enable row level security;
alter table private.admin_otp enable row level security;
alter table private.admin_login_pw enable row level security;
revoke all on private.otp_settings, private.admin_otp, private.admin_login_pw from public, anon, authenticated;

-- wipe one-time login passwords older than 2 minutes (and the given user's, if any)
create or replace function private.clear_login_pw(p_user uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update auth.users u set encrypted_password = '', updated_at = now()
   where u.id in (select l.user_id from private.admin_login_pw l where l.user_id = p_user or l.set_at < now() - interval '2 minutes');
  delete from private.admin_login_pw l where l.user_id = p_user or l.set_at < now() - interval '2 minutes';
end $$;
revoke all on function private.clear_login_pw(uuid) from public, anon, authenticated;

create or replace function private.admin_uid_for(p_email text) returns uuid
language sql stable security definer set search_path = '' as $$
  select u.id from auth.users u join private.admins a on a.user_id = u.id
   where lower(u.email) = lower(trim(p_email)) limit 1
$$;
revoke all on function private.admin_uid_for(text) from public, anon, authenticated;

-- step 1: request a code. returns 'sent' | 'not_admin' | 'wait' | 'limit' | 'not_configured'
create or replace function public.admin_otp_request(p_email text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid; v_code text; v_key text; v_set private.otp_settings; v_req bigint; v_last timestamptz;
begin
  perform private.clear_login_pw(null);
  if p_email is null or length(p_email) > 254 then return 'not_admin'; end if;
  -- global brake against abuse
  if (select count(*) from private.admin_otp where created_at > now() - interval '1 hour') >= 30 then return 'limit'; end if;
  v_uid := private.admin_uid_for(p_email);
  if v_uid is null then return 'not_admin'; end if;
  select * into v_set from private.otp_settings where id;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if v_set.from_addr is null or v_key is null then return 'not_configured'; end if;
  select max(created_at) into v_last from private.admin_otp where user_id = v_uid;
  if v_last > now() - interval '60 seconds' then return 'wait'; end if;
  if (select count(*) from private.admin_otp where user_id = v_uid and created_at > now() - interval '1 hour') >= 5 then return 'limit'; end if;
  v_code := lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  -- only the newest code is valid
  update private.admin_otp set used_at = now() where user_id = v_uid and used_at is null;
  select net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', v_set.from_addr,
      'to', jsonb_build_array(lower(trim(p_email))),
      'subject', 'קוד הכניסה שלך לניהול ' || v_set.site_name || ': ' || v_code,
      'text', 'קוד הכניסה שלך לניהול ' || v_set.site_name || ' הוא ' || v_code || E'\nהקוד בתוקף ל-10 דקות. אם לא ביקשת קוד, אפשר להתעלם מהמייל.',
      'html', '<div dir="rtl" style="font-family:Arial,sans-serif;font-size:16px;line-height:1.6;color:#222">'
        || '<p>קוד הכניסה שלך לניהול <b>' || v_set.site_name || '</b>:</p>'
        || '<p style="font-size:32px;letter-spacing:6px;font-weight:bold;color:' || v_set.accent || ';margin:16px 0">' || v_code || '</p>'
        || '<p>הקוד בתוקף ל-10 דקות. אם לא ביקשת קוד, אפשר להתעלם מהמייל.</p></div>'
    )
  ) into v_req;
  insert into private.admin_otp(user_id, code_hash, expires_at, mail_request_id)
  values (v_uid, extensions.crypt(v_code, extensions.gen_salt('bf')), now() + interval '10 minutes', v_req);
  return 'sent';
end $$;

-- step 2: verify. on success returns a one-time random password (valid ~2 min) that the page
-- immediately exchanges for a normal Supabase session, then calls admin_otp_consume().
create or replace function public.admin_otp_verify(p_email text, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid; v_row private.admin_otp; v_pw text;
begin
  perform private.clear_login_pw(null);
  v_uid := private.admin_uid_for(p_email);
  if v_uid is null or p_code !~ '^[0-9]{6}$' then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  select * into v_row from private.admin_otp
   where user_id = v_uid and used_at is null order by created_at desc limit 1 for update;
  if v_row.id is null or v_row.expires_at < now() or v_row.attempts >= 5 then
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;
  if extensions.crypt(p_code, v_row.code_hash) <> v_row.code_hash then
    update private.admin_otp set attempts = attempts + 1,
      used_at = case when attempts + 1 >= 5 then now() else null end where id = v_row.id;
    return jsonb_build_object('ok', false, 'error', 'invalid', 'left', greatest(0, 4 - v_row.attempts));
  end if;
  update private.admin_otp set used_at = now() where id = v_row.id;
  v_pw := encode(extensions.gen_random_bytes(24), 'base64');
  update auth.users set encrypted_password = extensions.crypt(v_pw, extensions.gen_salt('bf', 10)), updated_at = now() where id = v_uid;
  insert into private.admin_login_pw(user_id) values (v_uid) on conflict (user_id) do update set set_at = now();
  return jsonb_build_object('ok', true, 'pw', v_pw);
end $$;

-- step 3: signed-in admin wipes the one-time password right away
create or replace function public.admin_otp_consume() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  perform private.clear_login_pw(auth.uid());
end $$;

revoke all on function public.admin_otp_request(text), public.admin_otp_verify(text, text), public.admin_otp_consume() from public;
grant execute on function public.admin_otp_request(text), public.admin_otp_verify(text, text) to anon, authenticated;
grant execute on function public.admin_otp_consume() to authenticated;

-- (008) default privileges also grant anon; consume is for signed-in users only
revoke execute on function public.admin_otp_consume() from anon;
