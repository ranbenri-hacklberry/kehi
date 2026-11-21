-- 015: צוות (אדמין / מנהל/ת קהילה) נחשב/ת לתושב/ת מאומת/ת.
-- אין הרחבת GRANT. community_id נלקח מברירת-המחדל של הטבלה.
-- בטבלת residents אין עמודות verified_at/verified_by; מעודכנים updated_at/updated_by (הטריגר הקיים).

-- ========== עזר: שורת תושב מאומת לאיש צוות ==========
create or replace function private.ensure_staff_resident(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user is null then
    return;
  end if;
  if not (
    exists (select 1 from private.admins a where a.user_id = p_user)
    or exists (select 1 from private.managers m where m.user_id = p_user)
  ) then
    return;
  end if;

  insert into public.residents (user_id, status)
  values (p_user, 'verified')
  on conflict (user_id) do update
    set status = 'verified',
        review_note = case
          when public.residents.status is distinct from 'verified' then null
          else public.residents.review_note
        end
  where public.residents.status is distinct from 'verified';
end $$;

revoke all on function private.ensure_staff_resident(uuid) from public, anon, authenticated;

-- ========== is_verified_resident: צוות נחשב מאומת ==========
create or replace function private.is_verified_resident() returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select private.is_staff()), false)
      or exists (
        select 1 from public.residents r
         where r.user_id = (select auth.uid()) and r.status = 'verified'
      )
$$;
-- GRANTs נשארים כפי ש-012 הגדיר (anon, authenticated). לא משנים אותם.

-- ========== ensure_my_profile: שורת תושב אמיתית לצוות ==========
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

  if coalesce((select private.is_staff()), false) then
    perform private.ensure_staff_resident(uid);
  end if;
end $$;

-- ========== my_resident: אם צוות בלי שורה / ממתין — מאמתים את השורה ומחזירים אותה ==========
create or replace function public.my_resident()
returns public.residents
language plpgsql volatile security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  rec public.residents;
begin
  if uid is null then
    return rec;
  end if;
  if coalesce((select private.is_staff()), false) then
    perform private.ensure_staff_resident(uid);
  end if;
  select * into rec from public.residents r where r.user_id = uid;
  return rec;
end $$;

-- ========== בקשת אימות: צוות מקבל verified מיד ==========
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

  if coalesce((select private.is_staff()), false) then
    perform private.ensure_staff_resident(uid);
    if note is not null then
      update public.residents
         set request_note = note
       where user_id = uid
         and request_note is distinct from note
      returning * into rec;
    end if;
    if rec.user_id is null then
      select * into rec from public.residents r where r.user_id = uid;
    end if;
    return rec;
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

-- ========== טריגר: הוספה ל-admins/managers מאמתת את שורת התושב ==========
create or replace function private.staff_membership_ensure_resident()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    return old;
  end if;
  perform private.ensure_staff_resident(new.user_id);
  return new;
end $$;

revoke all on function private.staff_membership_ensure_resident() from public, anon, authenticated;

drop trigger if exists admins_ensure_resident on private.admins;
create trigger admins_ensure_resident
  after insert or update of user_id on private.admins
  for each row execute function private.staff_membership_ensure_resident();

drop trigger if exists managers_ensure_resident on private.managers;
create trigger managers_ensure_resident
  after insert or update of user_id on private.managers
  for each row execute function private.staff_membership_ensure_resident();

-- ========== השלמה לצוות קיים (רק שורות צוות; לא נוגעים בתושבים אחרים) ==========
select private.ensure_staff_resident(s.user_id)
  from (
    select user_id from private.admins
    union
    select user_id from private.managers
  ) s;
