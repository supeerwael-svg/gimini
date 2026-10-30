import { useEffect, useState, useCallback } from 'react';
import { BookOpen, Search, CalendarClock, Users, UserCog } from 'lucide-react';
import { useI18n } from '@/lib/i18n';
import { useAuth } from '@/lib/auth';
import { supabase } from '@/lib/supabase';
import { EmptyState, Spinner } from '@/components/ui';
import type { ClassRow, Lesson, Student, ClassAssignment, WeekDay } from '@/lib/types';
import { weekDayLabel } from '@/lib/i18n';
import { DEFAULT_WORKING_DAYS } from '@/lib/types';

export default function UnassignedClasses() {
  const { t, lang } = useI18n();
  const { profile, assignedClassIds } = useAuth();
  const instId = profile?.institution_id;
  const isAdmin = profile?.role === 'admin';
  const [classes, setClasses] = useState<ClassRow[]>([]);
  const [assignments, setAssignments] = useState<ClassAssignment[]>([]);
  const [studentCounts, setStudentCounts] = useState<Record<string, number>>({});
  const [lessonCounts, setLessonCounts] = useState<Record<string, number>>({});
  const [selectedClass, setSelectedClass] = useState<ClassRow | null>(null);
  const [lessons, setLessons] = useState<Lesson[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');

  const loadData = useCallback(async () => {
    if (!instId) { setLoading(false); return; }
    setLoading(true);
    const [cRes, aRes] = await Promise.all([
      supabase.from('classes').select('*').eq('institution_id', instId).eq('archived', false).order('name'),
      supabase.from('class_assignments').select('*'),
    ]);
    const allClasses = (cRes.data ?? []) as ClassRow[];
    const allAssignments = (aRes.data ?? []) as ClassAssignment[];
    setAssignments(allAssignments);

    const assignedIds = new Set(allAssignments.map((a) => a.class_id));
    const unassigned = allClasses.filter((c) => !assignedIds.has(c.id));
    setClasses(unassigned);

    const sCounts: Record<string, number> = {};
    const lCounts: Record<string, number> = {};
    for (const c of unassigned) {
      const [sRes, lRes] = await Promise.all([
        supabase.from('students').select('id', { count: 'exact', head: true }).eq('class_id', c.id).eq('archived', false),
        supabase.from('lessons').select('id', { count: 'exact', head: true }).eq('class_id', c.id),
      ]);
      sCounts[c.id] = sRes.count ?? 0;
      lCounts[c.id] = lRes.count ?? 0;
    }
    setStudentCounts(sCounts);
    setLessonCounts(lCounts);
    setLoading(false);
  }, [instId]);

  useEffect(() => { loadData(); }, [loadData]);

  const viewTimetable = async (cls: ClassRow) => {
    setSelectedClass(cls);
    const { data } = await supabase.from('lessons').select('*').eq('class_id', cls.id).order('week_day').order('start_time');
    setLessons((data ?? []) as Lesson[]);
  };

  const canViewTimetable = (cls: ClassRow) => {
    if (isAdmin) return true;
    return assignedClassIds.has(cls.id);
  };

  const filtered = classes.filter((c) =>
    c.name.toLowerCase().includes(search.toLowerCase().trim())
  );

  const lessonsByDay = (day: WeekDay) => lessons.filter((l) => l.week_day === day).sort((a, b) => a.start_time.localeCompare(b.start_time));

  if (loading) return <Spinner label={t('loading')} />;

  return (
    <div className="space-y-4">
      <div className="card flex flex-wrap gap-3 items-end">
        <div className="flex-1 min-w-[200px]">
          <label className="label">{t('search')}</label>
          <div className="relative">
            <Search size={16} className="absolute inset-y-0 start-0 ms-3 my-auto text-muted" />
            <input
              className="input ps-9"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={t('class_name')}
            />
          </div>
        </div>
        <div className="text-sm text-muted">
          {filtered.length} {t('classes')}
        </div>
      </div>

      {selectedClass && (
        <div className="card space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="font-semibold flex items-center gap-2">
              <CalendarClock size={18} /> {selectedClass.name}
            </h3>
            <button onClick={() => setSelectedClass(null)} className="btn btn-ghost text-sm">{t('cancel')}</button>
          </div>
          <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-3">
            {DEFAULT_WORKING_DAYS.map((day) => (
              <div key={day} className="surface-2 rounded-lg p-3">
                <div className="font-medium text-sm mb-2">{weekDayLabel(day, lang)}</div>
                {lessonsByDay(day).length === 0 ? (
                  <p className="text-xs text-muted py-2 text-center">{t('no_lessons_today')}</p>
                ) : (
                  <div className="space-y-1.5">
                    {lessonsByDay(day).map((l) => (
                      <div key={l.id} className="text-xs">
                        <div className="font-medium">{l.subject}</div>
                        <div className="text-muted">{l.start_time} - {l.end_time}</div>
                        {l.room && <div className="text-muted">{t('room')}: {l.room}</div>}
                        {l.teacher_name && <div style={{ color: 'var(--primary-600)' }}>{l.teacher_name}</div>}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      )}

      {!selectedClass && (
        filtered.length === 0 ? (
          <div className="card"><EmptyState icon={<BookOpen size={40} />} text={t('no_unassigned_classes')} /></div>
        ) : (
          <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-3">
            {filtered.map((c) => (
              <div key={c.id} className="card space-y-3">
                <div className="flex items-center gap-2">
                  <div className="w-10 h-10 rounded-lg flex items-center justify-center" style={{ background: 'var(--surface-2)' }}>
                    <BookOpen size={20} />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="font-semibold truncate">{c.name}</div>
                  </div>
                </div>
                <div className="flex items-center gap-4 text-sm text-muted">
                  <span className="flex items-center gap-1"><Users size={14} /> {studentCounts[c.id] ?? 0} {t('students')}</span>
                  <span className="flex items-center gap-1"><CalendarClock size={14} /> {lessonCounts[c.id] ?? 0} {t('subject')}</span>
                </div>
                <div className="flex items-center gap-2">
                  <button
                    onClick={() => viewTimetable(c)}
                    className="btn btn-ghost text-sm"
                    disabled={!canViewTimetable(c)}
                    title={canViewTimetable(c) ? t('view_timetable') : t('no_permission')}
                  >
                    <CalendarClock size={16} />{t('view_timetable')}
                  </button>
                </div>
                {!canViewTimetable(c) && (
                  <p className="text-xs text-muted">{t('unassigned_no_permission')}</p>
                )}
              </div>
            ))}
          </div>
        )
      )}
    </div>
  );
}
