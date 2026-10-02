-- Jambling: daily reward. Run this once in Supabase > SQL Editor.
alter table profiles add column if not exists last_daily timestamptz;

create or replace function claim_daily() returns json
language plpgsql security definer set search_path = public as $$
declare
  last timestamptz;
  bal numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select last_daily into last from profiles where id = auth.uid() for update;
  if last is not null and now() < last + interval '24 hours' then
    raise exception 'Daily reward not ready yet';
  end if;
  update profiles set balance = balance + 250, last_daily = now()
   where id = auth.uid() returning balance into bal;
  return json_build_object('balance', bal, 'next', now() + interval '24 hours');
end $$;
