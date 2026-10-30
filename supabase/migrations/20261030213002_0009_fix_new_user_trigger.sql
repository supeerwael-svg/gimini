/*
# Fix handle_new_user trigger for supervisor signup

## Problem
`auth.users` AFTER INSERT trigger `handle_new_user()` inserted into `public.profiles(id, full_name, email)`,
but `profiles.user_id` is `NOT NULL` with no default. Every `supabase.auth.signUp` call therefore
failed with "Database error saving new user" before the frontend could submit a join request.

## Fix
- Rebuild `handle_new_user()` so it inserts `user_id = new.id` alongside `id`.
- Use `COALESCE` for `full_name` (fall back to email username) and keep `email = new.email`.
- `ON CONFLICT (id) DO UPDATE` so a retried insert (e.g. re-signup of same email) updates rather than fails.
- SECURITY DEFINER + SET search_path = public preserved.
- No columns dropped, no data touched; only the function body changes.

## Notes
1. The function still does NOT create a membership or institution here — that stays in
   `submit_join_request` / `create_own_institution` so the caller controls tenant assignment.
2. `user_id` is populated from `new.id` (the auth user), so it is never forged by the client.
*/

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, user_id, full_name, email)
  values (
    new.id,
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.email
  )
  on conflict (id) do update
  set
    user_id    = excluded.user_id,
    full_name  = excluded.full_name,
    email      = excluded.email;
  return new;
end;
$$;

notify pgrst, 'reload schema';
