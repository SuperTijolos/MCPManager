-- Ways to sign in to the dashboard, set up from the dashboard itself. The
-- client secret is kept apart and never returned by the API.
create table auth_providers (
  id         text primary key,                  -- the address segment: /auth/<id>
  position   integer not null default 0,
  kind       text not null check (kind in ('github', 'google')),
  name       text not null,
  client_id  text not null default '',
  enabled    boolean not null default true,
  orgs       text[] not null default '{}',      -- GitHub organisations
  users      text[] not null default '{}',      -- GitHub logins
  domains    text[] not null default '{}',      -- email domains
  emails     text[] not null default '{}',      -- single email addresses
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table auth_provider_secrets (
  provider_id   text primary key references auth_providers (id) on delete cascade,
  client_secret text not null
);

-- Who signed in with what, and the verified emails the provider vouched for.
alter table members
  add column provider text not null default 'github',
  add column emails   text[] not null default '{}';
