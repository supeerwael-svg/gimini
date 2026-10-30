/*
# EduTrack Classes, Invitations, Requests and Admin RPCs

Adds the remaining institution-scoped tables and the SECURITY DEFINER RPCs
that are the ONLY way clients can perform administrative mutations.

## Overview

- Classes and class assignments (regular supervisors assigned to classes).
- Invitation codes (with expiry and usage limits) for joining an institution.
- Membership approval requests (pending joins that a General Supervisor
  approves or rejects).
- A set of SECURITY DEFINER RPCs that enforce all authorization server-side
  and write the audit log. Clients have NO direct INSERT/UPDATE/DELETE on
  memberships, membership_permissions, audit_log, membership_requests, or
  invitation_codes.

## Tables created

1. classes
   - id (uuid PK)
   - institution_id (uuid -> institutions, ON DELETE CASCADE)
   - name (text, not null)
   - grade (text, nullable) - e.g. "Grade 10"
   - created_at (timestamptz)
   - UNIQUE (institution_id, name)

2. class_assignments
   - id (uuid PK)
   - class_id (uuid -> classes, ON DELETE CASCADE)
   - membership_id (uuid -> memberships, ON DELETE CASCADE)
   - assigned_by (uuid -> auth.users)
   - assigned_at (timestamptz)
   - UNIQUE (class_id, membership_id)
   Only regular_supervisor memberships can be assigned.

3. invitation_codes
   - id (uuid PK)
   - institution_id (uuid -> institutions, ON DELETE CASCADE)
   - code (text, not null, UNIQUE) - generated random code
   - created_by (uuid -> auth.users)
   - expires_at (timestamptz, not null)
   - max_uses (int, default 1, check >= 1)
   - uses_count (int, default 0)
   - revoked_at (timestamptz, nullable)
   - created_at (timestamptz)

4. membership_requests
   - id (uuid PK)
   - institution_id (uuid -> institutions, ON DELETE CASCADE)
   - user_id (uuid -> auth.users, ON DELETE CASCADE)
   - invitation_code_id (uuid -> invitation_codes, nullable)
   - status (text, default pending, CHECK in
     pending / approved / rejected)
   - reviewed_by (uuid -> auth.users, nullable)
   - reviewed_at (timestamptz, nullable)
   - requested_role (text, default regular_supervisor)
   - created_at, updated_at (timestamptz)
   - UNIQUE (institution_id, user_id) - one pending request per user per inst

## RPCs (all SECURITY DEFINER, fixed search_path = public)

All RPCs REVOKE EXECUTE FROM PUBLIC/anon and GRANT to authenticated only.

- submit_membership_request(p_code text)
    Validates the invitation code (exists, not expired, not revoked, under
    max_uses). Creates a pending membership_request and atomically
    increments uses_count. Returns the request row. No permission required
    (any authenticated user may join via a valid code).
- approve_membership_request(p_request_id uuid)
    General Supervisor only. Sets request to approved, creates an active
    membership with the requested role, audits. Guard: cannot approve if
    membership already exists.
- reject_membership_request(p_request_id uuid)
    General Supervisor only. Sets request to rejected, audits.
- create_invitation_code(p_institution_id uuid, p_expires_at timestamptz, p_max_uses int)
    Requires manage_invitations permission. Generates a random 8-char code.
- revoke_invitation_code(p_code_id uuid)
    Requires manage_invitations permission. Sets revoked_at.
- grant_permission(p_membership_id uuid, p_permission text)
    General Supervisor only. Validates permission exists and target is a
    regular_supervisor (cannot grant to GS). Audits.
- revoke_permission(p_membership_id uuid, p_permission text)
    General Supervisor only. Audits.
- update_member_role(p_membership_id uuid, p_role text)
    General Supervisor only. Guard: prevents demoting the last General
    Supervisor; cannot change own role to avoid self-lockout. Audits.
- set_member_status(p_membership_id uuid, p_status text)
    General Supervisor only. Guard: prevents suspending the last General
    Supervisor. Audits.
- remove_member(p_membership_id uuid)
    General Supervisor only. Guard: prevents removing the last General
    Supervisor; cannot remove self. Audits.
- assign_class(p_class_id uuid, p_membership_id uuid)
    Requires assign_classes permission. Target membership must be a regular
    supervisor in the same institution. Audits.
- unassign_class(p_assignment_id uuid)
    Requires assign_classes permission. Audits.

## RLS

- classes: SELECT if is_member; INSERT/UPDATE/DELETE via RPCs only (no client
  grants beyond the table being managed through SECURITY DEFINER functions
  called from edge functions / service role). For this version, class
  management is performed through the service_role / RPC path; clients get
  SELECT only. (Class create/edit/delete RPCs can be added later.)
- class_assignments: SELECT if is_member.
- invitation_codes: SELECT if is_member (so members can see codes); writes
  via RPCs only.
- membership_requests: SELECT if is_member (General Supervisor sees all
  requests for the institution; regular supervisors see their own); writes
  via RPCs only.

## Important notes

1. All RPCs are the single entry point for privileged mutations. They check
   authorization using the helper functions from migration 1 and raise
   exceptions (RAISERROR via raise exception) on unauthorized access.
2. The last-General-Supervisor guard prevents accidental lockout.
3. Regular supervisors cannot change roles because they have no UPDATE grant
   on memberships and the role-changing RPC requires is_general_supervisor.
*/

-- ---------------------------------------------------------------------------
-- classes
-- ---------------------------------------------------------------------------
create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  name text not null,
  grade text,
  created_at timestamptz not null default now(),
  unique (institution_id, name)
);

alter table public.classes enable row level security;

grant select on public.classes to authenticated;
grant all on public.classes to service_role;

drop policy if exists "classes_select_member" on public.classes;
create policy "classes_select_member"
  on public.classes for select
  to authenticated
  using (public.is_member(institution_id));

-- ---------------------------------------------------------------------------
-- class_assignments
-- ---------------------------------------------------------------------------
create table if not exists public.class_assignments (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  membership_id uuid not null references public.memberships(id) on delete cascade,
  assigned_by uuid references auth.users(id),
  assigned_at timestamptz not null default now(),
  unique (class_id, membership_id)
);

alter table public.class_assignments enable row level security;

grant select on public.class_assignments to authenticated;
grant all on public.class_assignments to service_role;

drop policy if exists "class_assignments_select_member" on public.class_assignments;
create policy "class_assignments_select_member"
  on public.class_assignments for select
  to authenticated
  using (
    exists (
      select 1 from public.classes c
      where c.id = class_assignments.class_id
        and public.is_member(c.institution_id)
    )
  );

-- ---------------------------------------------------------------------------
-- invitation_codes
-- ---------------------------------------------------------------------------
create table if not exists public.invitation_codes (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  code text not null unique,
  created_by uuid not null references auth.users(id),
  expires_at timestamptz not null,
  max_uses int not null default 1 check (max_uses >= 1),
  uses_count int not null default 0,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.invitation_codes enable row level security;

grant select on public.invitation_codes to authenticated;
grant all on public.invitation_codes to service_role;

-- Members can see invitation codes of their institution (GS manages them).
drop policy if exists "invitation_codes_select_member" on public.invitation_codes;
create policy "invitation_codes_select_member"
  on public.invitation_codes for select
  to authenticated
  using (public.is_member(institution_id));

-- ---------------------------------------------------------------------------
-- membership_requests
-- ---------------------------------------------------------------------------
create table if not exists public.membership_requests (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  invitation_code_id uuid references public.invitation_codes(id),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  requested_role text not null default 'regular_supervisor' check (requested_role in ('general_supervisor','regular_supervisor')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (institution_id, user_id)
);

alter table public.membership_requests enable row level security;

grant select on public.membership_requests to authenticated;
grant all on public.membership_requests to service_role;

-- General Supervisors see all requests for their institution; regular
-- supervisors see only their own requests.
drop policy if exists "membership_requests_select" on public.membership_requests;
create policy "membership_requests_select"
  on public.membership_requests for select
  to authenticated
  using (
    user_id = auth.uid()
    or public.is_general_supervisor(institution_id)
  );

-- updated_at trigger for membership_requests
create or replace function public.set_request_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_membership_requests_updated on public.membership_requests;
create trigger trg_membership_requests_updated
  before update on public.membership_requests
  for each row execute function public.set_request_updated_at();

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
create index if not exists idx_classes_institution on public.classes(institution_id);
create index if not exists idx_class_assignments_class on public.class_assignments(class_id);
create index if not exists idx_class_assignments_membership on public.class_assignments(membership_id);
create index if not exists idx_invitation_codes_institution on public.invitation_codes(institution_id);
create index if not exists idx_membership_requests_institution on public.membership_requests(institution_id, status);
create index if not exists idx_membership_requests_user on public.membership_requests(user_id);

-- ===========================================================================
-- RPCs (SECURITY DEFINER) — the ONLY mutation path for privileged operations
-- ===========================================================================

-- Helper: write an audit entry (internal, not exposed to clients)
create or replace function public.write_audit(
  p_institution uuid,
  p_actor uuid,
  p_action text,
  p_target_type text default null,
  p_target_id text default null,
  p_details jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_log (institution_id, actor_id, action, target_type, target_id, details)
  values (p_institution, p_actor, p_action, p_target_type, p_target_id, p_details);
end;
$$;

-- ---------------------------------------------------------------------------
-- submit_membership_request
-- ---------------------------------------------------------------------------
create or replace function public.submit_membership_request(p_code text)
returns public.membership_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv public.invitation_codes%rowtype;
  v_existing public.membership_requests%rowtype;
  v_already_member boolean;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to request membership.';
  end if;

  select * into v_inv from public.invitation_codes
  where code = p_code
  for update;

  if not found then
    raise exception 'Invalid invitation code.';
  end if;

  if v_inv.revoked_at is not null then
    raise exception 'This invitation code has been revoked.';
  end if;

  if now() > v_inv.expires_at then
    raise exception 'This invitation code has expired.';
  end if;

  if v_inv.uses_count >= v_inv.max_uses then
    raise exception 'This invitation code has reached its usage limit.';
  end if;

  -- Check if already a member
  select true into v_already_member
  from public.memberships
  where institution_id = v_inv.institution_id
    and user_id = auth.uid()
  limit 1;

  if v_already_member then
    raise exception 'You are already a member of this institution.';
  end if;

  -- Check for existing pending request
  select * into v_existing
  from public.membership_requests
  where institution_id = v_inv.institution_id
    and user_id = auth.uid()
    and status = 'pending'
  limit 1;

  if found then
    raise exception 'You already have a pending request for this institution.';
  end if;

  -- Increment usage atomically
  update public.invitation_codes
  set uses_count = uses_count + 1
  where id = v_inv.id;

  -- Create the request
  insert into public.membership_requests (institution_id, user_id, invitation_code_id, status, requested_role)
  values (v_inv.institution_id, auth.uid(), v_inv.id, 'pending', 'regular_supervisor')
  returning * into v_existing;

  perform public.write_audit(
    v_inv.institution_id, auth.uid(), 'membership_request_submitted',
    'membership_request', v_existing.id::text,
    jsonb_build_object('code_id', v_inv.id::text)
  );

  return v_existing;
end;
$$;

-- ---------------------------------------------------------------------------
-- approve_membership_request
-- ---------------------------------------------------------------------------
create or replace function public.approve_membership_request(p_request_id uuid)
returns public.membership_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.membership_requests%rowtype;
  v_membership public.memberships%rowtype;
begin
  select * into v_req from public.membership_requests where id = p_request_id for update;

  if not found then
    raise exception 'Membership request not found.';
  end if;

  if not public.is_general_supervisor(v_req.institution_id) then
    raise exception 'Only a General Supervisor can approve membership requests.';
  end if;

  if v_req.status <> 'pending' then
    raise exception 'This request has already been processed.';
  end if;

  -- Prevent duplicate membership
  select * into v_membership
  from public.memberships
  where institution_id = v_req.institution_id
    and user_id = v_req.user_id
  limit 1;

  if found then
    raise exception 'This user is already a member.';
  end if;

  -- Create the membership
  insert into public.memberships (institution_id, user_id, role, status)
  values (v_req.institution_id, v_req.user_id, v_req.requested_role, 'active')
  returning * into v_membership;

  -- Update request
  update public.membership_requests
  set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_request_id
  returning * into v_req;

  perform public.write_audit(
    v_req.institution_id, auth.uid(), 'member_approved',
    'membership', v_membership.id::text,
    jsonb_build_object('user_id', v_req.user_id::text, 'role', v_req.requested_role)
  );

  return v_req;
end;
$$;

-- ---------------------------------------------------------------------------
-- reject_membership_request
-- ---------------------------------------------------------------------------
create or replace function public.reject_membership_request(p_request_id uuid)
returns public.membership_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.membership_requests%rowtype;
begin
  select * into v_req from public.membership_requests where id = p_request_id for update;

  if not found then
    raise exception 'Membership request not found.';
  end if;

  if not public.is_general_supervisor(v_req.institution_id) then
    raise exception 'Only a General Supervisor can reject membership requests.';
  end if;

  if v_req.status <> 'pending' then
    raise exception 'This request has already been processed.';
  end if;

  update public.membership_requests
  set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_request_id
  returning * into v_req;

  perform public.write_audit(
    v_req.institution_id, auth.uid(), 'member_rejected',
    'membership_request', v_req.id::text,
    jsonb_build_object('user_id', v_req.user_id::text)
  );

  return v_req;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_invitation_code
-- ---------------------------------------------------------------------------
create or replace function public.create_invitation_code(
  p_institution_id uuid,
  p_expires_at timestamptz,
  p_max_uses int default 1
)
returns public.invitation_codes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_row public.invitation_codes%rowtype;
begin
  if not public.has_permission(p_institution_id, 'manage_invitations') then
    raise exception 'You do not have permission to manage invitation codes.';
  end if;

  if p_max_uses < 1 then
    raise exception 'max_uses must be at least 1.';
  end if;

  if p_expires_at <= now() then
    raise exception 'expires_at must be in the future.';
  end if;

  -- Generate a random 8-character uppercase code
  v_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));

  insert into public.invitation_codes (institution_id, code, created_by, expires_at, max_uses)
  values (p_institution_id, v_code, auth.uid(), p_expires_at, p_max_uses)
  returning * into v_row;

  perform public.write_audit(
    p_institution_id, auth.uid(), 'invitation_code_created',
    'invitation_code', v_row.id::text,
    jsonb_build_object('code', v_code, 'max_uses', p_max_uses)
  );

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- revoke_invitation_code
-- ---------------------------------------------------------------------------
create or replace function public.revoke_invitation_code(p_code_id uuid)
returns public.invitation_codes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.invitation_codes%rowtype;
begin
  select * into v_row from public.invitation_codes where id = p_code_id for update;

  if not found then
    raise exception 'Invitation code not found.';
  end if;

  if not public.has_permission(v_row.institution_id, 'manage_invitations') then
    raise exception 'You do not have permission to manage invitation codes.';
  end if;

  if v_row.revoked_at is not null then
    raise exception 'This code is already revoked.';
  end if;

  update public.invitation_codes set revoked_at = now() where id = p_code_id
  returning * into v_row;

  perform public.write_audit(
    v_row.institution_id, auth.uid(), 'invitation_code_revoked',
    'invitation_code', v_row.id::text,
    jsonb_build_object('code', v_row.code)
  );

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- grant_permission
-- ---------------------------------------------------------------------------
create or replace function public.grant_permission(p_membership_id uuid, p_permission text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mem public.memberships%rowtype;
  v_perm_exists boolean;
begin
  select * into v_mem from public.memberships where id = p_membership_id for update;

  if not found then
    raise exception 'Membership not found.';
  end if;

  if not public.is_general_supervisor(v_mem.institution_id) then
    raise exception 'Only a General Supervisor can grant permissions.';
  end if;

  if v_mem.user_id = auth.uid() then
    raise exception 'You cannot modify your own permissions.';
  end if;

  if v_mem.role = 'general_supervisor' then
    raise exception 'General Supervisors already hold all permissions.';
  end if;

  select exists(select 1 from public.permission_keys where key = p_permission) into v_perm_exists;
  if not v_perm_exists then
    raise exception 'Unknown permission key.';
  end if;

  insert into public.membership_permissions (membership_id, permission_key, granted_by)
  values (p_membership_id, p_permission, auth.uid())
  on conflict (membership_id, permission_key) do nothing;

  perform public.write_audit(
    v_mem.institution_id, auth.uid(), 'permission_granted',
    'membership_permissions', p_membership_id::text,
    jsonb_build_object('permission', p_permission, 'membership_id', p_membership_id::text)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- revoke_permission
-- ---------------------------------------------------------------------------
create or replace function public.revoke_permission(p_membership_id uuid, p_permission text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mem public.memberships%rowtype;
begin
  select * into v_mem from public.memberships where id = p_membership_id for update;

  if not found then
    raise exception 'Membership not found.';
  end if;

  if not public.is_general_supervisor(v_mem.institution_id) then
    raise exception 'Only a General Supervisor can revoke permissions.';
  end if;

  delete from public.membership_permissions
  where membership_id = p_membership_id and permission_key = p_permission;

  perform public.write_audit(
    v_mem.institution_id, auth.uid(), 'permission_revoked',
    'membership_permissions', p_membership_id::text,
    jsonb_build_object('permission', p_permission, 'membership_id', p_membership_id::text)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- update_member_role
-- ---------------------------------------------------------------------------
create or replace function public.update_member_role(p_membership_id uuid, p_role text)
returns public.memberships
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mem public.memberships%rowtype;
  v_gs_count int;
begin
  if p_role not in ('general_supervisor','regular_supervisor') then
    raise exception 'Invalid role.';
  end if;

  select * into v_mem from public.memberships where id = p_membership_id for update;

  if not found then
    raise exception 'Membership not found.';
  end if;

  if not public.is_general_supervisor(v_mem.institution_id) then
    raise exception 'Only a General Supervisor can change member roles.';
  end if;

  if v_mem.user_id = auth.uid() then
    raise exception 'You cannot change your own role.';
  end if;

  -- Prevent demoting the last General Supervisor
  if v_mem.role = 'general_supervisor' and p_role = 'regular_supervisor' then
    select count(*) into v_gs_count
    from public.memberships
    where institution_id = v_mem.institution_id
      and role = 'general_supervisor'
      and status = 'active';

    if v_gs_count <= 1 then
      raise exception 'Cannot demote the last General Supervisor.';
    end if;
  end if;

  update public.memberships set role = p_role where id = p_membership_id
  returning * into v_mem;

  -- Clear permissions if promoted to GS (they hold all implicitly)
  if p_role = 'general_supervisor' then
    delete from public.membership_permissions where membership_id = p_membership_id;
  end if;

  perform public.write_audit(
    v_mem.institution_id, auth.uid(), 'member_role_changed',
    'membership', p_membership_id::text,
    jsonb_build_object('new_role', p_role)
  );

  return v_mem;
end;
$$;

-- ---------------------------------------------------------------------------
-- set_member_status
-- ---------------------------------------------------------------------------
create or replace function public.set_member_status(p_membership_id uuid, p_status text)
returns public.memberships
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mem public.memberships%rowtype;
  v_gs_count int;
begin
  if p_status not in ('active','suspended') then
    raise exception 'Invalid status.';
  end if;

  select * into v_mem from public.memberships where id = p_membership_id for update;

  if not found then
    raise exception 'Membership not found.';
  end if;

  if not public.is_general_supervisor(v_mem.institution_id) then
    raise exception 'Only a General Supervisor can change member status.';
  end if;

  if v_mem.user_id = auth.uid() then
    raise exception 'You cannot change your own status.';
  end if;

  -- Prevent suspending the last General Supervisor
  if v_mem.role = 'general_supervisor' and p_status = 'suspended' then
    select count(*) into v_gs_count
    from public.memberships
    where institution_id = v_mem.institution_id
      and role = 'general_supervisor'
      and status = 'active';

    if v_gs_count <= 1 then
      raise exception 'Cannot suspend the last General Supervisor.';
    end if;
  end if;

  update public.memberships set status = p_status where id = p_membership_id
  returning * into v_mem;

  perform public.write_audit(
    v_mem.institution_id, auth.uid(), 'member_status_changed',
    'membership', p_membership_id::text,
    jsonb_build_object('new_status', p_status)
  );

  return v_mem;
end;
$$;

-- ---------------------------------------------------------------------------
-- remove_member
-- ---------------------------------------------------------------------------
create or replace function public.remove_member(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mem public.memberships%rowtype;
  v_gs_count int;
begin
  select * into v_mem from public.memberships where id = p_membership_id for update;

  if not found then
    raise exception 'Membership not found.';
  end if;

  if not public.is_general_supervisor(v_mem.institution_id) then
    raise exception 'Only a General Supervisor can remove members.';
  end if;

  if v_mem.user_id = auth.uid() then
    raise exception 'You cannot remove yourself.';
  end if;

  -- Prevent removing the last General Supervisor
  if v_mem.role = 'general_supervisor' then
    select count(*) into v_gs_count
    from public.memberships
    where institution_id = v_mem.institution_id
      and role = 'general_supervisor'
      and status = 'active';

    if v_gs_count <= 1 then
      raise exception 'Cannot remove the last General Supervisor.';
    end if;
  end if;

  delete from public.memberships where id = p_membership_id;

  perform public.write_audit(
    v_mem.institution_id, auth.uid(), 'member_removed',
    'membership', p_membership_id::text,
    jsonb_build_object('user_id', v_mem.user_id::text)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- assign_class
-- ---------------------------------------------------------------------------
create or replace function public.assign_class(p_class_id uuid, p_membership_id uuid)
returns public.class_assignments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_class public.classes%rowtype;
  v_mem public.memberships%rowtype;
  v_row public.class_assignments%rowtype;
begin
  select * into v_class from public.classes where id = p_class_id;
  if not found then
    raise exception 'Class not found.';
  end if;

  if not public.has_permission(v_class.institution_id, 'assign_classes') then
    raise exception 'You do not have permission to assign classes.';
  end if;

  select * into v_mem from public.memberships where id = p_membership_id;
  if not found then
    raise exception 'Membership not found.';
  end if;

  if v_mem.institution_id <> v_class.institution_id then
    raise exception 'Membership and class belong to different institutions.';
  end if;

  if v_mem.role <> 'regular_supervisor' then
    raise exception 'Only regular supervisors can be assigned to classes.';
  end if;

  if v_mem.status <> 'active' then
    raise exception 'Cannot assign a suspended member.';
  end if;

  insert into public.class_assignments (class_id, membership_id, assigned_by)
  values (p_class_id, p_membership_id, auth.uid())
  on conflict (class_id, membership_id) do nothing
  returning * into v_row;

  perform public.write_audit(
    v_class.institution_id, auth.uid(), 'class_assigned',
    'class_assignments', v_row.id::text,
    jsonb_build_object('class_id', p_class_id::text, 'membership_id', p_membership_id::text)
  );

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- unassign_class
-- ---------------------------------------------------------------------------
create or replace function public.unassign_class(p_assignment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.class_assignments%rowtype;
  v_class public.classes%rowtype;
begin
  select * into v_row from public.class_assignments where id = p_assignment_id;
  if not found then
    raise exception 'Assignment not found.';
  end if;

  select * into v_class from public.classes where id = v_row.class_id;
  if not found then
    raise exception 'Class not found.';
  end if;

  if not public.has_permission(v_class.institution_id, 'assign_classes') then
    raise exception 'You do not have permission to unassign classes.';
  end if;

  delete from public.class_assignments where id = p_assignment_id;

  perform public.write_audit(
    v_class.institution_id, auth.uid(), 'class_unassigned',
    'class_assignments', p_assignment_id::text,
    jsonb_build_object('class_id', v_row.class_id::text, 'membership_id', v_row.membership_id::text)
  );
end;
$$;

-- ===========================================================================
-- Revoke EXECUTE on all RPCs from PUBLIC/anon; grant to authenticated only
-- ===========================================================================
revoke execute on function public.submit_membership_request(text) from public, anon;
revoke execute on function public.approve_membership_request(uuid) from public, anon;
revoke execute on function public.reject_membership_request(uuid) from public, anon;
revoke execute on function public.create_invitation_code(uuid, timestamptz, int) from public, anon;
revoke execute on function public.revoke_invitation_code(uuid) from public, anon;
revoke execute on function public.grant_permission(uuid, text) from public, anon;
revoke execute on function public.revoke_permission(uuid, text) from public, anon;
revoke execute on function public.update_member_role(uuid, text) from public, anon;
revoke execute on function public.set_member_status(uuid, text) from public, anon;
revoke execute on function public.remove_member(uuid) from public, anon;
revoke execute on function public.assign_class(uuid, uuid) from public, anon;
revoke execute on function public.unassign_class(uuid) from public, anon;
-- write_audit is internal; do not expose
revoke execute on function public.write_audit(uuid, uuid, text, text, text, jsonb) from public, anon;

grant execute on function public.submit_membership_request(text) to authenticated;
grant execute on function public.approve_membership_request(uuid) to authenticated;
grant execute on function public.reject_membership_request(uuid) to authenticated;
grant execute on function public.create_invitation_code(uuid, timestamptz, int) to authenticated;
grant execute on function public.revoke_invitation_code(uuid) to authenticated;
grant execute on function public.grant_permission(uuid, text) to authenticated;
grant execute on function public.revoke_permission(uuid, text) to authenticated;
grant execute on function public.update_member_role(uuid, text) to authenticated;
grant execute on function public.set_member_status(uuid, text) to authenticated;
grant execute on function public.remove_member(uuid) to authenticated;
grant execute on function public.assign_class(uuid, uuid) to authenticated;
grant execute on function public.unassign_class(uuid) to authenticated;
