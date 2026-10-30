/*
# Fix: Invitation Code Generation

## Problem
The `create_invitation_code` RPC used `gen_random_bytes(6)` to generate a
random invitation code, but `pgcrypto` is installed in the `extensions`
schema, not `public`. The function's `set search_path = public` means
`gen_random_bytes` is not found.

## Fix
Replace the code-generation logic with `gen_random_uuid()` (a built-in
Postgres function available in all schemas) and extract 8 hex characters
from it. This produces an 8-character uppercase alphanumeric code without
depending on pgcrypto's location.

## Changes
- Recreate `create_invitation_code` using `gen_random_uuid()` for code gen.
- Re-apply the EXECUTE grant (revoke from public/anon, grant to authenticated).
*/

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

  -- Generate a random 8-character uppercase code from a UUID
  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

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

revoke execute on function public.create_invitation_code(uuid, timestamptz, int) from public, anon;
grant execute on function public.create_invitation_code(uuid, timestamptz, int) to authenticated;
