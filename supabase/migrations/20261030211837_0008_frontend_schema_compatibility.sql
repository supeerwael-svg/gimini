/*
# Frontend Schema Compatibility and Missing RPCs

## Purpose
Adds the tables, columns, RPC functions, permissions, and RLS policies required
by the imported EduTrack frontend while preserving all existing tables, data,
and security policies.

## Existing tables extended
- `profiles`: adds `user_id`, `institution_id`, `role`, `disabled`,
  `force_password_change` so the frontend profile/supervisor flows work.
- `institutions`: adds `joining_code`, `code_revoked_at`, `code_expires_at`,
  `updated_at`.
- `memberships`: adds `approved`.
- `classes`: adds `archived`, `updated_at`.
- `class_assignments`: adds `profile_id`; `membership_id` made nullable.

## New tables
- `students`, `lessons`, `attendance_records`, `teacher_absences`,
  `absence_episodes`, `teachers`, `teacher_class_assignments`,
  `teacher_lesson_assignments`, `institution_settings`, `developer_info`,
  `join_requests`, `audit_events`.

## RPC functions
- `create_own_institution(p_full_name text, p_name text)`
- `complete_admin_signup(p_institution_name text, p_full_name text)`
- `submit_join_request(p_institution_code text, p_email text, p_full_name text)`
- `get_own_join_request_status()`
- `list_joinable_institutions()`
- `approve_join_request(p_request_id uuid)`
- `reject_join_request(p_request_id uuid)`
- `regenerate_joining_code(p_inst uuid)`

## Security
- RLS enabled on every new table.
- anon has no access; authenticated reads/writes are institution-scoped via is_member.
- All admin RPCs are SECURITY DEFINER with General Supervisor checks.
- PostgREST schema cache reloaded at the end.

## Important notes
1. No existing columns, policies, or data are dropped.
2. Migration is idempotent (uses IF NOT EXISTS / DO blocks).
*/

-- ---------------------------------------------------------------------------
-- Compatibility columns on existing objects
-- ---------------------------------------------------------------------------

alter table public.profiles add column if not exists user_id uuid;
alter table public.profiles add column if not exists institution_id uuid;
alter table public.profiles add column if not exists role text not null default 'supervisor';
alter table public.profiles add column if not exists disabled boolean not null default false;
alter table public.profiles add column if not exists force_password_change boolean not null default false;
update public.profiles set user_id = id where user_id is null;
alter table public.profiles alter column user_id set not null;
create unique index if not exists idx_profiles_user_id_unique on public.profiles(user_id);

alter table public.institutions add column if not exists joining_code text;
alter table public.institutions add column if not exists code_revoked_at timestamptz;
alter table public.institutions add column if not exists code_expires_at timestamptz;
alter table public.institutions add column if not exists updated_at timestamptz not null default now();
create unique index if not exists idx_institutions_joining_code_unique on public.institutions(joining_code) where joining_code is not null;

alter table public.memberships add column if not exists approved boolean not null default true;

alter table public.classes add column if not exists archived boolean not null default false;
alter table public.classes add column if not exists updated_at timestamptz not null default now();

alter table public.class_assignments add column if not exists profile_id uuid;
alter table public.class_assignments alter column membership_id drop not null;
create unique index if not exists idx_class_assignments_profile_class on public.class_assignments(profile_id, class_id) where profile_id is not null;

-- updated_at triggers
create or replace function public.set_updated_at()
returns trigger language plpgsql security definer set search_path = public
as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists trg_institutions_updated_at on public.institutions;
create trigger trg_institutions_updated_at before update on public.institutions
for each row execute function public.set_updated_at();

drop trigger if exists trg_classes_updated_at on public.classes;
create trigger trg_classes_updated_at before update on public.classes
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- New application tables
-- ---------------------------------------------------------------------------

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete restrict,
  first_name text not null,
  last_name text not null,
  birth_date date,
  gender text check (gender is null or gender in ('male','female')),
  repetition_status text not null default 'none',
  boarding text not null default 'day',
  enrolled boolean not null default true,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lessons (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  week_day text not null,
  subject text not null,
  start_time time not null,
  end_time time not null,
  duration_minutes integer not null default 0,
  room text,
  teacher_name text,
  effective_from date not null default current_date,
  created_at timestamptz not null default now()
);

-- Auto-compute duration_minutes from start_time/end_time on insert/update
create or replace function public.compute_lesson_duration()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  new.duration_minutes := extract(epoch from (new.end_time - new.start_time)) / 60;
  return new;
end;
$$;

drop trigger if exists trg_lessons_duration on public.lessons;
create trigger trg_lessons_duration before insert or update on public.lessons
for each row execute function public.compute_lesson_duration();

create table if not exists public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  lesson_id uuid references public.lessons(id) on delete set null,
  record_date date not null,
  subject_snapshot text not null default '',
  start_time_snapshot time,
  end_time_snapshot time,
  duration_minutes_snapshot integer not null default 0,
  status text not null check (status in ('absent','present','excused')),
  recorded_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.teacher_absences (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  class_id uuid references public.classes(id) on delete set null,
  teacher_name text not null,
  subject text,
  record_date date not null,
  start_time time,
  end_time time,
  reason text,
  notes text,
  status text not null default 'active' check (status in ('active','cancelled')),
  cancelled_by uuid references auth.users(id),
  cancelled_at timestamptz,
  recorded_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.absence_episodes (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete cascade,
  start_date date not null,
  end_date date,
  status text not null default 'open' check (status in ('open','closed')),
  consecutive_absent_days integer not null default 0,
  first_notice_date date,
  second_notice_date date,
  prolonged_notice_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.teachers (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  name text not null,
  email text,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.teacher_class_assignments (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete cascade,
  subject text not null default '',
  created_at timestamptz not null default now(),
  unique (teacher_id, class_id, subject)
);

create table if not exists public.teacher_lesson_assignments (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete cascade,
  subject text not null default '',
  week_day text not null,
  start_time time not null,
  end_time time not null,
  created_at timestamptz not null default now()
);

create table if not exists public.institution_settings (
  institution_id uuid primary key references public.institutions(id) on delete cascade,
  working_days text[] not null default array['sunday','monday','tuesday','wednesday','thursday'],
  first_notice_days integer not null default 3,
  second_notice_days integer not null default 5,
  prolonged_notice_days integer not null default 10,
  excused_counts_as_absent boolean not null default false,
  excel_template_url text,
  total_rooms integer not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.developer_info (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null unique references public.institutions(id) on delete cascade,
  dev_name text not null default '',
  app_name text not null default 'EduTrack',
  app_version text not null default '1.0.0',
  contact_email text,
  contact_phone text,
  website text,
  description text,
  support_hours text,
  whatsapp_group_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.join_requests (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  applicant_email text not null,
  applicant_name text not null,
  status text not null default 'pending' check (status in ('pending','accepted','rejected')),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists idx_join_requests_pending_unique
  on public.join_requests(institution_id, user_id) where status = 'pending';

create table if not exists public.audit_events (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  actor uuid references auth.users(id),
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- RLS and grants for new tables
-- ---------------------------------------------------------------------------

alter table public.students enable row level security;
alter table public.lessons enable row level security;
alter table public.attendance_records enable row level security;
alter table public.teacher_absences enable row level security;
alter table public.absence_episodes enable row level security;
alter table public.teachers enable row level security;
alter table public.teacher_class_assignments enable row level security;
alter table public.teacher_lesson_assignments enable row level security;
alter table public.institution_settings enable row level security;
alter table public.developer_info enable row level security;
alter table public.join_requests enable row level security;
alter table public.audit_events enable row level security;

grant select, insert, update, delete on public.students, public.lessons, public.attendance_records,
  public.teacher_absences, public.absence_episodes, public.teachers,
  public.teacher_class_assignments, public.teacher_lesson_assignments,
  public.institution_settings, public.developer_info to authenticated;
grant select on public.join_requests, public.audit_events to authenticated;
grant all on public.students, public.lessons, public.attendance_records,
  public.teacher_absences, public.absence_episodes, public.teachers,
  public.teacher_class_assignments, public.teacher_lesson_assignments,
  public.institution_settings, public.developer_info, public.join_requests,
  public.audit_events to service_role;

-- Institution-scoped CRUD for operational tables
drop policy if exists "students_select_member" on public.students;
create policy "students_select_member" on public.students for select to authenticated using (public.is_member(institution_id));
drop policy if exists "students_insert_member" on public.students;
create policy "students_insert_member" on public.students for insert to authenticated with check (public.is_member(institution_id));
drop policy if exists "students_update_member" on public.students;
create policy "students_update_member" on public.students for update to authenticated using (public.is_member(institution_id)) with check (public.is_member(institution_id));
drop policy if exists "students_delete_member" on public.students;
create policy "students_delete_member" on public.students for delete to authenticated using (public.is_member(institution_id));

-- Institution-scoped tables: select + insert/update/delete
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'teacher_absences','absence_episodes','teachers',
    'teacher_class_assignments','teacher_lesson_assignments',
    'institution_settings','developer_info','audit_events'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS "%s_select_member" ON public.%I', t, t);
    EXECUTE format('CREATE POLICY "%s_select_member" ON public.%I FOR SELECT TO authenticated USING (public.is_member(institution_id))', t, t);
  END LOOP;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'teacher_absences','absence_episodes','teachers',
    'teacher_class_assignments','teacher_lesson_assignments',
    'institution_settings','developer_info'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS "%s_insert_member" ON public.%I', t, t);
    EXECUTE format('CREATE POLICY "%s_insert_member" ON public.%I FOR INSERT TO authenticated WITH CHECK (public.is_member(institution_id))', t, t);
    EXECUTE format('DROP POLICY IF EXISTS "%s_update_member" ON public.%I', t, t);
    EXECUTE format('CREATE POLICY "%s_update_member" ON public.%I FOR UPDATE TO authenticated USING (public.is_member(institution_id)) WITH CHECK (public.is_member(institution_id))', t, t);
    EXECUTE format('DROP POLICY IF EXISTS "%s_delete_member" ON public.%I', t, t);
    EXECUTE format('CREATE POLICY "%s_delete_member" ON public.%I FOR DELETE TO authenticated USING (public.is_member(institution_id))', t, t);
  END LOOP;
END $$;

-- Lessons are scoped through classes (no direct institution_id)
drop policy if exists "lessons_select_member" on public.lessons;
create policy "lessons_select_member" on public.lessons for select to authenticated
  using (exists (select 1 from public.classes c where c.id = lessons.class_id and public.is_member(c.institution_id)));
drop policy if exists "lessons_insert_member" on public.lessons;
create policy "lessons_insert_member" on public.lessons for insert to authenticated
  with check (exists (select 1 from public.classes c where c.id = lessons.class_id and public.is_member(c.institution_id)));
drop policy if exists "lessons_update_member" on public.lessons;
create policy "lessons_update_member" on public.lessons for update to authenticated
  using (exists (select 1 from public.classes c where c.id = lessons.class_id and public.is_member(c.institution_id)))
  with check (exists (select 1 from public.classes c where c.id = lessons.class_id and public.is_member(c.institution_id)));
drop policy if exists "lessons_delete_member" on public.lessons;
create policy "lessons_delete_member" on public.lessons for delete to authenticated
  using (exists (select 1 from public.classes c where c.id = lessons.class_id and public.is_member(c.institution_id)));

-- Attendance records scoped by institution_id
drop policy if exists "attendance_records_select_member" on public.attendance_records;
create policy "attendance_records_select_member" on public.attendance_records for select to authenticated using (public.is_member(institution_id));
drop policy if exists "attendance_records_insert_member" on public.attendance_records;
create policy "attendance_records_insert_member" on public.attendance_records for insert to authenticated with check (public.is_member(institution_id));
drop policy if exists "attendance_records_update_member" on public.attendance_records;
create policy "attendance_records_update_member" on public.attendance_records for update to authenticated using (public.is_member(institution_id)) with check (public.is_member(institution_id));
drop policy if exists "attendance_records_delete_member" on public.attendance_records;
create policy "attendance_records_delete_member" on public.attendance_records for delete to authenticated using (public.is_member(institution_id));

-- Join requests: own or admin
drop policy if exists "join_requests_select_own_or_admin" on public.join_requests;
create policy "join_requests_select_own_or_admin" on public.join_requests for select to authenticated
  using (auth.uid() = user_id or public.is_general_supervisor(institution_id));

-- Audit events: admin only
drop policy if exists "audit_events_select_admin" on public.audit_events;
create policy "audit_events_select_admin" on public.audit_events for select to authenticated
  using (public.is_general_supervisor(institution_id));

-- Extend existing classes/class_assignments for frontend CRUD
grant insert, update, delete on public.classes to authenticated;
drop policy if exists "classes_insert_member" on public.classes;
create policy "classes_insert_member" on public.classes for insert to authenticated with check (public.is_member(institution_id));
drop policy if exists "classes_update_member" on public.classes;
create policy "classes_update_member" on public.classes for update to authenticated using (public.is_member(institution_id)) with check (public.is_member(institution_id));
drop policy if exists "classes_delete_member" on public.classes;
create policy "classes_delete_member" on public.classes for delete to authenticated using (public.is_member(institution_id));

grant select, insert, update, delete on public.class_assignments to authenticated;
drop policy if exists "class_assignments_insert_member" on public.class_assignments;
create policy "class_assignments_insert_member" on public.class_assignments for insert to authenticated
  with check (exists (select 1 from public.classes c where c.id = class_assignments.class_id and public.is_member(c.institution_id)));
drop policy if exists "class_assignments_update_member" on public.class_assignments;
create policy "class_assignments_update_member" on public.class_assignments for update to authenticated
  using (exists (select 1 from public.classes c where c.id = class_assignments.class_id and public.is_member(c.institution_id)))
  with check (exists (select 1 from public.classes c where c.id = class_assignments.class_id and public.is_member(c.institution_id)));
drop policy if exists "class_assignments_delete_member" on public.class_assignments;
create policy "class_assignments_delete_member" on public.class_assignments for delete to authenticated
  using (exists (select 1 from public.classes c where c.id = class_assignments.class_id and public.is_member(c.institution_id)));

-- Allow profiles full_name/email update (frontend updates these)
grant update (full_name, email) on public.profiles to authenticated;

-- Allow institutions name update (admin only via RLS)
grant update (name) on public.institutions to authenticated;
drop policy if exists "institutions_update_gs" on public.institutions;
create policy "institutions_update_gs" on public.institutions for update to authenticated
  using (public.is_general_supervisor(id)) with check (public.is_general_supervisor(id));

-- Allow memberships delete for admin (remove supervisor)
grant delete on public.memberships to authenticated;
drop policy if exists "memberships_delete_gs" on public.memberships;
create policy "memberships_delete_gs" on public.memberships for delete to authenticated
  using (public.is_general_supervisor(institution_id));

-- Allow profiles update institution_id for admin (unlink supervisor)
-- The existing profiles_update_own policy only allows own profile update.
-- Add a GS-scoped update policy for institution_id and disabled columns.
drop policy if exists "profiles_update_gs" on public.profiles;
create policy "profiles_update_gs" on public.profiles for update to authenticated
  using (exists (
    select 1 from public.memberships m
    where m.user_id = profiles.user_id
      and public.is_general_supervisor(m.institution_id)
  ))
  with check (exists (
    select 1 from public.memberships m
    where m.user_id = profiles.user_id
      and public.is_general_supervisor(m.institution_id)
  ));
grant update (institution_id, disabled) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- RPC functions
-- ---------------------------------------------------------------------------

create or replace function public.create_own_institution(p_full_name text, p_name text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_inst public.institutions%rowtype;
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;
  if nullif(trim(p_name), '') is null then
    raise exception 'Institution name is required.';
  end if;

  v_code := upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 8));

  insert into public.institutions (name, created_by, joining_code, code_expires_at)
  values (trim(p_name), auth.uid(), v_code, now() + interval '24 hours')
  returning * into v_inst;

  update public.profiles
  set user_id = auth.uid(),
      institution_id = v_inst.id,
      role = 'admin',
      full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
      updated_at = now()
  where id = auth.uid();

  insert into public.memberships (institution_id, user_id, role, status, approved)
  values (v_inst.id, auth.uid(), 'general_supervisor', 'active', true)
  on conflict (institution_id, user_id)
  do update set role = 'general_supervisor', status = 'active', approved = true;

  insert into public.institution_settings (institution_id)
  values (v_inst.id) on conflict do nothing;

  insert into public.audit_events (institution_id, actor, action, detail)
  values (v_inst.id, auth.uid(), 'institution_created', jsonb_build_object('name', v_inst.name));

  return jsonb_build_object('success', true, 'institution_id', v_inst.id, 'joining_code', v_code);
end;
$$;

create or replace function public.complete_admin_signup(p_institution_name text, p_full_name text)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  return public.create_own_institution(p_full_name, p_institution_name);
end;
$$;

create or replace function public.submit_join_request(p_institution_code text, p_email text, p_full_name text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_inst public.institutions%rowtype;
  v_req public.join_requests%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select * into v_inst from public.institutions
  where joining_code = upper(trim(p_institution_code))
  for update;

  if not found then
    raise exception 'invalid_code';
  end if;

  if v_inst.code_revoked_at is not null then
    raise exception 'code_revoked';
  end if;

  if v_inst.code_expires_at is not null and v_inst.code_expires_at <= now() then
    raise exception 'code_expired';
  end if;

  if exists (
    select 1 from public.memberships
    where institution_id = v_inst.id and user_id = auth.uid() and status = 'active'
  ) then
    raise exception 'already_member';
  end if;

  if exists (
    select 1 from public.join_requests
    where institution_id = v_inst.id and user_id = auth.uid() and status = 'pending'
  ) then
    raise exception 'duplicate_pending';
  end if;

  update public.profiles
  set full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
      email = coalesce(nullif(trim(p_email), ''), email),
      updated_at = now()
  where id = auth.uid();

  insert into public.join_requests (institution_id, user_id, applicant_email, applicant_name, status)
  values (v_inst.id, auth.uid(), coalesce(p_email, ''), coalesce(p_full_name, ''), 'pending')
  returning * into v_req;

  return jsonb_build_object('success', true, 'request_id', v_req.id);
end;
$$;

create or replace function public.get_own_join_request_status()
returns table (
  status text,
  institution_name text,
  created_at timestamptz
)
language sql security definer set search_path = public
as $$
  select r.status::text, i.name, r.created_at
  from public.join_requests r
  join public.institutions i on i.id = r.institution_id
  where r.user_id = auth.uid()
  order by r.created_at desc
  limit 1;
$$;

create or replace function public.list_joinable_institutions()
returns table (
  id uuid,
  name text
)
language sql security definer set search_path = public
as $$
  select i.id, i.name
  from public.institutions i
  where i.joining_code is not null
    and i.code_revoked_at is null
    and (i.code_expires_at is null or i.code_expires_at > now())
    and not exists (
      select 1 from public.memberships m
      where m.institution_id = i.id and m.user_id = auth.uid() and m.status = 'active'
    )
  order by i.name;
$$;

create or replace function public.approve_join_request(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_req public.join_requests%rowtype;
begin
  select * into v_req from public.join_requests where id = p_request_id for update;

  if not found then
    raise exception 'Request not found.';
  end if;

  if not public.is_general_supervisor(v_req.institution_id) then
    raise exception 'Only a General Supervisor can approve join requests.';
  end if;

  if v_req.status <> 'pending' then
    raise exception 'This request has already been processed.';
  end if;

  insert into public.memberships (institution_id, user_id, role, status, approved)
  values (v_req.institution_id, v_req.user_id, 'regular_supervisor', 'active', true)
  on conflict (institution_id, user_id)
  do update set status = 'active', approved = true, role = 'regular_supervisor';

  update public.profiles
  set institution_id = v_req.institution_id,
      role = 'supervisor',
      full_name = coalesce(nullif(v_req.applicant_name, ''), full_name),
      updated_at = now()
  where id = v_req.user_id;

  update public.join_requests
  set status = 'accepted', decided_by = auth.uid(), decided_at = now(), updated_at = now()
  where id = p_request_id;

  insert into public.audit_events (institution_id, actor, action, detail)
  values (v_req.institution_id, auth.uid(), 'approve_join_request',
    jsonb_build_object('email', v_req.applicant_email, 'user_id', v_req.user_id));

  return jsonb_build_object('success', true);
end;
$$;

create or replace function public.reject_join_request(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_req public.join_requests%rowtype;
begin
  select * into v_req from public.join_requests where id = p_request_id for update;

  if not found then
    raise exception 'Request not found.';
  end if;

  if not public.is_general_supervisor(v_req.institution_id) then
    raise exception 'Only a General Supervisor can reject join requests.';
  end if;

  if v_req.status <> 'pending' then
    raise exception 'This request has already been processed.';
  end if;

  update public.join_requests
  set status = 'rejected', decided_by = auth.uid(), decided_at = now(), updated_at = now()
  where id = p_request_id;

  insert into public.audit_events (institution_id, actor, action, detail)
  values (v_req.institution_id, auth.uid(), 'reject_join_request',
    jsonb_build_object('email', v_req.applicant_email, 'user_id', v_req.user_id));

  return jsonb_build_object('success', true);
end;
$$;

create or replace function public.regenerate_joining_code(p_inst uuid)
returns text language plpgsql security definer set search_path = public
as $$
declare
  v_code text;
begin
  if not public.is_general_supervisor(p_inst) then
    raise exception 'Only a General Supervisor can regenerate invitation codes.';
  end if;

  v_code := upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 8));

  update public.institutions
  set joining_code = v_code,
      code_revoked_at = null,
      code_expires_at = now() + interval '24 hours',
      updated_at = now()
  where id = p_inst;

  insert into public.audit_events (institution_id, actor, action, detail)
  values (p_inst, auth.uid(), 'regenerate_joining_code', jsonb_build_object('code', v_code));

  return v_code;
end;
$$;

-- RPC grants: authenticated only
revoke execute on function public.create_own_institution(text, text) from public, anon;
revoke execute on function public.complete_admin_signup(text, text) from public, anon;
revoke execute on function public.submit_join_request(text, text, text) from public, anon;
revoke execute on function public.get_own_join_request_status() from public, anon;
revoke execute on function public.list_joinable_institutions() from public, anon;
revoke execute on function public.approve_join_request(uuid) from public, anon;
revoke execute on function public.reject_join_request(uuid) from public, anon;
revoke execute on function public.regenerate_joining_code(uuid) from public, anon;

grant execute on function public.create_own_institution(text, text) to authenticated;
grant execute on function public.complete_admin_signup(text, text) to authenticated;
grant execute on function public.submit_join_request(text, text, text) to authenticated;
grant execute on function public.get_own_join_request_status() to authenticated;
grant execute on function public.list_joinable_institutions() to authenticated;
grant execute on function public.approve_join_request(uuid) to authenticated;
grant execute on function public.reject_join_request(uuid) to authenticated;
grant execute on function public.regenerate_joining_code(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
create index if not exists idx_students_institution on public.students(institution_id);
create index if not exists idx_students_class on public.students(class_id);
create index if not exists idx_lessons_class on public.lessons(class_id);
create index if not exists idx_attendance_institution_date on public.attendance_records(institution_id, record_date);
create index if not exists idx_teacher_absences_institution_date on public.teacher_absences(institution_id, record_date);
create index if not exists idx_absence_episodes_institution_status on public.absence_episodes(institution_id, status);
create index if not exists idx_teachers_institution on public.teachers(institution_id);
create index if not exists idx_join_requests_institution_status on public.join_requests(institution_id, status);
create index if not exists idx_audit_events_institution_created on public.audit_events(institution_id, created_at desc);

-- Reload PostgREST schema cache
notify pgrst, 'reload schema';
