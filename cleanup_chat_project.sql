-- Run this ONLY in your CHAT Supabase project, to remove the Jambling stuff that got pasted there by mistake.
drop function if exists gift_coins(text, numeric);
drop function if exists my_new_gifts();
drop table if exists gifts;
drop function if exists ride_start(numeric);
drop function if exists ride_hold(uuid, boolean, int);
drop function if exists ride_stop(uuid, int);
drop function if exists _ride_clamp(ride_rounds, int);
drop function if exists _ride_k(ride_rounds);
drop function if exists _ride_path(bigint, int);
drop table if exists ride_rounds;
drop function if exists chart_poll(uuid, int);
drop function if exists chart_hold(uuid, boolean, int);
drop function if exists chart_cashout(uuid, int);
drop function if exists chart_start(numeric);
drop function if exists _chart_finish(uuid, int);
drop function if exists _chart_settle(uuid, int);
drop function if exists _chart_k(chart_rounds);
drop table if exists chart_rounds;
