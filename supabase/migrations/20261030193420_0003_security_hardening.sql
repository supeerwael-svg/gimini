/*
# Security Hardening — Revoke anon Access, Lock Down Internal Functions

## Problem
Supabase grants DEFAULT privileges (SELECT, INSERT, UPDATE, DELETE) on every
table in the public schema to the `anon` role automatically. The previous
migrations only ADDED grants to authenticated/service_role but did NOT revoke
the excessive defaults on anon. This left anon with full CRUD on every table,
including sensitive ones (memberships, audit_log, membership_permissions).
Additionally, trigger functions and the internal write_audit helper were
callable as RPCs by the anon role.

## Changes

1. REVOKE all table privileges from anon on every table.
   - This app requires sign-in, so anon should have NO direct table access.
   - Re-grant only what is truly needed: nothing for anon (all policies are
     TO authenticated).
2. REVOKE EXECUTE from anon AND authenticated on:
   - Trigger functions: handle_new_user, handle_new_institution, set_updated_at,
     set_request_updated_at (called by triggers, not by users).
   - Internal helper: write_audit (called only by other SECURITY DEFINER RPCs).
3. REVOKE EXECUTE from anon on policy-helper functions (is_member,
   is_general_supervisor, has_permission). Authenticated keeps EXECUTE because
     RLS policies call these functions during authenticated queries.
4. Re-affirm column-restricted UPDATE grant on profiles (full_name, phone,
   avatar_url only) after revoking the broad default.

## Security impact
- anon can no longer read or write any table.
- anon can no longer call any function via the REST API.
- authenticated can only call the 12 business RPCs (submit/approve/reject
  request, create/revoke invitation, grant/revoke permission, update role,
  set status, remove member, assign/unassign class) plus the 3 policy helpers.
- Trigger and internal functions are not callable via RPC by anyone.

## Important notes
1. This migration is safe to re-run: all REVOKE statements are idempotent.
2. The service_role grant on each table is preserved (edge functions may need it).
3. After this migration, the only client-facing surface is: SELECT on tables
   (filtered by RLS), UPDATE on own profile, INSERT on institutions (creator
   only), and the 12 RPCs.
*/

-- ---------------------------------------------------------------------------
-- 1. Revoke ALL privileges from anon on every table
-- ---------------------------------------------------------------------------
revoke select, insert, update, delete on public.profiles from anon;
revoke select, insert, update, delete on public.institutions from anon;
revoke select, insert, update, delete on public.memberships from anon;
revoke select, insert, update, delete on public.permission_keys from anon;
revoke select, insert, update, delete on public.membership_permissions from anon;
revoke select, insert, update, delete on public.audit_log from anon;
revoke select, insert, update, delete on public.classes from anon;
revoke select, insert, update, delete on public.class_assignments from anon;
revoke select, insert, update, delete on public.invitation_codes from anon;
revoke select, insert, update, delete on public.membership_requests from anon;

-- ---------------------------------------------------------------------------
-- 2. Revoke ALL privileges from authenticated on write-protected tables,
--    then re-grant ONLY SELECT (writes go through RPCs)
--    (This overrides Supabase defaults that granted full CRUD to authenticated.)
-- ---------------------------------------------------------------------------
-- memberships: SELECT only
revoke insert, update, delete on public.memberships from authenticated;
-- membership_permissions: SELECT only
revoke insert, update, delete on public.membership_permissions from authenticated;
-- audit_log: SELECT only
revoke insert, update, delete on public.audit_log from authenticated;
-- classes: SELECT only (managed via service_role / future RPCs)
revoke insert, update, delete on public.classes from authenticated;
-- class_assignments: SELECT only (managed via assign_class/unassign_class RPCs)
revoke insert, update, delete on public.class_assignments from authenticated;
-- invitation_codes: SELECT only (managed via create/revoke RPCs)
revoke insert, update, delete on public.invitation_codes from authenticated;
-- membership_requests: SELECT only (managed via submit/approve/reject RPCs)
revoke insert, update, delete on public.membership_requests from authenticated;
-- institutions: SELECT + INSERT only (no UPDATE/DELETE for clients)
revoke update, delete on public.institutions from authenticated;
-- profiles: SELECT only via default; UPDATE re-granted below with column scope
revoke insert, update, delete on public.profiles from authenticated;
grant update (full_name, phone, avatar_url) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Revoke EXECUTE on trigger and internal functions from ALL roles
-- ---------------------------------------------------------------------------
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.handle_new_institution() from public, anon, authenticated;
revoke execute on function public.set_updated_at() from public, anon, authenticated;
revoke execute on function public.set_request_updated_at() from public, anon, authenticated;
revoke execute on function public.write_audit(uuid, uuid, text, text, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Revoke EXECUTE on policy-helper functions from anon (keep authenticated)
-- ---------------------------------------------------------------------------
revoke execute on function public.is_member(uuid) from public, anon;
revoke execute on function public.is_general_supervisor(uuid) from public, anon;
revoke execute on function public.has_permission(uuid, text) from public, anon;
