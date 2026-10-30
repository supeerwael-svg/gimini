/*
# EduTrack Core Schema

Builds the foundational tables, security helpers, triggers and RLS policies
for EduTrack, an educational-institution management system.

## Overview

This migration creates the core data model and security architecture:
- User profiles (1:1 with auth.users, created automatically on signup)
- Institutions (tenants)
- Memberships (user <-> institution links with roles)
- Permission catalog + granted permissions
- Audit log (append-only record of admin actions)

## Security Architecture

Authentication: Supabase email/password (built-in auth.users). No custom auth tables.
A trigger auto-creates a profiles row on signup.

Roles (stored on memberships.role):
- general_supervisor: implicit full permissions within their institution;
  can manage members, permissions, classes, invitations; views audit log.
- regular_supervisor: only permissions explicitly granted via membership_permissions.

Server-side enforcement:
- Tenant isolation: every institution-scoped table's SELECT policy uses the
  is_member(institution_id) helper, so a user only ever sees rows of
  institutions they belong to.
- No direct client writes to sensitive tables (memberships, membership_permissions,
  audit_log). All mutations go through SECURITY DEFINER RPCs (added in
  migration 2) that verify the caller is a General Supervisor and write the
  audit log.
- Role-change protection: regular supervisors have no direct UPDATE grant on
  memberships; role-changing RPCs check is_general_supervisor, so no one can
  escalate or change their own role.
- Helper functions are SECURITY DEFINER with a fixed search_path to avoid
  RLS recursion.

## Tables created

1. profiles
   - id (uuid PK -> auth.users.id, ON DELETE CASCADE)
   - full_name (text, not null)
   - email (citext, not null, unique) - denormalized mirror of auth email
   - phone (text, nullable)
   - avatar_url (text, nullable)
   - created_at, updated_at (timestamptz)

2. institutions
   - id (uuid PK, default gen_random_uuid())
   - name (text, not null)
   - created_by (uuid -> auth.users, not null)
   - created_at (timestamptz, default now())

3. memberships
   - id (uuid PK)
   - institution_id (uuid -> institutions, ON DELETE CASCADE)
   - user_id (uuid -> auth.users, ON DELETE CASCADE)
   - role (text, not null, CHECK in general_supervisor / regular_supervisor)
   - status (text, not null, default active, CHECK in active / suspended)
   - created_at (timestamptz, default now())
   - UNIQUE (institution_id, user_id)

4. permission_keys
   - key (text PK) - e.g. manage_members
   - description (text)
   - category (text)
   Seeded with: manage_members, manage_permissions, manage_classes,
   assign_classes, manage_invitations, view_audit_log.

5. membership_permissions
   - membership_id (uuid -> memberships, ON DELETE CASCADE)
   - permission_key (text -> permission_keys, ON DELETE CASCADE)
   - granted_by (uuid -> auth.users)
   - granted_at (timestamptz, default now())
   - PK (membership_id, permission_key)

6. audit_log
   - id (uuid PK)
   - institution_id (uuid -> institutions, ON DELETE CASCADE)
   - actor_id (uuid -> auth.users)
   - action (text, not null)
   - target_type (text)
   - target_id (text)
   - details (jsonb, default empty)
   - created_at (timestamptz, default now())

## Triggers / Functions

- handle_new_user(): SECURITY DEFINER trigger function that inserts a
  profiles row when a new auth.users row is created. Idempotent.
- set_updated_at(): sets updated_at on profiles UPDATE.
- handle_new_institution(): SECURITY DEFINER trigger on institutions that
  auto-creates a General Supervisor membership for the creator and an audit
  log entry. Idempotent.

## RLS

All tables have RLS enabled.
- profiles: authenticated read own, update own; service_role full.
- institutions: authenticated read if is_member; creator insert
  (creator auto-becomes General Supervisor via trigger); service_role full.
- memberships: authenticated read within institutions they are a member of;
  NO client INSERT/UPDATE/DELETE (managed via RPCs in migration 2);
  service_role full.
- permission_keys: authenticated SELECT (catalog is shared, read-only);
  service_role full for seeding.
- membership_permissions: authenticated read within their institution;
  NO client INSERT/UPDATE/DELETE (managed via RPCs); service_role full.
- audit_log: authenticated read within their institution ONLY if they hold
  the view_audit_log permission OR are a General Supervisor;
  NO client INSERT/UPDATE/DELETE; service_role full.

## Important notes

1. The frontend talks to Postgres with the anon key. Every request runs as
   authenticated once signed in. All policies target authenticated.
2. Helper functions (is_member, is_general_supervisor, has_permission) are
   SECURITY DEFINER with search_path = public to avoid RLS recursion when
   called inside policies. They are created AFTER the tables so references
   resolve.
3. Sensitive tables (memberships, membership_permissions, audit_log) are
   write-locked from clients. Migration 2 adds SECURITY DEFINER RPCs for all
   administrative mutations.
*/

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
create extension if not exists citext;

-- ---------------------------------------------------------------------------
-- Tables (created before helper functions so references resolve)
-- ---------------------------------------------------------------------------

-- profiles
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email citext not null unique,
  phone text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- institutions
create table if not exists public.institutions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

-- memberships
create table if not exists public.memberships (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('general_supervisor','regular_supervisor')),
  status text not null default 'active' check (status in ('active','suspended')),
  created_at timestamptz not null default now(),
  unique (institution_id, user_id)
);

-- permission_keys (catalog)
create table if not exists public.permission_keys (
  key text primary key,
  description text,
  category text
);

-- membership_permissions
create table if not exists public.membership_permissions (
  membership_id uuid not null references public.memberships(id) on delete cascade,
  permission_key text not null references public.permission_keys(key) on delete cascade,
  granted_by uuid references auth.users(id),
  granted_at timestamptz not null default now(),
  primary key (membership_id, permission_key)
);

-- audit_log
create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  actor_id uuid references auth.users(id),
  action text not null,
  target_type text,
  target_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Helper functions (SECURITY DEFINER, fixed search_path; used in policies)
-- ---------------------------------------------------------------------------

-- Is the current user an active member of the given institution?
create or replace function public.is_member(inst uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.memberships m
    where m.institution_id = inst
      and m.user_id = auth.uid()
      and m.status = 'active'
  );
$$;

-- Is the current user a General Supervisor of the given institution?
create or replace function public.is_general_supervisor(inst uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.memberships m
    where m.institution_id = inst
      and m.user_id = auth.uid()
      and m.role = 'general_supervisor'
      and m.status = 'active'
  );
$$;

-- Does the current user hold a given permission in the given institution,
-- OR are they a General Supervisor (who implicitly holds all permissions)?
create or replace function public.has_permission(inst uuid, perm text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.memberships m
    where m.institution_id = inst
      and m.user_id = auth.uid()
      and m.status = 'active'
      and (
        m.role = 'general_supervisor'
        or exists (
          select 1 from public.membership_permissions mp
          where mp.membership_id = m.id
            and mp.permission_key = perm
        )
      )
  );
$$;

-- ---------------------------------------------------------------------------
-- Triggers: auto-create profile on signup; updated_at on profile edits
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
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

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Create a profile when a new auth user signs up.
create or replace function public.handle_new_user()
returns trigger
security definer
set search_path = public
language plpgsql
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.email
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- RLS: enable on all tables
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.institutions enable row level security;
alter table public.memberships enable row level security;
alter table public.permission_keys enable row level security;
alter table public.membership_permissions enable row level security;
alter table public.audit_log enable row level security;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
-- profiles: read own, update own columns
grant select on public.profiles to authenticated;
grant update (full_name, phone, avatar_url) on public.profiles to authenticated;
grant all on public.profiles to service_role;

-- institutions: read if member; insert as creator
grant select on public.institutions to authenticated;
grant insert (name, created_by) on public.institutions to authenticated;
grant all on public.institutions to service_role;

-- memberships: read only for clients
grant select on public.memberships to authenticated;
grant all on public.memberships to service_role;

-- permission_keys: read-only catalog
grant select on public.permission_keys to authenticated;
grant all on public.permission_keys to service_role;

-- membership_permissions: read only for clients
grant select on public.membership_permissions to authenticated;
grant all on public.membership_permissions to service_role;

-- audit_log: read only for clients
grant select on public.audit_log to authenticated;
grant all on public.audit_log to service_role;

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------

-- profiles
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- institutions
drop policy if exists "institutions_select_member" on public.institutions;
create policy "institutions_select_member"
  on public.institutions for select
  to authenticated
  using (public.is_member(id));

drop policy if exists "institutions_insert_creator" on public.institutions;
create policy "institutions_insert_creator"
  on public.institutions for insert
  to authenticated
  with check (created_by = auth.uid());

-- memberships
drop policy if exists "memberships_select_member" on public.memberships;
create policy "memberships_select_member"
  on public.memberships for select
  to authenticated
  using (public.is_member(institution_id));

-- permission_keys (shared read-only catalog)
drop policy if exists "permission_keys_select_all" on public.permission_keys;
create policy "permission_keys_select_all"
  on public.permission_keys for select
  to authenticated
  using (true);

-- membership_permissions
drop policy if exists "membership_permissions_select_member" on public.membership_permissions;
create policy "membership_permissions_select_member"
  on public.membership_permissions for select
  to authenticated
  using (
    exists (
      select 1 from public.memberships m
      where m.id = membership_permissions.membership_id
        and public.is_member(m.institution_id)
    )
  );

-- audit_log (only viewers with view_audit_log permission / GS)
drop policy if exists "audit_log_select_authorized" on public.audit_log;
create policy "audit_log_select_authorized"
  on public.audit_log for select
  to authenticated
  using (public.has_permission(institution_id, 'view_audit_log'));

-- ---------------------------------------------------------------------------
-- Seed permission catalog
-- ---------------------------------------------------------------------------
insert into public.permission_keys (key, description, category) values
  ('manage_members', 'Approve/reject join requests, suspend or remove members', 'members'),
  ('manage_permissions', 'Grant or revoke permissions for regular supervisors', 'permissions'),
  ('manage_classes', 'Create, edit or delete classes', 'classes'),
  ('assign_classes', 'Assign regular supervisors to classes', 'classes'),
  ('manage_invitations', 'Create or revoke invitation codes', 'invitations'),
  ('view_audit_log', 'View the institution audit log', 'audit')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Trigger: auto-create General Supervisor membership + audit on new institution
-- (defined after memberships + audit_log exist)
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_institution()
returns trigger
security definer
set search_path = public
language plpgsql
as $$
begin
  insert into public.memberships (institution_id, user_id, role, status)
  values (new.id, new.created_by, 'general_supervisor', 'active')
  on conflict (institution_id, user_id) do nothing;

  insert into public.audit_log (institution_id, actor_id, action, target_type, target_id, details)
  values (
    new.id, new.created_by, 'institution_created', 'institution', new.id::text,
    jsonb_build_object('name', new.name)
  );

  return new;
end;
$$;

drop trigger if exists trg_institution_created on public.institutions;
create trigger trg_institution_created
  after insert on public.institutions
  for each row execute function public.handle_new_institution();

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
create index if not exists idx_memberships_institution on public.memberships(institution_id);
create index if not exists idx_memberships_user on public.memberships(user_id);
create index if not exists idx_audit_log_institution on public.audit_log(institution_id, created_at desc);
create index if not exists idx_membership_permissions_membership on public.membership_permissions(membership_id);
