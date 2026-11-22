-- Run only after a community's private store is live and its chat reports / admin feedback were copied there
-- (see docs/private-store.md). Empties the Supabase copies, stops the retention cron and closes the RPCs, so
-- private records can never be written to Supabase again (no silent fallback).
delete from private.chat_qa_log;
delete from private.admin_feedback;
select cron.unschedule('chat-qa-log-30d') where exists (select 1 from cron.job where jobname = 'chat-qa-log-30d');
revoke execute on function public.chat_qa_insert(text, text, text, text, text[], text, integer, boolean) from public, anon, authenticated;
revoke execute on function public.chat_qa_flag(text, text) from public, anon, authenticated;
revoke execute on function public.admin_list_chat_qa(boolean, integer) from public, anon, authenticated;
revoke execute on function public.admin_add_feedback(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.admin_list_feedback(text, text, timestamptz, integer) from public, anon, authenticated;
revoke execute on function public.admin_update_feedback(bigint, text, text) from public, anon, authenticated;
comment on table private.chat_qa_log is 'Unused: chat reports live in the community private store.';
comment on table private.admin_feedback is 'Unused: admin feedback lives in the community private store.';
