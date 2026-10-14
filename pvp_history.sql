-- Jambling: 1v1 record + recent matches. Run once in Supabase > SQL Editor (safe to run again).
create or replace function pvp_history() returns json
language sql stable security definer set search_path = public as $$
  with mine as (
    select m.*, case when m.a = auth.uid() then m.b else m.a end as opp_id,
           case when m.winner is null then 'tie' when m.winner = auth.uid() then 'win' else 'lose' end as outcome
    from pvp_matches m
    where (m.a = auth.uid() or m.b = auth.uid()) and m.status = 'done'
  )
  select json_build_object(
    'wins',   (select count(*) from mine where outcome = 'win'),
    'losses', (select count(*) from mine where outcome = 'lose'),
    'ties',   (select count(*) from mine where outcome = 'tie'),
    'net',    (select coalesce(sum(case when friendly then 0 when outcome = 'win' then stake when outcome = 'lose' then -stake else 0 end), 0) from mine),
    'recent', (select coalesce(json_agg(r order by r.at desc), '[]') from (
                 select x.created_at as at, p.username as opp, x.friendly, x.stake, x.outcome
                 from mine x join profiles p on p.id = x.opp_id
                 order by x.created_at desc limit 8) r)
  )
$$;
revoke execute on function pvp_history() from anon;
notify pgrst, 'reload schema';
