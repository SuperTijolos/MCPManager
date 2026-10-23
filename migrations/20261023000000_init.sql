-- MCP Manager: the portal server's system of record (plain Postgres).
--
-- The server is the only thing that talks to this database; the dashboard
-- goes through the server's API, so secrets never leave it.

create table members (
  id           text primary key,            -- provider:id, e.g. github:12345
  login        text not null,               -- GitHub login
  name         text,
  email        text,
  avatar_url   text,
  orgs         text[] not null default '{}',
  role         text not null default 'admin',
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz
);

-- Small key/value settings (e.g. the bootstrap admin token hash).
create table settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

create table servers (
  id           text primary key,
  position     integer not null default 0,
  slug         text not null unique,
  name         text not null,
  url          text not null,
  transport    text not null default 'auto',
  enabled      boolean not null default true,
  header_names text[] not null default '{}',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Upstream credentials. No dashboard policy: server only.
create table server_credentials (
  server_id text primary key references servers (id) on delete cascade,
  headers   jsonb not null default '{}'
);

create table portals (
  id             text primary key,
  position       integer not null default 0,
  slug           text not null unique,
  name           text not null,
  description    text not null default '',
  enabled        boolean not null default true,
  servers        jsonb not null default '[]',
  excluded_tools text[] not null default '{}',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table tool_rules (
  id         text primary key,
  position   integer not null default 0,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);

create table tool_overrides (
  tool_key   text primary key,              -- serverId/toolName
  data       jsonb not null,
  updated_at timestamptz not null default now()
);

-- Credentials for MCP clients. Only hashes are stored. No dashboard policy.
create table access_tokens (
  id           text primary key,
  position     integer not null default 0,
  name         text not null,
  hash         text not null unique,
  prefix       text not null default '',
  portal_ids   text[] not null default '{}',
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz,
  expires_at   timestamptz
);

create table oauth_clients (
  client_id     text primary key,
  client_name   text not null,
  redirect_uris text[] not null default '{}',
  created_at    timestamptz not null default now()
);

create table oauth_grants (
  hash       text primary key,
  kind       text not null check (kind in ('access', 'refresh')),
  client_id  text not null,
  portal_id  text,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index oauth_grants_client_idx on oauth_grants (client_id);

-- Every call: from a portal client, the dashboard's test bench or its chat.
create table audit_events (
  id          text primary key,
  ts          timestamptz not null default now(),
  source      text not null default 'portal' check (source in ('portal', 'dashboard', 'chat')),
  portal_id   text,
  portal_slug text,
  principal   jsonb not null default '{}',
  status      text not null check (status in ('success', 'error', 'denied')),
  server_id   text,
  server_name text,
  tool        text,
  exposed_name text,
  duration_ms integer,
  args        text,
  forwarded   text,
  context     text,
  result      text,
  error       text,
  rules       text[] not null default '{}'
);
create index audit_events_ts_idx on audit_events (ts desc);
create index audit_events_portal_idx on audit_events (portal_id, ts desc);
create index audit_events_status_idx on audit_events (status, ts desc);
