-- Run this script once in Supabase Dashboard > SQL Editor.
-- Audit starts after this script is installed; earlier edits cannot be reconstructed.

create table if not exists public.cashflow_audit_logs (
  id bigint generated always as identity primary key,
  workspace_id uuid not null,
  table_name text not null check (table_name in ('cashflow_transactions', 'cashflow_workspace_settings')),
  record_id text not null,
  action text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  actor_id uuid,
  actor_email text,
  actor_name text,
  changed_at timestamptz not null default now(),
  old_data jsonb,
  new_data jsonb
);

create index if not exists cashflow_audit_logs_workspace_changed_idx
  on public.cashflow_audit_logs (workspace_id, changed_at desc);

alter table public.cashflow_audit_logs enable row level security;

drop policy if exists "Workspace members can read cashflow audit" on public.cashflow_audit_logs;
create policy "Workspace members can read cashflow audit"
  on public.cashflow_audit_logs
  for select
  to authenticated
  using (
    auth.uid() is not null
    and workspace_id = '8b8d5a2e-6f2c-4c47-9f45-3a7d8e4b21c0'::uuid
  );

revoke all on public.cashflow_audit_logs from anon, authenticated;
grant select on public.cashflow_audit_logs to authenticated;

create or replace function public.write_cashflow_audit_log()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  old_row jsonb;
  new_row jsonb;
  old_snapshot jsonb;
  new_snapshot jsonb;
  audit_workspace_id uuid;
  audit_record_id text;
  audit_actor_id uuid;
  actor_claims jsonb;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    old_row := to_jsonb(old);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    new_row := to_jsonb(new);
  end if;

  audit_workspace_id := coalesce(new_row ->> 'workspace_id', old_row ->> 'workspace_id')::uuid;
  audit_record_id := coalesce(
    new_row ->> 'id',
    old_row ->> 'id',
    audit_workspace_id::text
  );
  audit_actor_id := coalesce(
    auth.uid(),
    nullif(coalesce(new_row ->> 'updated_by', old_row ->> 'updated_by'), '')::uuid
  );
  actor_claims := auth.jwt();

  if tg_table_name = 'cashflow_transactions' then
    old_snapshot := old_row -> 'data';
    new_snapshot := new_row -> 'data';
    if old_snapshot is not null then
      old_snapshot := old_snapshot - 'photoData';
    end if;
    if new_snapshot is not null then
      new_snapshot := new_snapshot - 'photoData';
    end if;
  else
    old_snapshot := old_row -> 'master_data';
    new_snapshot := new_row -> 'master_data';
  end if;

  if tg_op = 'UPDATE' and old_snapshot is not distinct from new_snapshot then
    return new;
  end if;

  insert into public.cashflow_audit_logs (
    workspace_id,
    table_name,
    record_id,
    action,
    actor_id,
    actor_email,
    actor_name,
    old_data,
    new_data
  ) values (
    audit_workspace_id,
    tg_table_name,
    audit_record_id,
    tg_op,
    audit_actor_id,
    nullif(actor_claims ->> 'email', ''),
    coalesce(
      nullif(actor_claims -> 'user_metadata' ->> 'display_name', ''),
      nullif(actor_claims -> 'user_metadata' ->> 'full_name', ''),
      nullif(actor_claims ->> 'email', '')
    ),
    old_snapshot,
    new_snapshot
  );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.write_cashflow_audit_log() from public, anon, authenticated;

drop trigger if exists cashflow_transactions_audit on public.cashflow_transactions;
create trigger cashflow_transactions_audit
  after insert or update or delete on public.cashflow_transactions
  for each row execute function public.write_cashflow_audit_log();

drop trigger if exists cashflow_workspace_settings_audit on public.cashflow_workspace_settings;
create trigger cashflow_workspace_settings_audit
  after insert or update or delete on public.cashflow_workspace_settings
  for each row execute function public.write_cashflow_audit_log();
