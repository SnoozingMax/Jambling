-- Jambling: Blackjack + remove Refill. Run once in Supabase > SQL Editor (safe to run again).
-- The deck and the dealer's hidden card stay on the server.

drop function if exists claim_refill();

create table if not exists bj_hands (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null,
  deck int[] not null,
  player int[] not null default '{}',
  dealer int[] not null default '{}',
  status text not null default 'live',   -- live | done
  result text,
  payout numeric,
  created_at timestamptz not null default now()
);
alter table bj_hands enable row level security;   -- no policies: only functions touch it

-- card c: rank = c % 13 (0 = A, 1..9 = 2..10, 10..12 = J Q K)
create or replace function _bj_total(cards int[]) returns int
language plpgsql immutable as $$
declare
  t int := 0; aces int := 0; r int;
begin
  foreach r in array coalesce(cards, '{}') loop
    r := r % 13;
    if r = 0 then aces := aces + 1; t := t + 11;
    elsif r >= 9 then t := t + 10;
    else t := t + r + 1; end if;
  end loop;
  while t > 21 and aces > 0 loop t := t - 10; aces := aces - 1; end loop;
  return t;
end $$;

-- what the browser is allowed to see
create or replace function _bj_view(h bj_hands) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  bal numeric;
  dview int[];
begin
  select balance into bal from profiles where id = h.user_id;
  dview := case when h.status = 'live' then h.dealer[1:1] else h.dealer end;
  return json_build_object(
    'id', h.id, 'bet', h.bet, 'status', h.status, 'result', h.result, 'payout', h.payout,
    'player', h.player, 'dealer', dview, 'hidden', h.status = 'live',
    'player_total', _bj_total(h.player), 'dealer_total', _bj_total(dview),
    'can_double', h.status = 'live' and array_length(h.player, 1) = 2 and bal >= h.bet,
    'balance', bal);
end $$;

-- dealer plays, hand is settled and paid (internal)
create or replace function _bj_settle(p_id uuid, p_result text default null) returns bj_hands
language plpgsql security definer set search_path = public as $$
declare
  h bj_hands; pt int; dt int; res text; pay numeric := 0; luck numeric;
begin
  select * into h from bj_hands where id = p_id for update;
  if h.status <> 'live' then return h; end if;
  pt := _bj_total(h.player);
  res := p_result;
  if res is null then
    if pt > 21 then res := 'bust';
    else
      while _bj_total(h.dealer) < 17 loop h.dealer := h.dealer || h.deck[1]; h.deck := h.deck[2:]; end loop;
      dt := _bj_total(h.dealer);
      res := case when dt > 21 or pt > dt then 'win' when pt = dt then 'push' else 'lose' end;
    end if;
  end if;
  luck := 1 + 0.1 * coalesce((select rebirths from profiles where id = h.user_id), 0);
  pay := case res
    when 'blackjack' then round(h.bet + h.bet * 1.5 * luck, 2)
    when 'win'       then round(h.bet + h.bet * luck, 2)
    when 'push'      then h.bet
    else 0 end;
  update bj_hands set dealer = h.dealer, deck = h.deck, status = 'done', result = res, payout = pay where id = h.id
    returning * into h;
  update profiles set balance = balance + pay where id = h.user_id;
  return h;
end $$;
revoke execute on function _bj_settle(uuid, text) from public, anon, authenticated;
revoke execute on function _bj_view(bj_hands) from public, anon, authenticated;

create or replace function bj_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric; h bj_hands; d int[]; pt int; dt int;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from bj_hands where user_id = auth.uid() and status = 'live') then
    raise exception 'Finish your current hand first';
  end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid();

  select array_agg(c order by random()) into d from generate_series(0, 51) c;
  insert into bj_hands (user_id, bet, deck, player, dealer)
    values (auth.uid(), p_bet, d[5:], array[d[1], d[3]], array[d[2], d[4]]) returning * into h;

  pt := _bj_total(h.player); dt := _bj_total(h.dealer);
  if pt = 21 or dt = 21 then
    h := _bj_settle(h.id, case when pt = 21 and dt = 21 then 'push' when pt = 21 then 'blackjack' else 'lose' end);
  end if;
  return _bj_view(h);
end $$;

create or replace function bj_hit(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  h bj_hands;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid() for update;
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  update bj_hands set player = player || deck[1], deck = deck[2:] where id = h.id returning * into h;
  if _bj_total(h.player) > 21 then h := _bj_settle(h.id, 'bust');
  elsif _bj_total(h.player) = 21 then h := _bj_settle(h.id); end if;   -- auto-stand on 21
  return _bj_view(h);
end $$;

create or replace function bj_stand(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  h bj_hands;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid();
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  h := _bj_settle(h.id);
  return _bj_view(h);
end $$;

create or replace function bj_double(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  h bj_hands; bal numeric;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid() for update;
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  if array_length(h.player, 1) <> 2 then raise exception 'You can only double on your first two cards'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < h.bet then raise exception 'Not enough coins to double'; end if;
  update profiles set balance = balance - h.bet where id = auth.uid();
  update bj_hands set bet = bet * 2, player = player || deck[1], deck = deck[2:] where id = h.id;
  h := _bj_settle(h.id, case when _bj_total((select player from bj_hands where id = h.id)) > 21 then 'bust' end);
  return _bj_view(h);
end $$;

-- resume a hand after closing the tab
create or replace function bj_current() returns json
language plpgsql security definer set search_path = public as $$
declare
  h bj_hands;
begin
  select * into h from bj_hands where user_id = auth.uid() and status = 'live' order by created_at desc limit 1;
  if not found then return null; end if;
  return _bj_view(h);
end $$;

notify pgrst, 'reload schema';
