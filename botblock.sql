-- Jambling: auto-ban bots. Run once in Supabase > SQL Editor (safe to run again).
-- Spots random-letter names (like "wgnflqttggw") and bans them.

alter table profiles add column if not exists banned boolean not null default false;

create or replace function _is_bot_name(n text) returns boolean
language sql immutable as $$
  select n ~ '^[a-z]{10,}$' and (                                   -- 10+ lowercase letters only
       n ~ '[bcdfghjklmnpqrstvwxyz]{4}'                             -- 4 consonants in a row
    or n ~ 'q[^u]'                                                  -- q without u
    or length(regexp_replace(n, '[^aeiou]', '', 'g'))::float8 / length(n) < 0.25   -- barely any vowels
  )
$$;

-- new bot sign-ups get banned instantly
create or replace function _ban_bot_signup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if _is_bot_name(coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1))) then
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
  bot boolean := _is_bot_name(nm);
begin
  insert into profiles (id, username, banned, balance)
  values (new.id, nm, bot, case when bot then 0 else 1000 end);
  return new;
end $$;

-- ban the bots already here (only untouched accounts: still at 1000 coins, no rebirths)
with b as (
  update profiles set banned = true
  where _is_bot_name(username) and balance = 1000 and rebirths = 0 and not banned
  returning id, username
), a as (
  update auth.users set banned_until = 'infinity' where id in (select id from b)
)
select username as banned_now from b order by username;
