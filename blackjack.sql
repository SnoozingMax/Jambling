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
alter table profiles add column if not exists badluck_until timestamptz;
-- your card values: an ace stays null until you pick 1 or 11 (then it's locked)
alter table bj_hands add column if not exists pvals int[];
-- hands from before this update: refund and close
update profiles p set balance = p.balance + h.bet from bj_hands h where h.user_id = p.id and h.status = 'live' and h.pvals is null;
update bj_hands set status = 'done', result = 'void', payout = bet where status = 'live' and pvals is null;

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

create or replace function _bj_val(c int) returns int language sql immutable as $$
  select case when c % 13 = 0 then null when c % 13 >= 9 then 10 else c % 13 + 1 end
$$;
create or replace function _bj_sum(v int[]) returns int language sql immutable as $$
  select coalesce(sum(x), 0)::int from unnest(v) x
$$;
create or replace function _bj_pending(v int[]) returns int[] language sql immutable as $$
  select coalesce(array_agg(i order by i), '{}') from generate_subscripts(v, 1) i where v[i] is null
$$;

-- what the browser is allowed to see
create or replace function _bj_view(h bj_hands) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  bal numeric;
  dview int[];
  pend int[] := _bj_pending(h.pvals);
begin
  select balance into bal from profiles where id = h.user_id;
  dview := case when h.status = 'live' then h.dealer[1:1] else h.dealer end;
  return json_build_object(
    'id', h.id, 'bet', h.bet, 'status', h.status, 'result', h.result, 'payout', h.payout,
    'player', h.player, 'pvals', h.pvals, 'pending', pend,
    'dealer', dview, 'hidden', h.status = 'live',
    'player_total', _bj_sum(h.pvals), 'dealer_total', _bj_total(dview),
    'can_double', h.status = 'live' and array_length(h.player, 1) = 2 and bal >= h.bet and cardinality(pend) = 0,
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
  pt := _bj_sum(h.pvals);
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

-- after any change: bust, or auto-stand on 21 (only once every ace is chosen)
create or replace function _bj_check(p_id uuid) returns bj_hands
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where id = p_id;
  if h.status <> 'live' or cardinality(_bj_pending(h.pvals)) > 0 then return h; end if;
  if _bj_sum(h.pvals) > 21 then return _bj_settle(h.id, 'bust'); end if;
  if _bj_sum(h.pvals) = 21 then return _bj_settle(h.id); end if;
  return h;
end $$;
revoke execute on function _bj_check(uuid) from public, anon, authenticated;

create or replace function bj_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric; h bj_hands; d int[]; dt int; is_bj boolean;
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
  -- bad luck: you get 16, dealer gets 20, and the next cards are all 10s
  if (select badluck_until > clock_timestamp() from profiles where id = auth.uid()) then
    declare tens int[] := array(select c from unnest(d) c where c % 13 >= 9);
            six int := (select c from unnest(d) c where c % 13 = 5 limit 1);
            picked int[];
    begin
      picked := array[tens[1], tens[2], six, tens[3]];
      d := picked || array(select c from unnest(d) c where not (c = any(picked)) order by (c % 13 >= 9) desc, random());
    end;
  end if;
  insert into bj_hands (user_id, bet, deck, player, dealer, pvals)
    values (auth.uid(), p_bet, d[5:], array[d[1], d[3]], array[d[2], d[4]], array[_bj_val(d[1]), _bj_val(d[3])])
    returning * into h;

  is_bj := _bj_total(h.player) = 21;          -- ace + ten is always blackjack
  dt := _bj_total(h.dealer);
  if is_bj then
    update bj_hands set pvals = array[coalesce(pvals[1], 11), coalesce(pvals[2], 11)] where id = h.id;
    h := _bj_settle(h.id, case when dt = 21 then 'push' else 'blackjack' end);
  elsif dt = 21 then
    h := _bj_settle(h.id, 'lose');
  end if;
  return _bj_view(h);
end $$;

-- pick 1 or 11 for one of your aces (locked once picked)
create or replace function bj_ace(p_id uuid, p_idx int, p_val int) returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid() for update;
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  if p_val not in (1, 11) then raise exception 'Ace must be 1 or 11'; end if;
  if p_idx is null or p_idx < 1 or p_idx > cardinality(h.player) or h.player[p_idx] % 13 <> 0 then raise exception 'That card isn''t an ace'; end if;
  if h.pvals[p_idx] is not null then raise exception 'That ace is already locked'; end if;
  h.pvals[p_idx] := p_val;
  update bj_hands set pvals = h.pvals where id = h.id;
  return _bj_view(_bj_check(h.id));
end $$;

create or replace function bj_hit(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid() for update;
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  if cardinality(_bj_pending(h.pvals)) > 0 then raise exception 'Pick 1 or 11 for your ace first'; end if;
  update bj_hands set player = player || deck[1], pvals = pvals || _bj_val(deck[1]), deck = deck[2:] where id = h.id;
  return _bj_view(_bj_check(h.id));
end $$;

create or replace function bj_stand(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid();
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  if cardinality(_bj_pending(h.pvals)) > 0 then raise exception 'Pick 1 or 11 for your ace first'; end if;
  return _bj_view(_bj_settle(h.id));
end $$;

create or replace function bj_double(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  h bj_hands; bal numeric; c int; v int;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid() for update;
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  if array_length(h.player, 1) <> 2 then raise exception 'You can only double on your first two cards'; end if;
  if cardinality(_bj_pending(h.pvals)) > 0 then raise exception 'Pick 1 or 11 for your ace first'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < h.bet then raise exception 'Not enough coins to double'; end if;
  update profiles set balance = balance - h.bet where id = auth.uid();
  c := h.deck[1];
  v := coalesce(_bj_val(c), case when _bj_sum(h.pvals) + 11 <= 21 then 11 else 1 end);   -- an ace on a double picks the best value
  update bj_hands set bet = bet * 2, player = player || c, pvals = pvals || v, deck = deck[2:] where id = h.id;
  return _bj_view(_bj_settle(h.id, case when _bj_sum(h.pvals) + v > 21 then 'bust' end));
end $$;

-- resume a hand after closing the tab
create or replace function bj_current() returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where user_id = auth.uid() and status = 'live' order by created_at desc limit 1;
  if not found then return null; end if;
  return _bj_view(h);
end $$;

notify pgrst, 'reload schema';
