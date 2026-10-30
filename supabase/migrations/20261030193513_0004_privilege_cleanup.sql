/*
# Security Hardening 2 — Clean Up Remaining Excess Privileges

## Problem
1. permission_keys still grants INSERT, UPDATE, DELETE to authenticated
   (missed in migration 3). The permission catalog is read-only for clients.
2. Both anon and authenticated retain inert but unnecessary TRUNCATE, TRIGGER,
   and REFERENCES privileges on all tables (Supabase defaults). While TRUNCATE
   is blocked by RLS and TRIGGER/REFERENCES are not exploitable by clients,
   removing them follows least-privilege and eliminates noise.

## Changes
- Revoke INSERT, UPDATE, DELETE on permission_keys from authenticated.
- Revoke TRUNCATE, TRIGGER, REFERENCES on all tables from anon and authenticated.
*/

-- permission_keys: make read-only for authenticated
revoke insert, update, delete on public.permission_keys from authenticated;

-- Remove inert TRUNCATE, TRIGGER, REFERENCES from anon on all tables
revoke truncate, trigger, references on public.profiles from anon;
revoke truncate, trigger, references on public.institutions from anon;
revoke truncate, trigger, references on public.memberships from anon;
revoke truncate, trigger, references on public.permission_keys from anon;
revoke truncate, trigger, references on public.membership_permissions from anon;
revoke truncate, trigger, references on public.audit_log from anon;
revoke truncate, trigger, references on public.classes from anon;
revoke truncate, trigger, references on public.class_assignments from anon;
revoke truncate, trigger, references on public.invitation_codes from anon;
revoke truncate, trigger, references on public.membership_requests from anon;

-- Remove inert TRUNCATE, TRIGGER, REFERENCES from authenticated on all tables
revoke truncate, trigger, references on public.profiles from authenticated;
revoke truncate, trigger, references on public.institutions from authenticated;
revoke truncate, trigger, references on public.memberships from authenticated;
revoke truncate, trigger, references on public.permission_keys from authenticated;
revoke truncate, trigger, references on public.membership_permissions from authenticated;
revoke truncate, trigger, references on public.audit_log from authenticated;
revoke truncate, trigger, references on public.classes from authenticated;
revoke truncate, trigger, references on public.class_assignments from authenticated;
revoke truncate, trigger, references on public.invitation_codes from authenticated;
revoke truncate, trigger, references on public.membership_requests from authenticated;
