-- db/schema.sql
--
-- Warp Monitor — Supabase Postgres schema.
--
-- Run this once in the Supabase SQL editor (Dashboard → SQL Editor → New query)
-- or via the Supabase CLI: supabase db push
--
-- The table stores a single row (id = 'current') containing the full JSON
-- state blob pushed by the Mac app.  Row-Level Security is enabled with zero
-- permissive policies so that the anon and authenticated roles cannot read or
-- write the table.  Only the service-role (secret) key — used by the Vercel
-- API routes — can bypass RLS.

create table if not exists public.warp_state (
  id          text primary key,
  state       jsonb not null,
  updated_at  timestamptz not null default now()
);

-- Enable Row Level Security.  Zero policies are added below, which means only
-- the service-role key (server-side, never exposed to the browser) can access
-- this table.  Do NOT add permissive policies.
alter table public.warp_state enable row level security;

-- LidCode state — one row, id = 'current', pushed by LidCode.app on each state change.
-- Separate from warp_state so WarpMonitor and LidCode never clobber each other.
create table if not exists public.lidcode_state (
  id          text primary key,
  state       jsonb not null,
  updated_at  timestamptz not null default now()
);
alter table public.lidcode_state enable row level security;
-- Zero policies: only service-role key can access.
