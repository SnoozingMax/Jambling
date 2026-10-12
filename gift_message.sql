-- Jambling: gifts can have a short message (80 characters). Run once in Supabase > SQL Editor (safe to run again).

alter table gifts add column if not exists message text;

drop function if exists gift_coins(text, numeric);
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
  p_message := nullif(left(trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g')), 80), '');   -- optional note, 80 chars max
  if p_amount is null or p_amount <= 0 or p_amount <> p_amount then raise exception 'Invalid amount'; end if;

  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_to)) and not banned order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_to; end if;
  if them = me then raise exception 'You can''t gift yourself'; end if;

  perform 1 from profiles where id in (me, them) order by id for update;
  if gifts_left() <= 0 then raise exception 'You''ve used all 10 gifts for today. Resets at midnight.'; end if;
  select balance into bal from profiles where id = me;
  if bal - p_amount < 1000 then
    raise exception 'You can only gift coins above 1,000 (you can send %)', greatest(0, bal - 1000);
  end if;

  update profiles set balance = balance - p_amount where id = me returning balance into bal;
  update profiles set balance = balance + p_amount where id = them;
  insert into gifts (from_id, to_id, amount, message) values (me, them, p_amount, p_message);
  return json_build_object('balance', bal, 'to', them_name, 'amount', p_amount, 'left', gifts_left());
end $$;
revoke execute on function gift_coins(text, numeric, text) from anon;

create or replace function my_new_gifts() returns json
language plpgsql security definer set search_path = public as $$
declare
  out json;
begin
  select coalesce(json_agg(json_build_object('from', p.username, 'amount', g.amount, 'message', g.message) order by g.created_at), '[]')
    into out
    from gifts g join profiles p on p.id = g.from_id
   where g.to_id = auth.uid() and not g.seen;
  update gifts set seen = true where to_id = auth.uid() and not seen;
  return out;
end $$;

drop function if exists admin_gift_log(text);
create or replace function admin_gift_log(p_user text default null) returns table(at timestamptz, from_user text, to_user text, amount numeric, message text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query
    select g.created_at, f.username, t.username, g.amount, g.message
    from gifts g join profiles f on f.id = g.from_id join profiles t on t.id = g.to_id
    where coalesce(trim(p_user), '') = ''
       or lower(f.username) = lower(trim(p_user)) or lower(t.username) = lower(trim(p_user))
    order by g.created_at desc
    limit 200;
end $$;
revoke execute on function admin_gift_log(text) from anon;

notify pgrst, 'reload schema';
