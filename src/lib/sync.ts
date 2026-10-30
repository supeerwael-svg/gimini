/**
 * Sync engine: pulls institution data into local IndexedDB on login,
 * and pushes pending offline writes to Supabase when online.
 *
 * Tombstones: when a record is deleted locally, a tombstone entry is
 * written to the deletion_tombstones store. The tombstone persists until
 * the cloud delete is confirmed, preventing background refreshes from
 * resurrecting the record via localBulkPut. Once the delete succeeds
 * (immediately or via syncPending), the tombstone is removed.
 */
import { supabase } from './supabase';
import {
  localGetAll, localBulkPut, localClearAll, localDelete,
  getPendingSync, removeSyncOp, enqueueSync, pendingSyncCount,
  addTombstone, removeTombstone, getTombstone,
  type StoreName,
} from './offline-db';
import type {
  ClassRow, Student, Lesson, AttendanceRecord, TeacherAbsence,
  AbsenceEpisode, Teacher, InstitutionSettings, ClassAssignment,
  Profile, Institution, DeveloperInfo,
} from './types';

type SyncStatus = 'idle' | 'syncing' | 'online' | 'offline' | 'error';
type SyncListener = (status: SyncStatus, pending: number) => void;

let currentStatus: SyncStatus = navigator.onLine ? 'online' : 'offline';
let listeners: SyncListener[] = [];

export function onSyncStatusChange(fn: SyncListener): () => void {
  listeners.push(fn);
  fn(currentStatus, 0);
  return () => { listeners = listeners.filter((l) => l !== fn); };
}

function setStatus(s: SyncStatus, pending: number) {
  currentStatus = s;
  for (const l of listeners) l(s, pending);
}

window.addEventListener('online', () => {
  setStatus('online', 0);
  syncPending();
});
window.addEventListener('offline', () => setStatus('offline', 0));

// =========== Full data preload on login ===========

export async function preloadInstitutionData(institutionId: string): Promise<void> {
  setStatus('syncing', 0);

  const queries: { store: StoreName; fn: () => Promise<{ data: unknown[] | null }> }[] = [
    { store: 'institutions', fn: async () => { const r = await supabase.from('institutions').select('*').eq('id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'classes', fn: async () => { const r = await supabase.from('classes').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'students', fn: async () => { const r = await supabase.from('students').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'lessons', fn: async () => { const r = await supabase.from('lessons').select('*, classes!inner(institution_id)').eq('classes.institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'attendance_records', fn: async () => { const r = await supabase.from('attendance_records').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'teacher_absences', fn: async () => { const r = await supabase.from('teacher_absences').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'absence_episodes', fn: async () => { const r = await supabase.from('absence_episodes').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'teachers', fn: async () => { const r = await supabase.from('teachers').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'teacher_class_assignments', fn: async () => { const r = await supabase.from('teacher_class_assignments').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'teacher_lesson_assignments', fn: async () => { const r = await supabase.from('teacher_lesson_assignments').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'institution_settings', fn: async () => { const r = await supabase.from('institution_settings').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'class_assignments', fn: async () => { const r = await supabase.from('class_assignments').select('*, profiles!inner(institution_id)').eq('profiles.institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'profiles', fn: async () => { const r = await supabase.from('profiles').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
    { store: 'developer_info', fn: async () => { const r = await supabase.from('developer_info').select('*').eq('institution_id', institutionId); return { data: r.data as unknown[] | null }; } },
  ];

  await localClearAll();

  const results = await Promise.allSettled(queries.map((q) => q.fn()));
  for (let i = 0; i < results.length; i++) {
    const result = results[i];
    const { store } = queries[i];
    if (result.status === 'fulfilled' && result.value.data) {
      let rows = result.value.data as Record<string, unknown>[];
      if (store === 'lessons') {
        rows = rows.map((r) => {
          const { classes: _c, ...rest } = r;
          return rest;
        });
      }
      if (store === 'class_assignments') {
        rows = rows.map((r) => {
          const { profiles: _p, ...rest } = r;
          return rest;
        });
      }
      // Filter out any rows that have active tombstones (pending deletions)
      const tombstoned = new Set<string>();
      for (const row of rows) {
        const id = row.id as string;
        const ts = await getTombstone(id);
        if (ts) tombstoned.add(id);
      }
      const filtered = rows.filter((r) => !tombstoned.has(r.id as string));
      await localBulkPut(store, filtered as { id: string }[]);
    }
  }

  const pending = await pendingSyncCount();
  setStatus(navigator.onLine ? 'online' : 'offline', pending);
}

// =========== Push pending writes to Supabase ===========

export async function syncPending(): Promise<void> {
  if (!navigator.onLine) return;
  const ops = await getPendingSync();
  if (ops.length === 0) return;

  setStatus('syncing', ops.length);

  let hadError = false;

  for (const op of ops) {
    try {
      const table = supabase.from(op.table_name);
      let result;
      if (op.operation === 'delete') {
        result = await table.delete().eq('id', op.record_id);
      } else if (op.operation === 'insert') {
        result = await table.insert(op.payload);
      } else {
        result = await table.update(op.payload).eq('id', op.record_id);
      }

      if (result.error) {
        const code = result.error.code ?? '';
        // 42501 = RLS denial; retrying won't help — mark error but don't infinite-loop
        if (code === '42501') {
          console.error(`[sync] Authorization error on ${op.operation} ${op.table_name} ${op.record_id}:`, result.error.message);
          hadError = true;
          continue; // leave in queue, skip removal
        }
        // Other errors (network, timeout, constraint) — leave for retry
        hadError = true;
        continue;
      }

      // Success — remove from queue and clean up tombstone if it was a delete
      await removeSyncOp(op.id);
      if (op.operation === 'delete') {
        await removeTombstone(op.record_id);
      }
    } catch {
      // Network-level failure — leave in queue for retry
      hadError = true;
    }
  }

  const remaining = await pendingSyncCount();
  setStatus(remaining > 0 ? (hadError ? 'error' : 'online') : 'online', remaining);
}

// =========== Write-through: local + queue ===========

export async function writeThrough<T extends { id: string }>(
  store: StoreName,
  table: string,
  record: T,
  operation: 'insert' | 'update',
): Promise<void> {
  const rec = record as unknown as Record<string, unknown>;
  // If there was a tombstone for this id (e.g. re-creating a previously-deleted record),
  // remove it — the new write supersedes the deletion.
  await removeTombstone(record.id);
  // Write to local immediately
  await localBulkPut(store, [rec as { id: string }]);
  // If online, push directly; otherwise queue
  if (navigator.onLine) {
    try {
      let result;
      if (operation === 'insert') {
        result = await supabase.from(table).insert(rec);
      } else {
        result = await supabase.from(table).update(rec).eq('id', record.id);
      }
      if (result.error) {
        // Cloud write failed — enqueue for retry
        await enqueueSync({ table_name: table, operation, record_id: record.id, payload: rec });
      }
    } catch {
      await enqueueSync({ table_name: table, operation, record_id: record.id, payload: rec });
    }
  } else {
    await enqueueSync({ table_name: table, operation, record_id: record.id, payload: rec });
  }
}

export async function deleteThrough(store: StoreName, table: string, id: string): Promise<void> {
  // Delete from local immediately
  await localDelete(store, id);
  // Write tombstone to prevent resurrection by background refresh
  await addTombstone({
    id,
    store_name: store,
    table_name: table,
    deleted_at: new Date().toISOString(),
  });
  if (navigator.onLine) {
    try {
      const result = await supabase.from(table).delete().eq('id', id);
      if (result.error) {
        // Cloud delete failed — enqueue for retry, keep tombstone
        await enqueueSync({ table_name: table, operation: 'delete', record_id: id, payload: {} });
      } else {
        // Cloud delete confirmed — remove tombstone
        await removeTombstone(id);
      }
    } catch {
      // Network failure — enqueue for retry, keep tombstone
      await enqueueSync({ table_name: table, operation: 'delete', record_id: id, payload: {} });
    }
  } else {
    await enqueueSync({ table_name: table, operation: 'delete', record_id: id, payload: {} });
  }
}

export function getSyncStatus(): SyncStatus {
  return currentStatus;
}

// Re-export for convenience
export { localGetAll, localDelete, enqueueSync, pendingSyncCount, getTombstone, removeTombstone };
