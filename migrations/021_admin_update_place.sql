-- 021: עריכת מקום/אירוע ע״י צוות — כל השדות כולל קישורים, שמירה+אישור.
-- ממחזר את public.admin_update_place / admin_update_event (מ־006/009) ואת שדות הקישור מ־mcp_admin_update_place_links (020).
-- SECURITY DEFINER עם בדיקת private.is_staff(). השינוי נרשם ב־audit_log דרך הטריגרים הקיימים.
-- קישורים מ-tachlis.co.il נחסמים.

create or replace function private.admin_url_error(u text) returns text
language plpgsql immutable set search_path = '' as $$
declare s text := nullif(btrim(coalesce(u, '')), '');
begin
  if s is null then return null; end if;
  if s ~* 'tachlis\.co\.il' then return 'לא שומרים קישורים מ-tachlis.co.il'; end if;
  if s !~* '^https?://[^[:space:]]+$' then return 'כתובת קישור לא תקינה'; end if;
  return null;
end $$;
revoke all on function private.admin_url_error(text) from public, anon, authenticated;

create or replace function private.admin_clean_url(u text) returns text
language plpgsql immutable set search_path = '' as $$
declare s text := nullif(btrim(coalesce(u, '')), ''); err text;
begin
  err := private.admin_url_error(s);
  if err is not null then raise exception '%', err using errcode = '22023'; end if;
  return s;
end $$;
revoke all on function private.admin_clean_url(text) from public, anon, authenticated;

create or replace function private.admin_clean_url_array(j jsonb) returns text[]
language plpgsql immutable set search_path = '' as $$
declare out text[] := '{}'; s text; err text; e jsonb;
begin
  if j is null or j = 'null'::jsonb then return '{}'; end if;
  if jsonb_typeof(j) = 'string' then
    foreach s in array regexp_split_to_array(j #>> '{}', E'[\\s,]+') loop
      s := nullif(btrim(s), '');
      if s is null then continue; end if;
      err := private.admin_url_error(s);
      if err is not null then raise exception '%', err using errcode = '22023'; end if;
      if not (s = any (out)) then out := out || s; end if;
    end loop;
    return out;
  end if;
  if jsonb_typeof(j) <> 'array' then raise exception 'source_urls must be an array' using errcode = '22023'; end if;
  for e in select value from jsonb_array_elements(j) loop
    if jsonb_typeof(e) = 'string' then s := e #>> '{}';
    elsif jsonb_typeof(e) = 'object' then s := coalesce(e->>'url', e->>'href');
    else s := null;
    end if;
    s := nullif(btrim(coalesce(s, '')), '');
    if s is null then continue; end if;
    err := private.admin_url_error(s);
    if err is not null then raise exception '%', err using errcode = '22023'; end if;
    if not (s = any (out)) then out := out || s; end if;
  end loop;
  return out;
end $$;
revoke all on function private.admin_clean_url_array(jsonb) from public, anon, authenticated;

drop function if exists public.admin_update_place(text, jsonb, integer);
create or replace function public.admin_update_place(
  p_id text, p_patch jsonb, p_version integer default null, p_approve boolean default false)
returns public.places
language plpgsql volatile security definer set search_path = '' as $$
declare res public.places; bad text;
begin
  if not coalesce((select private.is_staff()), false) then
    raise exception 'not admin' using errcode = '42501';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'bad patch' using errcode = '22023';
  end if;
  select string_agg(k, ',') into bad from jsonb_object_keys(p_patch) k
    where k not in (
      'name_he','category_group','category','note','hours','phone','website','address','badge','search_only',
      'name_en','maps_url','google_maps_url','facebook_url','instagram_url','source_urls','lat','lng','hours_status','last_verified'
    );
  if bad is not null then raise exception 'field not editable: %', bad using errcode = '22023'; end if;
  if p_patch ? 'name_he' and nullif(btrim(p_patch->>'name_he'), '') is null then
    raise exception 'name required' using errcode = '22023';
  end if;

  update public.places p set
    name_he         = case when p_patch ? 'name_he' then btrim(p_patch->>'name_he') else p.name_he end,
    category_group  = case when p_patch ? 'category_group' then nullif(btrim(p_patch->>'category_group'), '') else p.category_group end,
    category        = case when p_patch ? 'category' then nullif(btrim(p_patch->>'category'), '') else p.category end,
    note            = case when p_patch ? 'note' then nullif(btrim(p_patch->>'note'), '') else p.note end,
    hours           = case when p_patch ? 'hours' then nullif(btrim(p_patch->>'hours'), '') else p.hours end,
    phone           = case when p_patch ? 'phone' then nullif(btrim(p_patch->>'phone'), '') else p.phone end,
    website         = case when p_patch ? 'website' then private.admin_clean_url(p_patch->>'website') else p.website end,
    address         = case when p_patch ? 'address' then nullif(btrim(p_patch->>'address'), '') else p.address end,
    badge           = case when p_patch ? 'badge' then nullif(btrim(p_patch->>'badge'), '') else p.badge end,
    search_only     = case when p_patch ? 'search_only' then coalesce((p_patch->>'search_only')::boolean, false) else p.search_only end,
    name_en         = case when p_patch ? 'name_en' then nullif(btrim(p_patch->>'name_en'), '') else p.name_en end,
    maps_url        = case when p_patch ? 'maps_url' then private.admin_clean_url(p_patch->>'maps_url') else p.maps_url end,
    google_maps_url = case when p_patch ? 'google_maps_url' then private.admin_clean_url(p_patch->>'google_maps_url') else p.google_maps_url end,
    facebook_url    = case when p_patch ? 'facebook_url' then private.admin_clean_url(p_patch->>'facebook_url') else p.facebook_url end,
    instagram_url   = case when p_patch ? 'instagram_url' then private.admin_clean_url(p_patch->>'instagram_url') else p.instagram_url end,
    source_urls     = case when p_patch ? 'source_urls' then private.admin_clean_url_array(p_patch->'source_urls') else p.source_urls end,
    lat             = case when p_patch ? 'lat' then nullif(p_patch->>'lat','')::double precision else p.lat end,
    lng             = case when p_patch ? 'lng' then nullif(p_patch->>'lng','')::double precision else p.lng end,
    hours_status    = case when p_patch ? 'hours_status' then nullif(btrim(p_patch->>'hours_status'), '') else p.hours_status end,
    last_verified   = case when p_patch ? 'last_verified' then nullif(p_patch->>'last_verified','')::date else p.last_verified end,
    status          = case when coalesce(p_approve, false) then 'published'::public.place_status else p.status end
  where p.id = p_id and (p_version is null or p.version = p_version)
  returning * into res;
  if res.id is null then raise exception 'not found or changed by someone else' using errcode = '40001'; end if;
  return res;
end $$;
revoke all on function public.admin_update_place(text, jsonb, integer, boolean) from public, anon;
grant execute on function public.admin_update_place(text, jsonb, integer, boolean) to authenticated;

drop function if exists public.admin_update_event(text, jsonb, integer);
create or replace function public.admin_update_event(
  p_id text, p_patch jsonb, p_version integer default null, p_approve boolean default false)
returns public.events
language plpgsql volatile security definer set search_path = '' as $$
declare res public.events; bad text;
begin
  if not coalesce((select private.is_staff()), false) then
    raise exception 'not admin' using errcode = '42501';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'bad patch' using errcode = '22023';
  end if;
  select string_agg(k, ',') into bad from jsonb_object_keys(p_patch) k
    where k not in ('title','when_text','venue_name','address','price_text','organizer','description','start_date','starts_at','ends_at');
  if bad is not null then raise exception 'field not editable: %', bad using errcode = '22023'; end if;
  if p_patch ? 'title' and nullif(btrim(p_patch->>'title'), '') is null then
    raise exception 'title required' using errcode = '22023';
  end if;

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
    ends_at     = case when p_patch ? 'ends_at' then nullif(p_patch->>'ends_at', '')::timestamptz else e.ends_at end,
    status      = case when coalesce(p_approve, false) then 'published'::public.place_status else e.status end
  where e.id = p_id and (p_version is null or e.version = p_version)
  returning * into res;
  if res.id is null then raise exception 'not found or changed by someone else' using errcode = '40001'; end if;
  return res;
end $$;
revoke all on function public.admin_update_event(text, jsonb, integer, boolean) from public, anon;
grant execute on function public.admin_update_event(text, jsonb, integer, boolean) to authenticated;
