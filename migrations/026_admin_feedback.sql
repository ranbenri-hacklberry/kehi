-- 026: הערות ובקשות של אדמינים (הערה / תגובה / בקשת שיפור / תקלה). אדמינים בלבד: הטבלה בסכמה private, גישה רק דרך פונקציות שבודקות private.is_admin().
-- טקסט עובר ניקוי סודות/פרטים רגישים (טוקנים, מפתחות, סיסמאות, ת"ז, קודי כניסה) גם כאן בשרת, בנוסף לשומרים באפליקציה וב־MCP.
-- כליל: לפי כלל הארכיטקטורה המידע הפרטי יעבור למחשב של אפרת; כאן זה מקום זמני מאחורי ממשק (ראו docs).
create table if not exists private.admin_feedback (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  author_id uuid,
  author_email text,
  kind text not null check (kind in ('הערה', 'תגובה', 'בקשת שיפור', 'תקלה')),
  body text not null check (char_length(body) between 1 and 4000),
  related_kind text check (related_kind in ('place', 'event', 'post', 'qa', 'other')),
  related_id text check (char_length(related_id) <= 120),
  status text not null default 'פתוח' check (status in ('פתוח', 'בטיפול', 'טופל')),
  reply text check (char_length(reply) <= 4000),
  updated_at timestamptz not null default now(),
  updated_by_email text
);
create index if not exists admin_feedback_created_idx on private.admin_feedback (created_at desc);
alter table private.admin_feedback enable row level security;
revoke all on private.admin_feedback from public, anon, authenticated;

create or replace function private.scrub_secrets(t text) returns text
language sql immutable set search_path = '' as $$
  select btrim(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(t, ''),
      '-----BEGIN [A-Z ]+-----.*?-----END [A-Z ]+-----', '[הוסר]', 'g'),
      'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', '[הוסר]', 'g'),
      '(sb_secret_|sk-|sk_live_|sk_test_|rk_live_|ghp_|gho_|ghs_|github_pat_|xox[abprs]-|AKIA|AIza)[A-Za-z0-9_\-]{8,}', '[הוסר]', 'g'),
      '(password|passwd|pwd|token|secret|api[ _-]?key|סיסמה|סיסמא|סיסמת|קוד גישה)(\s*[:=]\s*|\s+)\S+', '\1: [הוסר]', 'gi'),
      'קוד\s*(ל|של\s*)?(ה)?(דלת|שער|בניין|כניסה|לובי|אינטרקום)\s*:?\s*[#*]?\d{3,8}#?', '[קוד הוסר]', 'g'),
      '(^|[^\d])\d{9}([^\d]|$)', '\1[הוסר]\2', 'g'),
      '[A-Fa-f0-9]{32,}', '[הוסר]', 'g'))
$$;
revoke all on function private.scrub_secrets(text) from public, anon, authenticated;

create or replace function public.admin_add_feedback(p_kind text, p_text text, p_related_kind text default null, p_related_id text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r private.admin_feedback; b text;
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  b := left(private.scrub_secrets(p_text), 4000);
  if b = '' then raise exception 'text required' using errcode = '22023'; end if;
  insert into private.admin_feedback (author_id, author_email, kind, body, related_kind, related_id)
  values ((select auth.uid()), (select auth.jwt() ->> 'email'), p_kind, b, nullif(p_related_kind, ''), nullif(left(btrim(coalesce(p_related_id, '')), 120), ''))
  returning * into r;
  return to_jsonb(r) - 'author_id';
end $$;

create or replace function public.admin_list_feedback(p_status text default null, p_kind text default null, p_since timestamptz default null, p_limit integer default 200)
returns setof jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  return query select to_jsonb(f) - 'author_id' from private.admin_feedback f
   where (p_status is null or f.status = p_status) and (p_kind is null or f.kind = p_kind) and (p_since is null or f.created_at >= p_since)
   order by f.created_at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end $$;

create or replace function public.admin_update_feedback(p_id bigint, p_status text default null, p_reply text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r private.admin_feedback;
begin
  if not coalesce((select private.is_admin()), false) then raise exception 'not admin' using errcode = '42501'; end if;
  if p_status is not null and p_status not in ('פתוח', 'בטיפול', 'טופל') then raise exception 'bad status' using errcode = '22023'; end if;
  update private.admin_feedback f set
    status = coalesce(p_status, f.status),
    reply = case when p_reply is null then f.reply else nullif(left(private.scrub_secrets(p_reply), 4000), '') end,
    updated_at = now(), updated_by_email = (select auth.jwt() ->> 'email')
  where f.id = p_id returning * into r;
  if r.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  return to_jsonb(r) - 'author_id';
end $$;
revoke all on function public.admin_add_feedback(text, text, text, text) from public, anon;
revoke all on function public.admin_list_feedback(text, text, timestamptz, integer) from public, anon;
revoke all on function public.admin_update_feedback(bigint, text, text) from public, anon;
grant execute on function public.admin_add_feedback(text, text, text, text) to authenticated;
grant execute on function public.admin_list_feedback(text, text, timestamptz, integer) to authenticated;
grant execute on function public.admin_update_feedback(bigint, text, text) to authenticated;
