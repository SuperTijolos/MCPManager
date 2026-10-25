-- Roles made of permissions, scopes on members, and invitations.
-- The built-in roles (admin, operator, viewer) live in the server; only roles
-- someone created are stored.
create table roles (
  id          text primary key,
  position    integer not null default 0,
  name        text not null,
  description text not null default '',
  permissions text[] not null default '{}',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Null means "all"; a list limits the member to those servers or portals.
-- via_invite keeps someone in even when they are not on a provider's list.
alter table members
  add column server_ids text[],
  add column portal_ids text[],
  add column via_invite boolean not null default false;

-- The role people get when a provider's own list lets them in. Everything
-- set up before roles existed gave full access, so it keeps doing so.
alter table auth_providers add column default_role text not null default 'viewer';
update auth_providers set default_role = 'admin';

create table invites (
  id         text primary key,
  hash       text not null unique,               -- of the link's token
  email      text,                               -- only this verified email may use it
  role       text not null,
  server_ids text[],
  portal_ids text[],
  return_to  text,
  created_by text not null default '',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_by    text,
  used_at    timestamptz
);
