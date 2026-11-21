-- 013: משלים RPC-ים ש-009 תיעד והאפליקציה קוראת, אבל לא יצרה.
-- אין כתיבה ישירה ל-residents (רק דרך RPC). community_id נלקח מברירת-המחדל של הטבלה.

create or replace function public.ensure_my_profile(p_display_name text default null, p_avatar_url text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
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
end $$;

create or replace function public.my_resident()
returns public.residents
language sql stable security definer set search_path = ''
as $$
  select * from public.residents r where r.user_id = (select auth.uid());
$$;

create or replace function public.request_resident_verification(p_note text default null)
returns public.residents
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  rec public.residents;
  note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into rec from public.residents r where r.user_id = uid;
  if rec.user_id is null then
    insert into public.residents (user_id, status, request_note)
    values (uid, 'pending', note)
    returning * into rec;
    return rec;
  end if;

  if rec.status = 'verified' then
    return rec;
  end if;

  update public.residents
     set status = 'pending',
         request_note = coalesce(note, request_note),
         review_note = case when rec.status = 'rejected' then null else rec.review_note end
   where user_id = uid
  returning * into rec;
  return rec;
end $$;

revoke all on function public.ensure_my_profile(text, text) from public, anon;
revoke all on function public.my_resident() from public, anon;
revoke all on function public.request_resident_verification(text) from public, anon;
grant execute on function public.ensure_my_profile(text, text) to authenticated;
grant execute on function public.my_resident() to authenticated;
grant execute on function public.request_resident_verification(text) to authenticated;
