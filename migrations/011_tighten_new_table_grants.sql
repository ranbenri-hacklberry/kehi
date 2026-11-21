-- 011: מצמצם הרשאות ברירת-מחדל על טבלאות מ-009/010.
-- אחרי CREATE TABLE, ל-anon נשארו ALL (כולל TRUNCATE) — זה לא היה מכוון.
-- RLS היה מופעל, אבל TRUNCATE עוקף RLS. הקובץ הזה רק משנה GRANT, לא מבנה.

revoke all on table
  public.posts, public.post_replies, public.post_reads,
  public.residents, public.post_slots, public.slot_bookings
  from public, anon, authenticated;

grant select on table public.posts, public.post_replies, public.post_slots to anon, authenticated;
grant select, insert, update on table public.posts, public.post_replies to authenticated;
grant select, insert, update, delete on table public.post_reads to authenticated;
grant select on table public.residents to authenticated;
grant select on table public.slot_bookings to authenticated;
grant insert, update, delete on table public.post_slots to authenticated;
