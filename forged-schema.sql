-- ============================================================================
-- FORGED — database schema (Supabase / Postgres)
-- Safe to re-run: every statement is idempotent (IF NOT EXISTS / DROP+CREATE).
-- Run this once in Supabase → SQL Editor before using the new forged.html.
-- ============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- PROFILES  (extends whatever you already had — adds the new columns needed
-- for coach/client linking, unit preference, and invite codes)
-- ----------------------------------------------------------------------------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  role text not null default 'client' check (role in ('trainer','client')),
  must_change_password boolean not null default false,
  created_at timestamptz not null default now()
);
alter table profiles add column if not exists coach_id uuid references profiles(id) on delete set null;
alter table profiles add column if not exists units text not null default 'metric' check (units in ('metric','imperial'));
alter table profiles add column if not exists invite_code text unique;
alter table profiles add column if not exists ai_enabled boolean not null default true;
alter table profiles add column if not exists injuries text;
alter table profiles add column if not exists equipment_notes text;
alter table profiles add column if not exists created_at timestamptz not null default now();

-- every trainer gets a short shareable invite code automatically; clients enter
-- this code at signup to link coach_id -> that trainer
create or replace function forged_gen_invite_code() returns text
language sql as $$ select upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)) $$;

create or replace function forged_set_invite_code() returns trigger
language plpgsql as $$
begin
  if new.role = 'trainer' and new.invite_code is null then
    new.invite_code := forged_gen_invite_code();
  end if;
  return new;
end $$;

drop trigger if exists trg_forged_set_invite_code on profiles;
create trigger trg_forged_set_invite_code before insert or update on profiles
for each row execute function forged_set_invite_code();

-- ----------------------------------------------------------------------------
-- EXERCISE LIBRARY — the deduped master list (seeded from your PDFs, see
-- forged-seed.sql). Coaches can add more from the app.
-- ----------------------------------------------------------------------------
create table if not exists exercise_library (
  id text primary key,
  name text not null,
  category text not null default 'strength' check (category in ('strength','cardio','core','mobility')),
  muscle_group text,
  equipment text,
  tracking_type text not null default 'reps_weight'
    check (tracking_type in ('reps_weight','distance_time','time_only','reps_only','level_distance')),
  notes text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_exlib_name on exercise_library using gin (to_tsvector('simple', name));

-- ----------------------------------------------------------------------------
-- WORKOUT TEMPLATES — original workout-day templates preserved from your PDFs
-- (see forged-seed.sql), plus any a coach saves as reusable from the builder.
-- exercises jsonb shape: [{ex_id, n, s, r, rest, grp}]
-- ----------------------------------------------------------------------------
create table if not exists workout_templates (
  id text primary key,
  name text not null,
  plan text,
  source_client text,
  dur int,
  equip text,
  exercises jsonb not null default '[]'::jsonb,
  created_by uuid references profiles(id),
  is_global boolean not null default true,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- ASSIGNED PLANS — a named programme a coach has assigned to one client
-- ----------------------------------------------------------------------------
create table if not exists assigned_plans (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references profiles(id) on delete cascade,
  coach_id uuid not null references profiles(id) on delete cascade,
  name text not null,
  start_date date,
  end_date date,
  status text not null default 'active' check (status in ('active','completed','archived')),
  created_at timestamptz not null default now()
);
create index if not exists idx_plans_client on assigned_plans(client_id);
create index if not exists idx_plans_coach on assigned_plans(coach_id);

-- ----------------------------------------------------------------------------
-- ASSIGNED WORKOUTS — one training-day instance on a client's calendar.
-- exercises jsonb is a *snapshot copy* (not a template reference) so edits by
-- the client, the coach, or the AI swap tool never mutate the shared template.
-- exercise shape: {ex_id, n, cat, track, s, reps, weight_kg, distance_m,
--                   time_sec, rest, grp, note}
-- ----------------------------------------------------------------------------
create table if not exists assigned_workouts (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid references assigned_plans(id) on delete cascade,
  client_id uuid not null references profiles(id) on delete cascade,
  coach_id uuid not null references profiles(id) on delete cascade,
  template_id text references workout_templates(id),
  scheduled_date date not null default current_date,
  name text not null,
  type text not null default 'training' check (type in ('training','cardio','rest','checkin')),
  dur int,
  exercises jsonb not null default '[]'::jsonb,
  status text not null default 'pending' check (status in ('pending','done','skipped')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_wk_client_date on assigned_workouts(client_id, scheduled_date);
create index if not exists idx_wk_coach on assigned_workouts(coach_id);

-- ----------------------------------------------------------------------------
-- WORKOUT LOGS — actual performance per set, logged by the client
-- ----------------------------------------------------------------------------
create table if not exists workout_logs (
  id uuid primary key default gen_random_uuid(),
  assigned_workout_id uuid not null references assigned_workouts(id) on delete cascade,
  client_id uuid not null references profiles(id) on delete cascade,
  exercise_index int not null,
  exercise_name text not null,
  set_number int not null,
  reps int,
  weight_kg numeric,
  distance_m numeric,
  time_sec numeric,
  rpe int,
  completed_at timestamptz not null default now()
);
create index if not exists idx_logs_workout on workout_logs(assigned_workout_id);
create index if not exists idx_logs_client on workout_logs(client_id);

-- ----------------------------------------------------------------------------
-- EXERCISE SWAPS — audit trail so the coach can see what the AI (or the
-- client) changed and why (injury / busy gym / other)
-- ----------------------------------------------------------------------------
create table if not exists exercise_swaps (
  id uuid primary key default gen_random_uuid(),
  assigned_workout_id uuid references assigned_workouts(id) on delete cascade,
  client_id uuid references profiles(id) on delete cascade,
  original_name text,
  new_name text,
  reason text,
  requested_by text check (requested_by in ('client','coach')),
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- AI CHAT HISTORY
-- ----------------------------------------------------------------------------
create table if not exists ai_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  role text not null check (role in ('user','bot')),
  content text not null,
  context text,
  created_at timestamptz not null default now()
);
create index if not exists idx_ai_user on ai_messages(user_id, created_at);

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================
alter table profiles enable row level security;
alter table exercise_library enable row level security;
alter table workout_templates enable row level security;
alter table assigned_plans enable row level security;
alter table assigned_workouts enable row level security;
alter table workout_logs enable row level security;
alter table exercise_swaps enable row level security;
alter table ai_messages enable row level security;

-- PROFILES ---------------------------------------------------------------
drop policy if exists profiles_self_select on profiles;
create policy profiles_self_select on profiles for select using (id = auth.uid());

drop policy if exists profiles_coach_select_clients on profiles;
create policy profiles_coach_select_clients on profiles for select using (coach_id = auth.uid());

-- lets a signed-up user look up a trainer's id by invite code before their
-- own coach_id is set. Only exposes rows that HAVE an invite code, i.e.
-- trainer directory rows — fine for a single-coach app.
drop policy if exists profiles_invite_lookup on profiles;
create policy profiles_invite_lookup on profiles for select using (invite_code is not null);

drop policy if exists profiles_self_insert on profiles;
create policy profiles_self_insert on profiles for insert with check (id = auth.uid());

drop policy if exists profiles_self_update on profiles;
create policy profiles_self_update on profiles for update using (id = auth.uid());

drop policy if exists profiles_coach_update_clients on profiles;
create policy profiles_coach_update_clients on profiles for update using (coach_id = auth.uid());

-- EXERCISE LIBRARY ---------------------------------------------------------
drop policy if exists exlib_select on exercise_library;
create policy exlib_select on exercise_library for select using (auth.uid() is not null);

drop policy if exists exlib_write on exercise_library;
create policy exlib_write on exercise_library for all
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'trainer'))
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'trainer'));

-- WORKOUT TEMPLATES ---------------------------------------------------------
drop policy if exists tpl_select on workout_templates;
create policy tpl_select on workout_templates for select using (auth.uid() is not null);

drop policy if exists tpl_write on workout_templates;
create policy tpl_write on workout_templates for all
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'trainer'))
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'trainer'));

-- ASSIGNED PLANS ---------------------------------------------------------
drop policy if exists plans_client_select on assigned_plans;
create policy plans_client_select on assigned_plans for select using (client_id = auth.uid());

drop policy if exists plans_coach_all on assigned_plans;
create policy plans_coach_all on assigned_plans for all
  using (coach_id = auth.uid()) with check (coach_id = auth.uid());

-- ASSIGNED WORKOUTS ---------------------------------------------------------
drop policy if exists wk_client_select on assigned_workouts;
create policy wk_client_select on assigned_workouts for select using (client_id = auth.uid());

-- clients can edit their own workout (log sets, swap an exercise) but not
-- reassign it to someone else or change who coaches them
drop policy if exists wk_client_update on assigned_workouts;
create policy wk_client_update on assigned_workouts for update
  using (client_id = auth.uid()) with check (client_id = auth.uid());

-- the app's "Save Workout" always calls upsert(), which issues an INSERT ...
-- ON CONFLICT DO UPDATE under the hood — Postgres checks the INSERT policy
-- even when the row already exists, so clients need insert rights on their
-- own rows too (e.g. self-adding a new session) or every save-on-existing
-- row would be rejected by RLS.
drop policy if exists wk_client_insert on assigned_workouts;
create policy wk_client_insert on assigned_workouts for insert
  with check (client_id = auth.uid());

drop policy if exists wk_coach_all on assigned_workouts;
create policy wk_coach_all on assigned_workouts for all
  using (coach_id = auth.uid()) with check (coach_id = auth.uid());

-- WORKOUT LOGS ---------------------------------------------------------
drop policy if exists logs_client_all on workout_logs;
create policy logs_client_all on workout_logs for all
  using (client_id = auth.uid()) with check (client_id = auth.uid());

drop policy if exists logs_coach_select on workout_logs;
create policy logs_coach_select on workout_logs for select using (
  exists (select 1 from assigned_workouts w where w.id = workout_logs.assigned_workout_id and w.coach_id = auth.uid())
);

-- EXERCISE SWAPS ---------------------------------------------------------
drop policy if exists swaps_client_all on exercise_swaps;
create policy swaps_client_all on exercise_swaps for all
  using (client_id = auth.uid()) with check (client_id = auth.uid());

drop policy if exists swaps_coach_select on exercise_swaps;
create policy swaps_coach_select on exercise_swaps for select using (
  exists (select 1 from assigned_workouts w where w.id = exercise_swaps.assigned_workout_id and w.coach_id = auth.uid())
);

-- a coach can also trigger a swap directly on a client's workout (helping
-- them mid-week) — that insert's client_id belongs to the client, not the
-- coach, so it needs its own check against assigned_workouts.coach_id
drop policy if exists swaps_coach_insert on exercise_swaps;
create policy swaps_coach_insert on exercise_swaps for insert
  with check (
    exists (select 1 from assigned_workouts w where w.id = exercise_swaps.assigned_workout_id and w.coach_id = auth.uid())
  );

-- AI MESSAGES ---------------------------------------------------------
drop policy if exists ai_self on ai_messages;
create policy ai_self on ai_messages for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================================
-- Done. Next: run forged-seed.sql to load the exercise library + workout
-- templates extracted from your PDFs.
-- ============================================================================
