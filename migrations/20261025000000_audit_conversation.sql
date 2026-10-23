-- Calls made from the dashboard's chat carry the conversation they belong to.
alter table audit_events add column conversation_id text;
create index audit_events_conversation_idx on audit_events (conversation_id)
  where conversation_id is not null;
