import { useEffect, useState, useCallback, useMemo } from 'react';
import { CalendarClock, Search, BookOpen, User, MapPin } from 'lucide-react';
import { useI18n, weekDayLabel } from '@/lib/i18n';
import { useAuth } from '@/lib/auth';
import { supabase } from '@/lib/supabase';
import { EmptyState, Spinner } from '@/components/ui';
import { DEFAULT_WORKING_DAYS, type ClassRow, type Lesson, type WeekDay } from '@/lib/types';

interface LessonWithClass extends Lesson {
  classes: { name: string };
}

export default function TimetableSearch() {
  const { t, lang } = useI18n();
  const { profile, assignedClassIds } = useAuth();
  const instId = profile?.institution_id;
  const isAdmin = profile?.role === 'admin';
  const [classes, setClasses] = useState<ClassRow[]>([]);
  const [selClass, setSelClass] = useState('');
  const [selDay, setSelDay] = useState<WeekDay | ''>('');
  const [lessons, setLessons] = useState<LessonWithClass[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');

  const loadClasses = useCallback(async () => {
    if (!instId) { setLoading(false); return; }
    const { data } = await supabase.from('classes').select('*').eq('institution_id', instId).eq('archived', false).order('name');
    const all = (data ?? []) as ClassRow[];
    const visible = isAdmin ? all : all.filter((c) => assignedClassIds.has(c.id));
    setClasses(visible);
    setLoading(false);
  }, [instId, isAdmin, assignedClassIds]);

  useEffect(() => { loadClasses(); }, [loadClasses]);

  const loadLessons = useCallback(async () => {
    if (!instId) return;
    setLoading(true);
    let query = supabase.from('lessons').select('*, classes!inner(name, institution_id)').eq('classes.institution_id', instId);
    if (selClass) query = query.eq('class_id', selClass);
    if (selDay) query = query.eq('week_day', selDay);
    query = query.order('week_day').order('start_time');
    const { data } = await query;
    const raw = (data ?? []) as LessonWithClass[];
    setLessons(raw);
    setLoading(false);
  }, [instId, selClass, selDay]);

  useEffect(() => { loadLessons(); }, [loadLessons]);

  const filtered = useMemo(() => {
    if (!search.trim()) return lessons;
    const q = search.toLowerCase().trim();
    return lessons.filter((l) =>
      l.subject.toLowerCase().includes(q) ||
      (l.teacher_name?.toLowerCase().includes(q) ?? false) ||
      (l.room?.toLowerCase().includes(q) ?? false) ||
      l.classes.name.toLowerCase().includes(q)
    );
  }, [lessons, search]);

  const grouped = useMemo(() => {
    const map = new Map<WeekDay, LessonWithClass[]>();
    for (const l of filtered) {
      const arr = map.get(l.week_day) ?? [];
      arr.push(l);
      map.set(l.week_day, arr);
    }
    return map;
  }, [filtered]);

  if (loading && classes.length === 0) return <Spinner label={t('loading')} />;

  return (
    <div className="space-y-4">
      <div className="card flex flex-wrap gap-3 items-end">
        <div className="flex-1 min-w-[180px]">
          <label className="label">{t('filter_by_class')}</label>
          <select className="input" value={selClass} onChange={(e) => setSelClass(e.target.value)}>
            <option value="">{t('all')}</option>
            {classes.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </div>
        <div className="flex-1 min-w-[140px]">
          <label className="label">{t('filter_by_day')}</label>
          <select className="input" value={selDay} onChange={(e) => setSelDay(e.target.value as WeekDay | '')}>
            <option value="">{t('all')}</option>
            {DEFAULT_WORKING_DAYS.map((d) => <option key={d} value={d}>{weekDayLabel(d, lang)}</option>)}
          </select>
        </div>
        <div className="flex-1 min-w-[160px]">
          <label className="label">{t('search')}</label>
          <div className="relative">
            <Search size={16} className="absolute inset-y-0 start-0 ms-3 my-auto text-muted" />
            <input className="input ps-9" value={search} onChange={(e) => setSearch(e.target.value)} placeholder={t('subject')} />
          </div>
        </div>
      </div>

      {loading ? <Spinner label={t('loading')} /> :
        filtered.length === 0 ? (
          <div className="card"><EmptyState icon={<CalendarClock size={40} />} text={t('no_lessons_today')} /></div>
        ) : (
          <div className="space-y-3">
            {DEFAULT_WORKING_DAYS.filter((d) => grouped.has(d)).map((day) => (
              <div key={day} className="card">
                <h3 className="font-semibold mb-3 flex items-center gap-2">
                  <CalendarClock size={18} /> {weekDayLabel(day, lang)}
                </h3>
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead className="surface-2">
                      <tr>
                        <th className="p-2 text-start">{t('class')}</th>
                        <th className="p-2 text-start">{t('subject')}</th>
                        <th className="p-2 text-start">{t('start_time')}</th>
                        <th className="p-2 text-start">{t('end_time')}</th>
                        <th className="p-2 text-start">{t('duration')}</th>
                        <th className="p-2 text-start">{t('teacher_name')}</th>
                        <th className="p-2 text-start">{t('room')}</th>
                      </tr>
                    </thead>
                    <tbody>
                      {grouped.get(day)!.map((l) => (
                        <tr key={l.id} className="border-b border-app">
                          <td className="p-2 font-medium">{l.classes.name}</td>
                          <td className="p-2">{l.subject}</td>
                          <td className="p-2 text-muted">{l.start_time}</td>
                          <td className="p-2 text-muted">{l.end_time}</td>
                          <td className="p-2 text-muted">{l.duration_minutes}{t('minutes')}</td>
                          <td className="p-2">
                            {l.teacher_name ? (
                              <span className="flex items-center gap-1" style={{ color: 'var(--primary-600)' }}>
                                <User size={12} /> {l.teacher_name}
                              </span>
                            ) : <span className="text-muted">—</span>}
                          </td>
                          <td className="p-2">
                            {l.room ? (
                              <span className="flex items-center gap-1 text-muted"><MapPin size={12} /> {l.room}</span>
                            ) : <span className="text-muted">{t('room_not_specified')}</span>}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            ))}
          </div>
        )
      }
    </div>
  );
}
