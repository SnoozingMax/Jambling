-- Jambling: bot ban v2 + refill to 500. Run once in Supabase > SQL Editor (safe to run again).
-- 1) bans every bot name from your screenshots (even ones that already played)
-- 2) smarter auto-ban for new sign-ups: gibberish letter combos, or a burst of
--    random lowercase names signing up within a few minutes of each other

alter table profiles add column if not exists banned boolean not null default false;

-- letter pairs that almost never show up in real words or names
create or replace function _rare_pairs() returns text[] language sql immutable as $$
  select array[
    'aa','aj','ao','aq','bf','bg','bh','bk','bn','bp','bq','bv','bw','bx','bz','cb',
    'cd','cf','cg','cj','cm','cn','cp','cq','cv','cw','cx','cz','dk','dq','dx','dz',
    'ej','ez','fd','fh','fj','fk','fm','fn','fp','fq','fv','fw','fx','fz','gj','gk',
    'gq','gv','gx','gz','hg','hj','hk','hq','hv','hx','hz','ih','ii','ij','iq','iu',
    'iw','iy','jb','jc','jd','jf','jg','jh','jj','jk','jl','jm','jn','jq','jt','jv',
    'jw','jx','jy','jz','kj','kq','kv','kx','kz','lh','lj','lq','lx','lz','md','mg',
    'mh','mj','mk','mq','mt','mv','mw','mx','mz','nq','nx','nz','oj','oq','oz','pg',
    'pj','pk','pn','pq','pv','pw','px','pz','qd','qe','qf','qg','qh','qj','qk','qm',
    'qn','qo','qq','qr','qs','qt','qv','qw','qx','qy','qz','rj','rq','rx','rz','sj',
    'sv','sx','sz','tg','tj','tk','tq','tv','tx','tz','uh','uj','uq','uu','uv','uw',
    'ux','uz','vb','vc','vd','vf','vg','vh','vj','vk','vl','vm','vn','vp','vq','vr',
    'vt','vu','vv','vw','vx','vz','wg','wj','wq','wu','wv','wx','wz','xg','xj','xk',
    'xn','xq','xw','xz','yq','yx','yy','zc','zg','zj','zk','zm','zn','zq','zt','zv',
    'zw','zx'
  ]
$$;

create or replace function _is_bot_name(n text) returns boolean
language plpgsql immutable as $$
declare rare text[] := _rare_pairs(); c int := 0;
begin
  if n is null or n !~ '^[a-z]{10,}$' then return false; end if;   -- only 10+ lowercase letters
  if lower(n) in ('laobaoshiangeko', 'israelistorage') then return false; end if;
  if n ~ 'q[^u]' then return true; end if;
  for i in 1 .. length(n) - 1 loop
    if substr(n, i, 2) = any(rare) then c := c + 1; end if;
  end loop;
  return c >= 2;
end $$;

create or replace function _is_bot_signup(n text) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if _is_bot_name(n) then return true; end if;
  -- burst: 3+ other random lowercase names in the last 10 minutes
  return n ~ '^[a-z]{10,}$' and (
    select count(*) from profiles
    where username ~ '^[a-z]{10,}$' and created_at > now() - interval '10 minutes'
  ) >= 3;
end $$;

create or replace function _ban_bot_signup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if _is_bot_signup(coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1))) then
    new.banned_until := 'infinity';
  end if;
  return new;
end $$;
drop trigger if exists ban_bot_signup on auth.users;
create trigger ban_bot_signup before insert on auth.users
for each row execute function _ban_bot_signup();

create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  nm text := coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1));
  bot boolean := coalesce(new.banned_until = 'infinity', false);
begin
  insert into profiles (id, username, banned, balance)
  values (new.id, nm, bot, case when bot then 0 else 1000 end);
  return new;
end $$;

-- ban the bots from your screenshots + anything else the checker flags
with b as (
  update profiles set banned = true
  where not banned and rebirths = 0 and (
    lower(username) in (
    'ygftdvtqohtqxh','dtbxvahpimawrjshenkq','mqvtwragqkcsfhqtuir','yeinfggdxnirkwxl','ttoofpksbrvbfazeuwm','snbztjswmnr',
    'lsgfaaaopeo','xpdovtjwuttclukpzxij','vhshrnhqzkykflf','iyzmuynvtmbvehdab','ejnhtukrynumshrtccx','aoqjrxkfvcosdi',
    'pkjrexdtayblwrjb','yxkiauihvljfurenx','fpaznkvqmopzmvpc','snmwoucwmtspmixpcrt','yzxhpcumdgzbw','ujefthpkylyvgigebza',
    'ezmimurnyzlneom','oryrupymwqzfpptfn','dzxbfqkthkohf','xntubdlayvy','rhxhpenfdosiveqwzj','igltyerliju',
    'qorjxrallxqegza','fkfkdwlseawmn','ypcncwutbagnegungqrx','xklkloabxlgdyus','xrrblkqqdttdzjsvu','gxfebbbxuabczzie',
    'drwebhiqpsa','crxxdbxscslauzlkguzj','exoxwinkzrpcswon','tzvsuklvuxokmdgabqk','zobmztbeywbzjwllz','tydtqswaiibdp',
    'fsmgysfqtajxlxzkldl','bodkpiphilpfwbffaga','esbenerksskkqwvr','xnfvfrqcfucmzgffoj','udqergmzknqqsqitz','qnsoymzusct',
    'zfrlofuawedfnbep','ommbhzkximropdkr','hhqldfkpzmslhdzumf','rzgyqiiomhiliudv','uvxqjzyhawilxllthuwh','xdadhsoqrsdwx',
    'utefchlejvqttuym','eglmcmxqambvgi','ugkyzonbcqotrauubwgy','ryxihnalirrlsrfci','anpaapqhgnzifpmmat','sfnujesjwcxptjqtj',
    'myrqzpglcjfuqymh','spoacqurfzgarsvohxb','yakencbrcuny','ztbwazohonkeoslyzys','xapljmgnsnumyis','cxhbrspkjgmgu',
    'cyoxrlujnyaonoi','bozcwusilesedm','jcleuyutarxekd','gozyejfyepgacf','eidvulflouji','digyevxkobuzkmi',
    'hvmeuwwceemev','odgegctiumebaa','rjreokrhekzo','rfidwyurvex','dtwujufoekyihro','wgnflqttggw',
    'xontwhbpkglhaieyzuh','hxjimzervezvcd','jlehzrguozsvlwkroh','bpoccroyovriinfvrr','higqqosjwhylgztxp','yjxjmvramfdnrdfnrta',
    'hqeddaakuqeycop','erankeyxptkbxshruqt','gkiqnpynpktpajp','lctmffybqoteqae','pewrmkfvbogoxhpgkze','mexiuthxqmflb',
    'pyadkjjtcucbcj','qjjiyolpxbg','qhbvqkuhcqjpikklrip','uvxecqotdpjneiwbbiru','lbzbmiexaqge','yueecbakqopzraavjaa',
    'jxbsibdoiznphnje','ecffewelyrpaqwmeaf','hpprwvegcmdma','mnxwfopxawoiqatg','axybukjddkpugzceuo','monosokogyoriokyzf',
    'crudvhccbiei','oqwqabcymjh','vnqftqzlfqfilzrnwvnr','umzywyciflplwnpw','cwsyprdcuclo','ebhniawlmbxtoplj',
    'xiztlrsjnxpkxa'
    ) or _is_bot_name(username)
  )
  returning id, username
), a as (
  update auth.users set banned_until = 'infinity' where id in (select id from b)
)
select count(*) as banned_now from b;

-- refill now gives 500
create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  bal numeric;
begin
  if me is null then raise exception 'Not signed in'; end if;

  -- tidy up leftovers from closed tabs
  perform ride_cleanup();
  update crash_rounds set status = 'crashed'
   where user_id = me and status = 'live'
     and extract(epoch from clock_timestamp() - started_at) >= ln(crash_point) / 0.09;

  if exists (select 1 from crash_rounds where user_id = me and status = 'live') then
    raise exception 'Your Rocket round is still flying. Cash out or let it crash first.';
  end if;
  if exists (select 1 from ride_rounds where user_id = me and status = 'live') then
    raise exception 'Stop your Ride round first.';
  end if;
  if exists (select 1 from bj_hands where user_id = me and status = 'live') then
    raise exception 'Finish your Blackjack hand first (it''s waiting in the Blackjack tab).';
  end if;

  select balance into bal from profiles where id = me;
  if bal >= 10 then raise exception 'Refill only works under 10 coins (you have %)', round(bal, 2); end if;
  update profiles set balance = 500 where id = me returning balance into bal;
  return json_build_object('balance', bal);
end $$;

notify pgrst, 'reload schema';
