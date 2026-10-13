-- Jambling: leaderboard banned players can't send gifts. Run once in Supabase > SQL Editor (after gift_accept.sql + board_ban.sql).

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
  if (select board_hidden from profiles where id = me) then raise exception 'Leaderboard banned players can''t send gifts'; end if;
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

notify pgrst, 'reload schema';
