-- Dashboard sign-in sessions. Only the hash of the session token is stored.
create table sessions (
  hash       text primary key,
  member_id  text not null references members (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index sessions_member_idx on sessions (member_id);
