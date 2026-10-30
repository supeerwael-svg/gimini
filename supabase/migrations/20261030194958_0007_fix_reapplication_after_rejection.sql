/*
# Fix: Allow Re-Application After Rejection

## Problem
The membership_requests table has a blanket UNIQUE constraint on
(institution_id, user_id). This prevents a user whose request was rejected
from ever re-applying to the same institution — even with a new invitation
code. The submit_membership_request function already checks for an existing
pending request, but the database-level constraint blocks ALL duplicate
pairs regardless of status.

## Fix
1. Drop the blanket UNIQUE constraint membership_requests_institution_id_user_id_key.
2. Create a partial UNIQUE INDEX that only covers rows with status = 'pending'.
   This enforces: one pending request per (institution, user) pair, while
   allowing rejected users to submit a new request.

## Security Impact
None — the submit_membership_request RPC still validates invitation codes,
checks for existing pending requests, and checks for existing membership
before creating a new request. The partial index only relaxes the constraint
to allow re-application after rejection.

## Important Notes
- This does NOT delete or modify any existing data.
- The existing rejected request for User 3 remains in the table.
- Re-applying after rejection requires a new valid invitation code.
*/

-- Drop the blanket unique constraint
alter table public.membership_requests
  drop constraint if exists membership_requests_institution_id_user_id_key;

-- Create a partial unique index: one pending request per (institution, user)
create unique index if not exists idx_membership_requests_pending_unique
  on public.membership_requests (institution_id, user_id)
  where status = 'pending';
