import { createContext, useContext, useEffect, useState, useCallback, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase';
import type { Profile, Institution, ClassAssignment } from './types';
import { preloadInstitutionData, syncPending } from './sync';
import { localGetAll } from './offline-db';

interface JoinRequestInfo {
  status: 'pending' | 'accepted' | 'rejected';
  institutionName: string;
  createdAt: string;
}

interface AuthContextValue {
  session: Session | null;
  profile: Profile | null;
  institution: Institution | null;
  loading: boolean;
  initError: boolean;
  joinRequestInfo: JoinRequestInfo | null;
  assignedClassIds: Set<string>;
  retryInit: () => void;
  signIn: (email: string, password: string) => Promise<{ error: string | null }>;
  signUpAdmin: (email: string, password: string, fullName: string, institutionName: string) => Promise<{ error: string | null }>;
  registerSupervisor: (email: string, password: string, fullName: string, joiningCode: string) => Promise<{ error: string | null }>;
  createInstitution: (name: string, fullName: string) => Promise<{ error: string | null }>;
  signOut: () => Promise<void>;
  refreshProfile: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | null>(null);

const TIMEOUT_MS = 15000;

function withTimeout<T>(promise: Promise<T>, ms = TIMEOUT_MS): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error('timeout')), ms)
    ),
  ]);
}

function errToString(e: unknown): string {
  if (e instanceof Error) return e.message === 'timeout' ? 'timeout' : e.message;
  if (typeof e === 'string') return e;
  if (e && typeof e === 'object' && 'message' in e && typeof (e as { message: unknown }).message === 'string')
    return (e as { message: string }).message;
  try { return JSON.stringify(e); } catch { return String(e); }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [institution, setInstitution] = useState<Institution | null>(null);
  const [loading, setLoading] = useState(true);
  const [initError, setInitError] = useState(false);
  const [joinRequestInfo, setJoinRequestInfo] = useState<JoinRequestInfo | null>(null);
  const [assignedClassIds, setAssignedClassIds] = useState<Set<string>>(new Set());

  const loadProfile = useCallback(async (uid: string) => {
    const { data: prof, error: profErr } = await supabase
      .from('profiles')
      .select('*')
      .eq('user_id', uid)
      .maybeSingle();

    if (profErr) throw profErr;

    setProfile(prof as Profile | null);

    if (!prof?.institution_id) {
      setInstitution(null);
      try {
        const { data: jrInfo } = await supabase.rpc('get_own_join_request_status');
        if (jrInfo && Array.isArray(jrInfo) && jrInfo.length > 0) {
          const row = jrInfo[0] as { status: string; institution_name: string; created_at: string };
          setJoinRequestInfo({
            status: row.status as 'pending' | 'accepted' | 'rejected',
            institutionName: row.institution_name,
            createdAt: row.created_at,
          });
        } else {
          setJoinRequestInfo(null);
        }
      } catch {
        setJoinRequestInfo(null);
      }
    } else {
      setJoinRequestInfo(null);
      const { data: inst, error: instErr } = await supabase
        .from('institutions')
        .select('*')
        .eq('id', prof.institution_id)
        .maybeSingle();
      if (instErr) throw instErr;
      setInstitution(inst as Institution | null);
      if (prof.institution_id) {
        preloadInstitutionData(prof.institution_id).then(() => syncPending()).catch(() => {});
      }
      if (prof.role === 'supervisor') {
        try {
          const { data: ca } = await supabase.from('class_assignments').select('class_id').eq('profile_id', uid);
          setAssignedClassIds(new Set((ca ?? []).map((r: { class_id: string }) => r.class_id)));
        } catch {
          const local = await localGetAll<ClassAssignment>('class_assignments');
          setAssignedClassIds(new Set(local.filter((a) => a.profile_id === uid).map((a) => a.class_id)));
        }
      } else {
        setAssignedClassIds(new Set());
      }
    }
  }, []);

  const init = useCallback(async () => {
    setLoading(true);
    setInitError(false);
    try {
      const { data, error } = await withTimeout(supabase.auth.getSession());
      if (error) throw error;
      setSession(data.session);
      if (data.session) {
        await withTimeout(loadProfile(data.session.user.id));
      }
    } catch {
      setInitError(true);
    } finally {
      setLoading(false);
    }
  }, [loadProfile]);

  useEffect(() => {
    init();

    const { data: sub } = supabase.auth.onAuthStateChange((_event, sess) => {
      setSession(sess);
      if (sess) {
        (async () => {
          try {
            await withTimeout(loadProfile(sess.user.id));
          } catch {
            // Profile load failed — Shell will show setup or error screen as fallback
          } finally {
            setLoading(false);
          }
        })();
      } else {
        setProfile(null);
        setInstitution(null);
        setJoinRequestInfo(null);
        setAssignedClassIds(new Set());
        setLoading(false);
      }
    });

    return () => sub.subscription.unsubscribe();
  }, [init, loadProfile]);

  const retryInit = useCallback(() => {
    init();
  }, [init]);

  const signIn = async (email: string, password: string) => {
    try {
      const { error } = await withTimeout(
        supabase.auth.signInWithPassword({ email, password })
      );
      if (error) return { error: error.message };
      return { error: null };
    } catch (e) {
      return { error: errToString(e) };
    }
  };

  const signUpAdmin = async (email: string, password: string, fullName: string, institutionName: string) => {
    try {
      const { data, error } = await withTimeout(
        supabase.auth.signUp({ email, password })
      );
      if (error) return { error: error.message };
      if (!data.user) return { error: 'signup_failed' };

      const { error: instErr } = await supabase
        .from('institutions')
        .insert({ name: institutionName });
      if (instErr) return { error: instErr.message };

      const { data: rpcResult, error: rpcErr } = await supabase.rpc('complete_admin_signup', {
        p_institution_name: institutionName,
        p_full_name: fullName,
      });
      if (rpcErr) return { error: rpcErr.message };
      const result = rpcResult as { error?: string; success?: boolean } | null;
      if (result?.error) return { error: result.error };

      await loadProfile(data.user.id);
      return { error: null };
    } catch (e) {
      return { error: errToString(e) };
    }
  };

  const registerSupervisor = async (email: string, password: string, fullName: string, joiningCode: string) => {
    try {
      // If the user is already logged in (e.g. from SetupInstitutionScreen),
      // skip auth and go straight to submitting the join request.
      const { data: sessData } = await supabase.auth.getSession();
      if (sessData.session) {
        const currentUser = sessData.session.user;
        const userEmail = currentUser.email ?? email;
        // Update profile full_name if provided
        if (fullName.trim()) {
          await supabase.from('profiles').update({ full_name: fullName.trim(), email: userEmail }).eq('user_id', currentUser.id);
        }
        // Check for existing join request
        const { data: jrInfo } = await supabase.rpc('get_own_join_request_status');
        if (jrInfo && Array.isArray(jrInfo) && jrInfo.length > 0) {
          const status = (jrInfo[0] as { status: string }).status;
          if (status === 'pending') return { error: 'duplicate_pending_request' };
          if (status === 'accepted') return { error: 'already_member' };
        }
        const { data: rpcResult, error: rpcErr } = await supabase.rpc('submit_join_request', {
          p_institution_code: joiningCode,
          p_email: userEmail,
          p_full_name: fullName,
        });
        if (rpcErr) return { error: rpcErr.message };
        // The RPC returns a JSON object — check for application-level errors
        const result = rpcResult as { error?: string; success?: boolean } | null;
        if (result?.error) return { error: result.error };
        return { error: null };
      }

      // Not logged in — try signing in first (existing account)
      if (password) {
        const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
        if (!signInError) {
          const { data: jrInfo } = await supabase.rpc('get_own_join_request_status');
          if (jrInfo && Array.isArray(jrInfo) && jrInfo.length > 0) {
            const status = (jrInfo[0] as { status: string }).status;
            if (status === 'pending') return { error: 'duplicate_pending_request' };
            if (status === 'accepted') return { error: 'already_member' };
          }
          const { data: rpcResult, error: rpcErr } = await supabase.rpc('submit_join_request', {
            p_institution_code: joiningCode,
            p_email: email,
            p_full_name: fullName,
          });
          if (rpcErr) return { error: rpcErr.message };
          const result1 = rpcResult as { error?: string; success?: boolean } | null;
          if (result1?.error) return { error: result1.error };
          return { error: null };
        }
      }

      // Sign up a new account
      const { data, error } = await supabase.auth.signUp({ email, password });
      if (error) {
        if (error.message.includes('already registered') || error.message.includes('already been registered')) {
          return { error: 'email_exists_signin' };
        }
        return { error: error.message };
      }
      if (!data.user) return { error: 'No user returned' };

      await supabase.from('profiles').update({ full_name: fullName, email }).eq('user_id', data.user.id);

      const { data: rpcResult2, error: rpcErr2 } = await supabase.rpc('submit_join_request', {
        p_institution_code: joiningCode,
        p_email: email,
        p_full_name: fullName,
      });
      if (rpcErr2) return { error: rpcErr2.message };
      const result2 = rpcResult2 as { error?: string; success?: boolean } | null;
      if (result2?.error) return { error: result2.error };

      await loadProfile(data.user.id);
      return { error: null };
    } catch (e) {
      return { error: errToString(e) };
    }
  };

  const createInstitution = async (name: string, fullName: string) => {
    try {
      const { error: rpcErr } = await supabase.rpc('create_own_institution', {
        p_name: name,
        p_full_name: fullName,
      });
      if (rpcErr) return { error: rpcErr.message };

      if (session) {
        await loadProfile(session.user.id);
      }
      return { error: null };
    } catch (e) {
      return { error: errToString(e) };
    }
  };

  const signOut = async () => {
    await supabase.auth.signOut();
    setProfile(null);
    setInstitution(null);
    setSession(null);
    setJoinRequestInfo(null);
    setAssignedClassIds(new Set());
    setInitError(false);
  };

  const refreshProfile = async () => {
    if (session) await loadProfile(session.user.id);
  };

  return (
    <AuthContext.Provider value={{ session, profile, institution, loading, initError, joinRequestInfo, assignedClassIds, retryInit, signIn, signUpAdmin, registerSupervisor, createInstitution, signOut, refreshProfile }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
