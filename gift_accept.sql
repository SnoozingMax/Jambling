-- Jambling: gifts must be accepted. Coins leave the sender right away and sit "pending" until the
-- receiver taps Accept (coins go to them) or Decline (coins go back to the sender).
-- Gifts nobody answers in 24 hours go back to the sender. Run once in Supabase > SQL Editor (safe to run again).

alter table gifts add column if not exists status text not null default 'accepted';   -- old gifts were auto-accepted
alter table gifts add column if not exists answered_at timestamptz;
create index if not exists gifts_pending on gifts (to_id) where status = 'pending';
alter table gifts add column if not exists sender_seen boolean;
update gifts set sender_seen = true where sender_seen is null and status = 'accepted';

-- send any 24h-old pending gifts back
create or replace function _expire_gifts() returns void
language plpgsql security definer set search_path = public as $$
declare g gifts;
begin
  for g in select * from gifts where status = 'pending' and created_at < now() - interval '24 hours' for update skip locked loop
    update gifts set status = 'expired', answered_at = now() where id = g.id;
    update profiles set balance = balance + g.amount where id = g.from_id;
  end loop;
end $$;

create or replace function gift_coins(p_to text, p_amount numeric, p_message text default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  them uuid;
  bal numeric;
  them_name text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if (select banned from profiles where id = me) then raise exception 'Your account is banned'; end if;
  p_amount := round(p_amount, 2);
  p_message := nullif(left(trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g')), 80), '');
  if p_amount is null or p_amount <= 0 or p_amount <> p_amount then raise exception 'Invalid amount'; end if;

  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_to)) and not banned and approved order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_to; end if;
  if them = me then raise exception 'You can''t gift yourself'; end if;

  perform 1 from profiles where id = me for update;
  if gifts_left() <= 0 then raise exception 'You''ve used all 10 gifts for today. Resets at midnight.'; end if;
  select balance into bal from profiles where id = me;
  if bal - p_amount < 1000 then
    raise exception 'You can only gift coins above 1,000 (you can send %)', greatest(0, bal - 1000);
  end if;

  update profiles set balance = balance - p_amount where id = me returning balance into bal;
  insert into gifts (from_id, to_id, amount, message, status) values (me, them, p_amount, p_message, 'pending');
  return json_build_object('balance', bal, 'to', them_name, 'amount', p_amount, 'left', gifts_left(), 'pending', true);
end $$;
revoke execute on function gift_coins(text, numeric, text) from anon;

-- gifts waiting for me to answer
create or replace function my_pending_gifts() returns json
language plpgsql security definer set search_path = public as $$
declare out json;
begin
  perform _expire_gifts();
  select coalesce(json_agg(json_build_object('id', g.id, 'from', p.username, 'amount', g.amount, 'message', g.message, 'at', g.created_at) order by g.created_at), '[]')
    into out from gifts g join profiles p on p.id = g.from_id
   where g.to_id = auth.uid() and g.status = 'pending';
  return out;
end $$;

-- accept (coins to me) or decline (coins back to the sender)
create or replace function answer_gift(p_id uuid, p_accept boolean) returns json
language plpgsql security definer set search_path = public as $$
declare g gifts; bal numeric;
begin
  select * into g from gifts where id = p_id and to_id = auth.uid() for update;
  if not found then raise exception 'Gift not found'; end if;
  if g.status <> 'pending' then raise exception 'That gift was already %', g.status; end if;
  if p_accept then
    update profiles set balance = balance + g.amount where id = auth.uid() returning balance into bal;
    update gifts set status = 'accepted', answered_at = now(), seen = true where id = g.id;
  else
    update profiles set balance = balance + g.amount where id = g.from_id;
    update gifts set status = 'declined', answered_at = now(), seen = true where id = g.id;
    select balance into bal from profiles where id = auth.uid();
  end if;
  return json_build_object('balance', bal, 'accepted', p_accept, 'amount', g.amount);
end $$;

-- senders hear back when their gift is declined or expires
create or replace function my_gift_replies() returns json
language plpgsql security definer set search_path = public as $$
declare out json;
begin
  perform _expire_gifts();
  select coalesce(json_agg(json_build_object('to', p.username, 'amount', g.amount, 'status', g.status) order by g.answered_at), '[]')
    into out from gifts g join profiles p on p.id = g.to_id
   where g.from_id = auth.uid() and g.status in ('accepted', 'declined', 'expired')
     and g.answered_at > now() - interval '7 days' and not coalesce(g.sender_seen, false);
  update gifts set sender_seen = true where from_id = auth.uid() and status in ('accepted', 'declined', 'expired') and not coalesce(sender_seen, false);
  return out;
end $$;

notify pgrst, 'reload schema';
