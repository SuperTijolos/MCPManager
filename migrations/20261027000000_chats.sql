-- Operator conversations, kept per member. The content (what the screen shows
-- and what the model remembers) is one document, as the dashboard saves it.
create table chats (
  id            text primary key,
  owner_id      text not null,              -- a member id, or "admin"
  title         text not null default 'New conversation',
  auto_approve  boolean not null default false,
  message_count integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index chats_owner_idx on chats (owner_id, updated_at desc);

create table chat_content (
  chat_id text primary key references chats (id) on delete cascade,
  items   jsonb not null default '[]',
  history jsonb not null default '[]'
);
