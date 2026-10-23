-- Language-model providers the dashboard chats with. The key is kept apart
-- and is never returned by the API; chat requests go through the server.
create table llm_providers (
  id             text primary key,
  position       integer not null default 0,
  name           text not null,
  kind           text not null check (kind in ('ollama', 'openaiCompatible')),
  base_url       text not null,
  models         text[] not null default '{}',
  context_length integer,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table llm_provider_secrets (
  provider_id text primary key references llm_providers (id) on delete cascade,
  api_key     text not null
);
