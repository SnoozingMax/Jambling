-- Jambling: gifting. Run once in Supabase > SQL Editor (safe to run again).
-- You can only gift coins above 1,000 (stops alt accounts farming Refill and funneling coins).

create table if not exists gifts (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references profiles(id) on delete cascade,
  to_id uuid not null references profiles(id) on delete cascade,
  amount numeric not null,
  created_at timestamptz not null default now(),
  seen boolean not null default false
);
alter table gifts enable row level security;  -- only the functions below touch it

create or replace function gift_coins(p_to text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  them uuid;
  bal numeric;
  them_name text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount <= 0 then raise exception 'Invalid amount'; end if;

  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_to)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_to; end if;
  if them = me then raise exception 'You can''t gift yourself'; end if;

  -- lock both rows in a fixed order so two gifts at once can't deadlock
  perform 1 from profiles where id in (me, them) order by id for update;
  select balance into bal from profiles where id = me;
  if bal - p_amount < 1000 then
    raise exception 'You can only gift coins above 1,000 (you can send %)', greatest(0, bal - 1000);
  end if;

  update profiles set balance = balance - p_amount where id = me returning balance into bal;
  update profiles set balance = balance + p_amount where id = them;
  insert into gifts (from_id, to_id, amount) values (me, them, p_amount);
  return json_build_object('balance', bal, 'to', them_name, 'amount', p_amount);
end $$;

-- gifts you received that you haven't seen yet (marks them seen)
create or replace function my_new_gifts() returns json
language plpgsql security definer set search_path = public as $$
declare
  out json;
begin
  select coalesce(json_agg(json_build_object('from', p.username, 'amount', g.amount) order by g.created_at), '[]')
    into out
    from gifts g join profiles p on p.id = g.from_id
   where g.to_id = auth.uid() and not g.seen;
  update gifts set seen = true where to_id = auth.uid() and not seen;
  return out;
end $$;
