-- Jambling: fix 'record "m" has no field "a_hp"'. Adds the 1v1 columns your database is missing. Run once.
alter table pvp_matches add column if not exists a_hp int not null default 100;
alter table pvp_matches add column if not exists b_hp int not null default 100;
alter table pvp_matches add column if not exists round int not null default 1;
alter table pvp_matches add column if not exists log jsonb not null default '[]';
alter table pvp_matches add column if not exists ax numeric;
alter table pvp_matches add column if not exists bx numeric;
alter table pvp_matches add column if not exists rt_start timestamptz;
alter table pvp_matches add column if not exists a_hit_at timestamptz;
alter table pvp_matches add column if not exists b_hit_at timestamptz;
notify pgrst, 'reload schema';
