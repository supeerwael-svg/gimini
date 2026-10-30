import { useEffect, useState, useCallback, useMemo } from 'react';
import { Search, GraduationCap, MapPin, Clock, AlertCircle, BookOpen } from 'lucide-react';
import { useI18n, weekDayLabel } from '@/lib/i18n';
import { useAuth } from '@/lib/auth';
import { supabase } from '@/lib/supabase';
import { EmptyState, Spinner } from '@/components/ui';
import { isoDate, weekDayOf, timeToMinutes } from '@/lib/utils';
import type { Teacher, TeacherLessonAssignment, WeekDay } from '@/lib/types';

interface AssignmentWithJoins extends TeacherLessonAssignment {
  teachers: { name: string };
  classes: { name: string };
}

export default function TeacherSearch() {
  const { t, lang } = useI18n();
  const { profile } = useAuth();
  const instId = profile?.institution_id;
  const [teachers, setTeachers] = useState<Teacher[]>([]);
  const [assignments, setAssignments] = useState<AssignmentWithJoins[]>([]);
  const [search, setSearch] = useState('');
  const [selDate, setSelDate] = useState(isoDate(new Date()));
  const [loading, setLoading] = useState(true);

  const loadData = useCallback(async () => {
    if (!instId) { setLoading(false); return; }
    setLoading(true);
    const [tRes, aRes] = await Promise.all([
      supabase.from('teachers').select('*').eq('institution_id', instId).eq('archived', false).order('name'),
      supabase.from('teacher_lesson_assignments').select('*, teachers(name), classes(name)').eq('institution_id', instId),
    ]);
    setTeachers((tRes.data ?? []) as Teacher[]);
    setAssignments((aRes.data ?? []) as AssignmentWithJoins[]);
    setLoading(false);
  }, [instId]);

  useEffect(() => { loadData(); }, [loadData]);

  const selectedWeekDay = weekDayOf(new Date(selDate)) as WeekDay;

  const filteredTeachers = useMemo(() => {
    if (!search.trim()) return teachers;
    const q = search.toLowerCase().trim();
    return teachers.filter((tch) => tch.name.toLowerCase().includes(q));
  }, [teachers, search]);

  const getTeacherSchedule = (teacherId: string): AssignmentWithJoins[] => {
    return assignments
      .filter((a) => a.teacher_id === teacherId && a.week_day === selectedWeekDay)
      .sort((a, b) => a.start_time.localeCompare(b.start_time));
  };

  const detectOverlaps = (items: AssignmentWithJoins[]): Set<number> => {
    const overlapIdx = new Set<number>();
    for (let i = 0; i < items.length; i++) {
      for (let j = i + 1; j < items.length; j++) {
        const aStart = timeToMinutes(items[i].start_time), aEnd = timeToMinutes(items[i].end_time);
        const bStart = timeToMinutes(items[j].start_time), bEnd = timeToMinutes(items[j].end_time);
        if (aStart < bEnd && aEnd > bStart) {
          overlapIdx.add(i);
          overlapIdx.add(j);
        }
      }
    }
    return overlapIdx;
  };

  if (loading) return <Spinner label={t('loading')} />;

  return (
    <div className="space-y-4">
      <div className="card flex flex-wrap gap-3 items-end">
        <div className="flex-1 min-w-[200px]">
          <label className="label">{t('teacher_name')}</label>
          <div className="relative">
            <Search size={16} className="absolute inset-y-0 start-0 ms-3 my-auto text-muted" />
            <input
              className="input ps-9"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={t('search')}
            />
          </div>
        </div>
        <div>
          <label className="label">{t('date')}</label>
          <input type="date" className="input" value={selDate} onChange={(e) => setSelDate(e.target.value)} />
        </div>
        <div className="text-sm text-muted">
          {weekDayLabel(selectedWeekDay, lang)}
        </div>
      </div>

      {teachers.length === 0 ? (
        <div className="card"><EmptyState icon={<GraduationCap size={40} />} text={t('no_teachers')} /></div>
      ) : filteredTeachers.length === 0 ? (
        <div className="card"><EmptyState icon={<Search size={40} />} text={t('empty')} /></div>
      ) : (
        <div className="space-y-3">
          {filteredTeachers.map((tch) => {
            const schedule = getTeacherSchedule(tch.id);
            const overlaps = detectOverlaps(schedule);
            return (
              <div key={tch.id} className="card space-y-3">
                <div className="flex items-center gap-2">
                  <div className="w-10 h-10 rounded-lg flex items-center justify-center" style={{ background: 'color-mix(in srgb, var(--primary-600) 10%, transparent)', color: 'var(--primary-700)' }}>
                    <GraduationCap size={20} />
                  </div>
                  <div>
                    <div className="font-semibold">{tch.name}</div>
                    <div className="text-xs text-muted">
                      {schedule.length} {t('weekly_lessons_count')} — {weekDayLabel(selectedWeekDay, lang)}
                    </div>
                  </div>
                </div>

                {schedule.length === 0 ? (
                  <div className="surface-2 rounded-lg p-3 text-sm text-muted text-center">
                    {t('no_lessons_for_day')}
                  </div>
                ) : (
                  <div className="space-y-2">
                    {schedule.map((a, idx) => {
                      const isOverlap = overlaps.has(idx);
                      return (
                        <div
                          key={a.id}
                          className="surface-2 rounded-lg p-3 flex flex-wrap items-center gap-3"
                          style={isOverlap ? { borderInlineStart: '3px solid var(--warning)' } : { borderInlineStart: '3px solid var(--primary-400)' }}
                        >
                          <div className="flex items-center gap-1.5 text-sm font-medium">
                            <Clock size={14} className="text-muted" />
                            {a.start_time} - {a.end_time}
                          </div>
                          <div className="flex-1 min-w-[120px]">
                            <div className="font-medium text-sm">{a.subject}</div>
                            <div className="text-xs text-muted flex items-center gap-1">
                              <BookOpen size={11} /> {a.classes.name}
                            </div>
                          </div>
                          <div className="flex items-center gap-1.5 text-sm text-muted">
                            <MapPin size={14} />
                            {t('room_not_specified')}
                          </div>
                          {isOverlap && (
                            <span className="flex items-center gap-1 text-xs" style={{ color: 'var(--warning)' }}>
                              <AlertCircle size={12} /> {t('overlap_warning')}
                            </span>
                          )}
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
