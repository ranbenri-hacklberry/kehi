-- 022: יומן שאלות ותשובות של הצ'אט. בלי מזהה משתמש, שם, טלפון, מייל, IP או מזהה מכשיר.
-- הטבלה בסכמה private (לא חשופה ב־API). כתיבה רק דרך ה־worker (מפתח כתיבה שה־hash שלו שמור כאן), קריאה רק לאדמינים.
-- מחיקה אוטומטית אחרי 30 יום: pg_cron + ניקוי גם בכל הוספה.
create extension if not exists pg_cron;

create table if not exists private.chat_qa_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  token_hash text not null unique,
  question text not null check (char_length(question) between 1 and 500),
  answer text check (char_length(answer) <= 2000),
  record_ids text[] not null default '{}' check (cardinality(record_ids) <= 12),
  source text not null check (source in ('model', 'fallback', 'refusal')),
  latency_ms integer check (latency_ms between 0 and 600000),
  scrubbed boolean not null default false,
  flagged boolean not null default false,
  flagged_at timestamptz
);
create index if not exists chat_qa_log_created_idx on private.chat_qa_log (created_at desc);
alter table private.chat_qa_log enable row level security;
revoke all on private.chat_qa_log from public, anon, authenticated;

create table if not exists private.chat_qa_writer (id int primary key default 1 check (id = 1), key_hash text not null);
alter table private.chat_qa_writer enable row level security;
revoke all on private.chat_qa_writer from public, anon, authenticated;

create or replace function private.chat_qa_key_ok(p_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(p_key, '') <> '' and exists (select 1 from private.chat_qa_writer w
    where w.key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex'))
$$;
revoke all on function private.chat_qa_key_ok(text) from public, anon, authenticated;

-- הוספה: נקראת רק מה־worker עם מפתח הכתיבה. מחזירה כלום; הטוקן (שמור רק כ־hash) הוא של ה־worker.
create or replace function public.chat_qa_insert(p_key text, p_token text, p_question text, p_answer text,
  p_record_ids text[], p_source text, p_latency_ms integer, p_scrubbed boolean)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
begin
  if not private.chat_qa_key_ok(p_key) then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{22,64}$' then raise exception 'bad token' using errcode = '22023'; end if;
  delete from private.chat_qa_log where created_at < now() - interval '30 days';
  insert into private.chat_qa_log (token_hash, question, answer, record_ids, source, latency_ms, scrubbed)
  values (encode(extensions.digest(p_token, 'sha256'), 'hex'), left(btrim(p_question), 500), left(p_answer, 2000),
          coalesce(p_record_ids[1:12], '{}'), p_source, least(greatest(coalesce(p_latency_ms, 0), 0), 600000), coalesce(p_scrubbed, false));
  return true;
end $$;

-- סימון "תשובה לא טובה" לפי טוקן השורה (לא לפי זהות).
create or replace function public.chat_qa_flag(p_key text, p_token text)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  if not private.chat_qa_key_ok(p_key) then raise exception 'forbidden' using errcode = '42501'; end if;
  update private.chat_qa_log set flagged = true, flagged_at = coalesce(flagged_at, now())
   where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') and created_at >= now() - interval '30 days';
  get diagnostics n = row_count;
  return n > 0;
end $$;
revoke all on function public.chat_qa_insert(text, text, text, text, text[], text, integer, boolean) from public;
revoke all on function public.chat_qa_flag(text, text) from public;
grant execute on function public.chat_qa_insert(text, text, text, text, text[], text, integer, boolean) to anon, authenticated;
grant execute on function public.chat_qa_flag(text, text) to anon, authenticated;

-- קריאה: אדמינים בלבד, החדשות קודם.
create or replace function public.admin_list_chat_qa(p_only_flagged boolean default false, p_limit integer default 300)
returns table (id bigint, created_at timestamptz, question text, answer text, record_ids text[], source text, latency_ms integer, scrubbed boolean, flagged boolean, flagged_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query select l.id, l.created_at, l.question, l.answer, l.record_ids, l.source, l.latency_ms, l.scrubbed, l.flagged, l.flagged_at
    from private.chat_qa_log l
   where l.created_at >= now() - interval '30 days' and (not coalesce(p_only_flagged, false) or l.flagged)
   order by l.created_at desc limit least(greatest(coalesce(p_limit, 300), 1), 1000);
end $$;
revoke all on function public.admin_list_chat_qa(boolean, integer) from public, anon;
grant execute on function public.admin_list_chat_qa(boolean, integer) to authenticated;

select cron.schedule('chat-qa-log-30d', '17 3 * * *', $$delete from private.chat_qa_log where created_at < now() - interval '30 days'$$);
