-- Jambling: rebirths get harder each time. 1st = 50k, 2nd = 100k, 3rd = 150k, +50k each time.
-- Run once in Supabase > SQL Editor (safe to run again).

create or replace function _rebirth_cost(p_done int) returns numeric
language sql immutable as $$ select 50000::numeric * (coalesce(p_done, 0) + 1) $$;

create or replace function rebirth() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  rb int;
  cost numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select balance, rebirths into bal, rb from profiles where id = auth.uid() for update;
  cost := _rebirth_cost(rb);
  if bal < cost then raise exception 'You need % coins for rebirth ▲%', to_char(cost, 'FM999,999,999,999'), rb + 1; end if;
  update profiles set balance = 1000, rebirths = rebirths + 1 where id = auth.uid()
    returning balance, rebirths into bal, rb;
  return json_build_object('balance', bal, 'rebirths', rb, 'next_cost', _rebirth_cost(rb));
end $$;

notify pgrst, 'reload schema';
