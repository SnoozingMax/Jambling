-- Jambling: leaderboard-banned (and banned) players don't show on the Obby fastest-runs board. Run once in Supabase > SQL Editor.
-- Their times are kept, so unbanning them puts them back.
create or replace function obby_top() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('username', username, 'secs', secs, 'deaths', deaths, 'coins', coins, 'me', user_id = auth.uid())), '[]'::json)
  from (select r.* from obby_runs r join profiles p on p.id = r.user_id
        where not coalesce(p.board_hidden, false) and not coalesce(p.banned, false)
        order by r.secs asc, r.updated_at asc limit 10) t
$$;
grant execute on function obby_top() to authenticated;
notify pgrst, 'reload schema';
