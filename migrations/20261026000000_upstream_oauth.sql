-- Servers that sign in with OAuth: the setting, and what the sign-in produced.
alter table servers
  add column oauth           boolean not null default false,
  add column oauth_client_id text,
  add column oauth_scope     text;

-- The registered client and tokens for one server. Server only.
create table server_oauth (
  server_id  text primary key references servers (id) on delete cascade,
  session    jsonb not null,
  updated_at timestamptz not null default now()
);
