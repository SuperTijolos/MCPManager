-- The dashboard's audit page shows more than tool calls: server connects,
-- sign-ins and management actions, who did them and how they were approved.
alter table audit_events
  add column kind     text not null default 'toolCall'
    check (kind in ('toolCall', 'serverConnect', 'authorize', 'manage')),
  add column actor    text,
  add column approval text;

alter table audit_events drop constraint audit_events_source_check;
alter table audit_events add constraint audit_events_source_check
  check (source in ('portal', 'dashboard', 'chat', 'system'));
