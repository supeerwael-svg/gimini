import { useState, useEffect } from 'react';
import { supabase } from '@/lib/supabase';
import {
  Clock, CheckCircle2, XCircle, LogOut, AlertTriangle, RotateCw,
  Building2, Plus, KeyRound, ArrowLeft, Search,
} from 'lucide-react';
import { I18nProvider, useI18n } from '@/lib/i18n';
import { AuthProvider, useAuth } from '@/lib/auth';
import Login from '@/components/Login';
import Layout, { type PageKey } from '@/components/Layout';
import Dashboard from '@/pages/Dashboard';
import Classes from '@/pages/Classes';
import Students from '@/pages/Students';
import Timetables from '@/pages/Timetables';
import TimetableSearch from '@/pages/TimetableSearch';
import UnassignedClasses from '@/pages/UnassignedClasses';
import TeacherSearch from '@/pages/TeacherSearch';
import TeacherAssignments from '@/pages/TeacherAssignments';
import Attendance from '@/pages/Attendance';
import TeacherAbsencePage from '@/pages/TeacherAbsence';
import DailyReports from '@/pages/DailyReports';
import MonthlyReports from '@/pages/MonthlyReports';
import StudentStats from '@/pages/StudentStats';
import AbsenceFollowup from '@/pages/AbsenceFollowup';
import Supervisors from '@/pages/Supervisors';
import InstitutionSettingsPage from '@/pages/InstitutionSettingsPage';
import DatabaseSettings from '@/pages/DatabaseSettings';
import BackupRestore from '@/pages/BackupRestore';
import DeveloperInfoPage from '@/pages/DeveloperInfoPage';
import SettingsPage from '@/pages/SettingsPage';
import { Spinner } from '@/components/ui';

function PendingScreen() {
  const { t } = useI18n();
  const { profile, joinRequestInfo, signOut } = useAuth();

  const status = joinRequestInfo?.status ?? 'pending';
  const icon = status === 'accepted' ? <CheckCircle2 size={48} /> :
    status === 'rejected' ? <XCircle size={48} /> :
    <Clock size={48} />;

  const color = status === 'accepted' ? 'var(--success)' :
    status === 'rejected' ? 'var(--error)' :
    'var(--warning)';

  const message = status === 'accepted' ? t('request_status_accepted') :
    status === 'rejected' ? t('request_status_rejected') :
    t('request_status_pending');

  return (
    <div className="min-h-screen flex flex-col items-center justify-center p-6" style={{ background: 'var(--bg)' }}>
      <div className="card max-w-md w-full text-center space-y-4">
        <div className="inline-flex items-center justify-center w-20 h-20 rounded-full mx-auto" style={{ background: `color-mix(in srgb, ${color} 14%, transparent)`, color }}>
          {icon}
        </div>
        <h2 className="text-xl font-bold">{profile?.full_name || profile?.email}</h2>
        <p className="text-sm text-muted">{message}</p>
        {joinRequestInfo && status === 'pending' && (
          <div className="surface-2 rounded-lg p-3 text-xs text-muted">
            <div>{t('institution_name')}: {joinRequestInfo.institutionName}</div>
            <div>{t('request_date')}: {new Date(joinRequestInfo.createdAt).toLocaleDateString('ar-DZ')}</div>
          </div>
        )}
        <button onClick={() => signOut()} className="btn btn-ghost mt-4">
          <LogOut size={18} />{t('sign_out')}
        </button>
      </div>
    </div>
  );
}

function ErrorScreen() {
  const { t } = useI18n();
  const { retryInit, signOut } = useAuth();
  return (
    <div className="min-h-screen flex flex-col items-center justify-center p-6" style={{ background: 'var(--bg)' }}>
      <div className="card max-w-md w-full text-center space-y-4">
        <div className="inline-flex items-center justify-center w-20 h-20 rounded-full mx-auto" style={{ background: 'color-mix(in srgb, var(--error) 14%, transparent)', color: 'var(--error)' }}>
          <AlertTriangle size={48} />
        </div>
        <h2 className="text-xl font-bold">{t('loading_failed')}</h2>
        <p className="text-sm text-muted">{t('loading_failed_desc')}</p>
        <div className="flex justify-center gap-2 pt-2">
          <button onClick={() => retryInit()} className="btn btn-primary">
            <RotateCw size={18} />{t('retry')}
          </button>
          <button onClick={() => signOut()} className="btn btn-ghost">
            <LogOut size={18} />{t('sign_out')}
          </button>
        </div>
      </div>
    </div>
  );
}

function SetupInstitutionScreen() {
  const { t, lang } = useI18n();
  const { profile, createInstitution, registerSupervisor, signOut, refreshProfile } = useAuth();
  const [tab, setTab] = useState<'choose' | 'create' | 'join'>('choose');
  const [instName, setInstName] = useState('');
  const [fullName, setFullName] = useState(profile?.full_name || '');
  const [joiningCode, setJoiningCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [institutions, setInstitutions] = useState<{ id: string; name: string }[]>([]);

  const ERR_MAP: Record<string, { ar: string; en: string }> = {
    invalid_code: { ar: 'رمز الدعوة غير صحيح', en: 'Invalid invitation code' },
    code_revoked: { ar: 'تم إلغاء رمز الدعوة. اطلب من مدير المؤسسة توليد رمز جديد', en: 'The invitation code has been revoked. Ask the institution admin to generate a new one' },
    code_expired: { ar: 'انتهت صلاحية رمز الدعوة. اطلب من مدير المؤسسة توليد رمز جديد', en: 'The invitation code has expired. Ask the institution admin to generate a new one' },
    duplicate_pending: { ar: 'لديك طلب انضمام قيد المراجعة بالفعل لهذه المؤسسة', en: 'You already have a pending join request for this institution' },
    duplicate_pending_request: { ar: 'لديك طلب انضمام قيد المراجعة بالفعل', en: 'You already have a pending join request' },
    already_member: { ar: 'أنت عضو بالفعل في هذه المؤسسة', en: 'You are already a member of this institution' },
    timeout: { ar: 'انتهت مهلة الاتصال. تحقق من الإنترنت وأعد المحاولة', en: 'Connection timed out. Check your internet and try again' },
  };

  const mapError = (err: string): string => {
    for (const [key, val] of Object.entries(ERR_MAP)) {
      if (err.includes(key)) return lang === 'ar' ? val.ar : val.en;
    }
    return err;
  };

  useEffect(() => {
    if (tab === 'join') {
      (async () => {
        try {
          const { data } = await supabase.rpc('list_joinable_institutions');
          if (data && Array.isArray(data)) {
            setInstitutions(data as { id: string; name: string }[]);
          }
        } catch {
          // ignore
        }
      })();
    }
  }, [tab]);

  const doCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy || !instName.trim()) return;
    setBusy(true); setError(null);
    const { error } = await createInstitution(instName.trim(), fullName.trim() || profile?.email || '');
    setBusy(false);
    if (error) {
      setError(error);
    } else {
      setSuccess(t('institution_created'));
      setTimeout(() => refreshProfile(), 500);
    }
  };

  const doJoin = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy || !joiningCode.trim()) return;
    setBusy(true); setError(null);
    const { error } = await registerSupervisor(
      profile?.email || '',
      '',
      fullName.trim() || profile?.full_name || '',
      joiningCode.trim()
    );
    setBusy(false);
    if (error) {
      setError(mapError(error));
    } else {
      setSuccess(t('join_success'));
      setTimeout(() => refreshProfile(), 500);
    }
  };

  const backBtn = () => (
    <button type="button" onClick={() => { setTab('choose'); setError(null); setSuccess(null); }} className="btn-ghost btn p-1.5">
      <ArrowLeft size={18} className={lang === 'ar' ? 'rotate-180' : ''} />
    </button>
  );

  return (
    <div className="min-h-screen flex flex-col items-center justify-center p-6" style={{ background: 'var(--bg)' }}>
      <div className="card max-w-md w-full space-y-4">
        {success ? (
          <div className="text-center space-y-4 py-4">
            <div className="inline-flex items-center justify-center w-16 h-16 rounded-full mx-auto" style={{ background: 'color-mix(in srgb, var(--success) 14%, transparent)', color: 'var(--success)' }}>
              <CheckCircle2 size={32} />
            </div>
            <p className="text-sm font-medium">{success}</p>
            <Spinner label={t('loading')} />
          </div>
        ) : tab === 'choose' ? (
          <>
            <div className="text-center space-y-2 pb-2">
              <div className="inline-flex items-center justify-center w-14 h-14 rounded-xl mx-auto" style={{ background: 'color-mix(in srgb, var(--warning) 14%, transparent)', color: 'var(--warning)' }}>
                <Building2 size={26} />
              </div>
              <h2 className="text-xl font-bold">{t('setup_institution')}</h2>
              <p className="text-sm text-muted">{t('no_institution_linked_desc')}</p>
            </div>
            <div className="space-y-3">
              <button
                onClick={() => { setTab('create'); setError(null); }}
                className="w-full text-start rounded-xl p-4 border border-app hover:border-[var(--primary-600)] transition"
              >
                <div className="flex items-center gap-3">
                  <div className="w-10 h-10 rounded-lg flex items-center justify-center" style={{ background: 'color-mix(in srgb, var(--primary-600) 12%, transparent)', color: 'var(--primary-700)' }}>
                    <Plus size={20} />
                  </div>
                  <div>
                    <div className="font-semibold text-sm">{t('create_new_institution')}</div>
                    <div className="text-xs text-muted">{t('create_new_institution_desc')}</div>
                  </div>
                </div>
              </button>
              <button
                onClick={() => { setTab('join'); setError(null); }}
                className="w-full text-start rounded-xl p-4 border border-app hover:border-[var(--primary-600)] transition"
              >
                <div className="flex items-center gap-3">
                  <div className="w-10 h-10 rounded-lg flex items-center justify-center" style={{ background: 'color-mix(in srgb, var(--accent) 12%, transparent)', color: 'var(--accent)' }}>
                    <KeyRound size={20} />
                  </div>
                  <div>
                    <div className="font-semibold text-sm">{t('join_existing_institution')}</div>
                    <div className="text-xs text-muted">{t('join_existing_desc')}</div>
                  </div>
                </div>
              </button>
            </div>
          </>
        ) : tab === 'create' ? (
          <form onSubmit={doCreate} className="space-y-4">
            <div className="flex items-center gap-2">
              {backBtn()}
              <span className="font-semibold">{t('create_new_institution')}</span>
            </div>
            {error && (
              <div className="rounded-lg px-3 py-2 text-sm" style={{ background: 'color-mix(in srgb, var(--error) 12%, transparent)', color: 'var(--error)' }}>
                {error}
              </div>
            )}
            <div>
              <label className="label">{t('enter_institution_name')}</label>
              <input className="input" required value={instName} onChange={(e) => setInstName(e.target.value)} placeholder={t('institution_name')} />
            </div>
            <div>
              <label className="label">{t('full_name')}</label>
              <input className="input" value={fullName} onChange={(e) => setFullName(e.target.value)} placeholder={t('full_name')} />
            </div>
            <button disabled={busy} className="btn btn-primary w-full">
              {busy ? t('loading') : t('create')}
            </button>
          </form>
        ) : (
          <form onSubmit={doJoin} className="space-y-4">
            <div className="flex items-center gap-2">
              {backBtn()}
              <span className="font-semibold">{t('join_existing_institution')}</span>
            </div>
            {error && (
              <div className="rounded-lg px-3 py-2 text-sm" style={{ background: 'color-mix(in srgb, var(--error) 12%, transparent)', color: 'var(--error)' }}>
                {error}
              </div>
            )}
            <div>
              <label className="label">{t('full_name')}</label>
              <input className="input" value={fullName} onChange={(e) => setFullName(e.target.value)} placeholder={t('full_name')} />
            </div>
            <div>
              <label className="label">{t('enter_joining_code')}</label>
              <input className="input" required value={joiningCode} onChange={(e) => setJoiningCode(e.target.value)} placeholder={t('joining_code_help')} />
            </div>
            {institutions.length > 0 && (
              <div className="surface-2 rounded-lg p-3 space-y-1">
                <div className="text-xs font-medium text-muted flex items-center gap-1">
                  <Search size={12} />{t('available_institutions')}
                </div>
                {institutions.map((inst) => (
                  <div key={inst.id} className="text-sm py-0.5">{inst.name}</div>
                ))}
              </div>
            )}
            {institutions.length === 0 && (
              <p className="text-xs text-muted">{t('no_other_institutions')}</p>
            )}
            <button disabled={busy} className="btn btn-primary w-full">
              {busy ? t('loading') : t('create')}
            </button>
          </form>
        )}
        {!success && (
          <div className="border-t border-app pt-3">
            <button onClick={() => signOut()} className="btn btn-ghost w-full text-sm">
              <LogOut size={16} />{t('sign_out')}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

function Shell() {
  const { t } = useI18n();
  const { session, profile, institution, joinRequestInfo, loading, initError, signOut } = useAuth();
  const [page, setPage] = useState<PageKey>('home');

  if (loading) {
    return (
      <div className="min-h-screen flex flex-col items-center justify-center" style={{ background: 'var(--bg)' }}>
        <Spinner label={t('loading')} />
        <button onClick={() => signOut()} className="btn btn-ghost mt-4 text-xs">
          {t('sign_out')}
        </button>
      </div>
    );
  }

  if (initError) {
    return <ErrorScreen />;
  }

  if (!session) return <Login />;

  if (session && (!profile?.institution_id || !institution)) {
    if (joinRequestInfo) {
      return <PendingScreen />;
    }
    return <SetupInstitutionScreen />;
  }

  const pages: Record<PageKey, React.ReactNode> = {
    home: <Dashboard setPage={setPage} />,
    classes: <Classes />,
    students: <Students />,
    timetables: <Timetables />,
    timetable_search: <TimetableSearch />,
    unassigned_classes: <UnassignedClasses />,
    teacher_search: <TeacherSearch />,
    teacher_assignments: <TeacherAssignments />,
    attendance: <Attendance />,
    teacher_absence: <TeacherAbsencePage />,
    daily_reports: <DailyReports />,
    monthly_reports: <MonthlyReports />,
    student_stats: <StudentStats />,
    absence_followup: <AbsenceFollowup />,
    supervisors: <Supervisors />,
    institution_settings: <InstitutionSettingsPage />,
    database_settings: <DatabaseSettings />,
    backup: <BackupRestore />,
    developer_info: <DeveloperInfoPage />,
    settings: <SettingsPage />,
  };

  return (
    <Layout page={page} setPage={setPage}>
      {pages[page]}
    </Layout>
  );
}

export default function App() {
  return (
    <I18nProvider>
      <AuthProvider>
        <Shell />
      </AuthProvider>
    </I18nProvider>
  );
}
