-- Martigal Promotion: full database setup.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- Safe to run once on a fresh project.

create extension if not exists pgcrypto;

-- ============ SETTINGS (single row, edited from the admin panel) ============
create table public.settings (
  id int primary key default 1 check (id = 1),
  reward_kes numeric not null default 25 check (reward_kes >= 0),
  daily_cap int not null default 5 check (daily_cap >= 0),
  offers_per_week int not null default 2,
  offer_reward_kes numeric not null default 20,
  ref_reward_kes numeric not null default 1300,   -- about 10 USD at 130
  ref_target int not null default 20,
  usd_rate numeric not null default 130 check (usd_rate > 0),
  min_withdraw numeric not null default 500,
  budget_kes numeric not null default 100000,
  withdraw_date date,
  banner text
);
insert into public.settings (id) values (1);

-- ============ PROFILES ============
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  email text not null,
  phone text not null check (phone ~ '^\+?[0-9]{9,15}$'),
  country text,
  ref_code text not null unique default encode(gen_random_bytes(4), 'hex'),
  referred_by uuid references public.profiles(id),
  role text not null default 'user' check (role in ('user','admin')),
  status text not null default 'active' check (status in ('active','suspended')),
  suspicious boolean not null default false,
  last_seen timestamptz,
  signup_ip text,
  device_fp text,
  created_at timestamptz not null default now()
);
create unique index profiles_username_ci on public.profiles (lower(username));
create unique index profiles_email_ci on public.profiles (lower(email));
create unique index profiles_phone_uq on public.profiles (phone);
create index profiles_referred_by_idx on public.profiles (referred_by);
create index profiles_device_idx on public.profiles (device_fp);

-- Creates the profile automatically when someone signs up.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb); ref uuid;
begin
  select id into ref from public.profiles where ref_code = nullif(m->>'ref', '');
  insert into public.profiles (id, username, email, phone, country, referred_by)
  values (new.id, m->>'username', new.email,
          regexp_replace(coalesce(m->>'phone', ''), '[^0-9+]', '', 'g'),
          m->>'country', ref);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;

-- ============ WITHDRAWALS + WINDOWS ============
create table public.withdrawal_windows (
  id bigint generated always as identity primary key,
  opens_on date not null,
  closes_on date not null,
  created_at timestamptz not null default now()
);

create table public.withdrawals (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  mpesa text not null,
  amount numeric not null check (amount > 0),
  status text not null default 'requested' check (status in ('requested','paid','rejected')),
  reason text,
  window_id bigint references public.withdrawal_windows(id),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index withdrawals_user_idx on public.withdrawals (user_id, id desc);
create index withdrawals_status_idx on public.withdrawals (status);

-- Setting a withdrawal date in admin opens a window: that day plus 2 more days.
create function public.open_window() returns trigger language plpgsql as $$
begin
  if new.withdraw_date is not null and new.withdraw_date is distinct from old.withdraw_date then
    insert into public.withdrawal_windows (opens_on, closes_on)
    values (new.withdraw_date, new.withdraw_date + 2);
  end if;
  return new;
end $$;
create trigger settings_open_window after update on public.settings
  for each row execute function public.open_window();

-- ============ LEDGER (every credit is a row; balances are sums) ============
create table public.ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('ad','offer','referral')),
  amount numeric not null check (amount > 0),
  -- pending = waiting admin approval, approved = available to withdraw,
  -- requested = in a withdrawal request, paid, rejected
  status text not null default 'pending'
    check (status in ('pending','approved','requested','paid','rejected')),
  txn_id text not null unique,            -- blocks duplicate postbacks
  withdrawal_id bigint references public.withdrawals(id),
  note text,
  created_at timestamptz not null default now()
);
create index ledger_user_idx on public.ledger (user_id, created_at desc);
create index ledger_status_idx on public.ledger (status);

-- ============ AD VIEWS, OFFERS, REFERRALS ============
create table public.ad_views (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  txn_id text not null unique,
  ip text,
  created_at timestamptz not null default now()
);
create index ad_views_user_idx on public.ad_views (user_id, created_at desc);

create table public.offers (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  txn_id text not null unique,
  network text,
  created_at timestamptz not null default now()
);
create index offers_user_idx on public.offers (user_id, created_at desc);

create table public.referrals (
  id bigint generated always as identity primary key,
  referrer_id uuid not null references public.profiles(id) on delete cascade,
  referred_id uuid not null unique references public.profiles(id) on delete cascade,
  verified_at timestamptz not null default now()
);
create index referrals_referrer_idx on public.referrals (referrer_id);

-- ============ SERVER-ONLY CREDIT FUNCTIONS (called by the Edge Function) ============
-- Returns: credited | duplicate | capped | budget | blocked
create function public.credit_ad(p_user uuid, p_txn text, p_ip text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s public.settings; p public.profiles; r public.profiles; today int; spent numeric; n int;
begin
  select * into s from settings where id = 1;
  select * into p from profiles where id = p_user for update;
  if not found or p.status <> 'active' then return 'blocked'; end if;
  if exists (select 1 from ad_views where txn_id = p_txn) then return 'duplicate'; end if;

  select count(*) into today from ad_views
   where user_id = p_user and (created_at at time zone 'utc')::date = (now() at time zone 'utc')::date;
  if today >= s.daily_cap then return 'capped'; end if;

  perform pg_advisory_xact_lock(7001);
  select coalesce(sum(amount), 0) into spent from ledger where status <> 'rejected';
  if spent + s.reward_kes > s.budget_kes then return 'budget'; end if;

  insert into ad_views (user_id, txn_id, ip) values (p_user, p_txn, p_ip) on conflict do nothing;
  if not found then return 'duplicate'; end if;
  insert into ledger (user_id, kind, amount, txn_id) values (p_user, 'ad', s.reward_kes, 'ad-' || p_txn);

  -- Referral counts only after the new user's first full ad view.
  if p.referred_by is not null and not exists (select 1 from referrals where referred_id = p.id) then
    select * into r from profiles where id = p.referred_by;
    if found and r.id <> p.id and r.status = 'active'
       and (p.device_fp is null or r.device_fp is distinct from p.device_fp) then
      insert into referrals (referrer_id, referred_id) values (r.id, p.id);
      select count(*) into n from referrals where referrer_id = r.id;
      if n % s.ref_target = 0 then
        insert into ledger (user_id, kind, amount, txn_id, note)
        values (r.id, 'referral', s.ref_reward_kes, 'ref-' || r.id || '-' || n,
                'Bonus for ' || n || ' verified referrals')
        on conflict do nothing;
      end if;
    elsif found then
      update profiles set suspicious = true where id = p.id;  -- same device as referrer
    end if;
  end if;
  return 'credited';
end $$;

create function public.credit_offer(p_user uuid, p_txn text, p_network text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s public.settings; p public.profiles; wk int; spent numeric;
begin
  select * into s from settings where id = 1;
  select * into p from profiles where id = p_user for update;
  if not found or p.status <> 'active' then return 'blocked'; end if;
  if exists (select 1 from offers where txn_id = p_txn) then return 'duplicate'; end if;
  select count(*) into wk from offers where user_id = p_user and created_at > now() - interval '7 days';
  if wk >= s.offers_per_week then return 'capped'; end if;
  perform pg_advisory_xact_lock(7001);
  select coalesce(sum(amount), 0) into spent from ledger where status <> 'rejected';
  if spent + s.offer_reward_kes > s.budget_kes then return 'budget'; end if;
  insert into offers (user_id, txn_id, network) values (p_user, p_txn, p_network) on conflict do nothing;
  if not found then return 'duplicate'; end if;
  insert into ledger (user_id, kind, amount, txn_id) values (p_user, 'offer', s.offer_reward_kes, 'offer-' || p_txn);
  return 'credited';
end $$;

-- ============ FUNCTIONS THE WEBSITE CALLS ============
create function public.touch() returns void language sql security definer set search_path = public as $$
  update profiles set last_seen = now() where id = auth.uid()
$$;

create function public.my_refs() returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from referrals where referrer_id = auth.uid()
$$;

create function public.request_withdraw(m text) returns void
language plpgsql security definer set search_path = public as $$
declare s public.settings; p public.profiles; win public.withdrawal_windows; tot numeric; wid bigint;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found or p.status <> 'active' then raise exception 'Your account cannot withdraw right now'; end if;
  if m !~ '^\+?[0-9]{9,15}$' then raise exception 'Enter a valid M-Pesa number'; end if;
  select * into win from withdrawal_windows
   where current_date between opens_on and closes_on order by id desc limit 1;
  if not found then raise exception 'No withdrawal window is open right now'; end if;
  select * into s from settings where id = 1;
  select coalesce(sum(amount), 0) into tot from ledger where user_id = p.id and status = 'approved';
  if tot < s.min_withdraw then
    raise exception 'Minimum withdrawal is % KES. Your approved balance is % KES', s.min_withdraw, tot;
  end if;
  insert into withdrawals (user_id, mpesa, amount, window_id) values (p.id, m, tot, win.id) returning id into wid;
  update ledger set status = 'requested', withdrawal_id = wid where user_id = p.id and status = 'approved';
end $$;

-- Admin: mark a withdrawal paid or rejected (reason is shown to the user).
create function public.admin_set_withdrawal(w bigint, s text, r text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  if s not in ('paid', 'rejected') then raise exception 'Bad status'; end if;
  if s = 'rejected' and coalesce(trim(r), '') = '' then raise exception 'A reason is required'; end if;
  update withdrawals set status = s, reason = case when s = 'rejected' then r end, decided_at = now()
   where id = w and status = 'requested';
  if not found then raise exception 'Withdrawal not found or already decided'; end if;
  if s = 'paid' then
    update ledger set status = 'paid' where withdrawal_id = w;
  else
    update ledger set status = 'approved', withdrawal_id = null where withdrawal_id = w; -- back to available
  end if;
end $$;

-- Admin: approve or reject pending earnings, single or bulk.
create function public.admin_set_earnings(ids bigint[], s text, r text default null) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  if s not in ('approved', 'rejected') then raise exception 'Bad status'; end if;
  update ledger set status = s, note = coalesce(r, note) where id = any(ids) and status = 'pending';
  get diagnostics n = row_count;
  return n;
end $$;

-- ============ ROW LEVEL SECURITY ============
alter table public.settings enable row level security;
alter table public.profiles enable row level security;
alter table public.ledger enable row level security;
alter table public.ad_views enable row level security;
alter table public.offers enable row level security;
alter table public.referrals enable row level security;
alter table public.withdrawals enable row level security;
alter table public.withdrawal_windows enable row level security;

create policy settings_read on public.settings for select to anon, authenticated using (true);
create policy settings_admin_update on public.settings for update to authenticated
  using (is_admin()) with check (is_admin());
create policy windows_read on public.withdrawal_windows for select to authenticated using (true);

create policy profiles_read on public.profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy profiles_admin_update on public.profiles for update to authenticated
  using (is_admin()) with check (is_admin());
create policy ledger_read on public.ledger for select to authenticated using (user_id = auth.uid() or is_admin());
create policy ad_views_read on public.ad_views for select to authenticated using (user_id = auth.uid() or is_admin());
create policy offers_read on public.offers for select to authenticated using (user_id = auth.uid() or is_admin());
create policy referrals_read on public.referrals for select to authenticated using (referrer_id = auth.uid() or is_admin());
create policy withdrawals_read on public.withdrawals for select to authenticated using (user_id = auth.uid() or is_admin());

-- Lock down privileges: the browser can only read, plus admin updates.
revoke all on all tables in schema public from anon, authenticated;
grant select on public.settings, public.withdrawal_windows to anon;
grant select on all tables in schema public to authenticated;
grant update on public.settings to authenticated;
grant update (status, suspicious) on public.profiles to authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.is_admin(), public.touch(), public.my_refs(),
  public.request_withdraw(text), public.admin_set_withdrawal(bigint, text, text),
  public.admin_set_earnings(bigint[], text, text) to authenticated;
grant execute on function public.credit_ad(uuid, text, text), public.credit_offer(uuid, text, text) to service_role;

-- ============ AFTER YOU SIGN UP YOUR OWN ACCOUNT ON THE SITE ============
-- Make yourself admin (replace the email, run this alone):
-- update public.profiles set role = 'admin' where lower(email) = lower('you@example.com');
