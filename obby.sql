-- Jambling: Obby best times leaderboard. Run once in Supabase > SQL Editor.
create table if not exists obby_runs (
  user_id uuid primary key references profiles(id) on delete cascade,
  username text not null, secs numeric not null, deaths int not null default 0, coins int not null default 0,
  runs int not null default 1, updated_at timestamptz not null default now()
);
alter table obby_runs enable row level security;   -- no policies: only the functions touch it

create or replace function obby_finish(p_secs numeric, p_deaths int, p_coins int) returns json
language plpgsql security definer set search_path = public as $$
declare n text; best numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_secs is null or p_secs < 20 or p_secs > 36000 then raise exception 'Bad time'; end if;
  select username into n from profiles where id = auth.uid();
  insert into obby_runs (user_id, username, secs, deaths, coins) values (auth.uid(), n, p_secs, coalesce(p_deaths, 0), coalesce(p_coins, 0))
  on conflict (user_id) do update set runs = obby_runs.runs + 1, username = excluded.username, updated_at = now(),
    secs = least(obby_runs.secs, excluded.secs),
    deaths = case when excluded.secs < obby_runs.secs then excluded.deaths else obby_runs.deaths end,
    coins = greatest(obby_runs.coins, excluded.coins);
  select secs into best from obby_runs where user_id = auth.uid();
  return json_build_object('best', best, 'rank', (select count(*) + 1 from obby_runs where secs < best));
end $$;
revoke execute on function obby_finish(numeric, int, int) from anon;
grant execute on function obby_finish(numeric, int, int) to authenticated;

create or replace function obby_top() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('username', username, 'secs', secs, 'deaths', deaths, 'coins', coins, 'me', user_id = auth.uid())), '[]'::json)
  from (select * from obby_runs order by secs asc, updated_at asc limit 10) t
$$;
grant execute on function obby_top() to authenticated;

notify pgrst, 'reload schema';
