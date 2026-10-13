/**
 * منظومة تقييم واختبارات اللغة العربية - Arabic Assessment & Exam Module
 * Authentication Service - Supabase Auth, Profiles, Session & Route Guards
 * Server-Authoritative Identity: Zero Fake JWTs, Zero Mock Bypass
 */

import { CONFIG } from '../config.js';
import { toast } from '../components/toast.js';

let supabaseClient = null;

/**
 * Initialize or get Supabase Client singleton.
 */
export async function getSupabase() {
  if (supabaseClient) return supabaseClient;

  let createClientFn = null;
  if (typeof window !== 'undefined' && window.supabase && typeof window.supabase.createClient === 'function') {
    createClientFn = window.supabase.createClient;
  } else {
    try {
      const module = await import('https://esm.sh/@supabase/supabase-js@2');
      createClientFn = module.createClient;
    } catch (err) {
      console.error('Failed to load Supabase SDK from ESM CDN:', err);
      if (window.supabase && typeof window.supabase.createClient === 'function') {
        createClientFn = window.supabase.createClient;
      }
    }
  }

  if (!createClientFn) {
    throw new Error('تعذر تحميل مكتبة Supabase JavaScript SDK.');
  }

  supabaseClient = createClientFn(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      storageKey: 'arabic_exam_auth_token',
    },
  });

  return supabaseClient;
}

/**
 * Sign In with Email & Password via Supabase Auth
 */
export async function login(email, password) {
  const cleanEmail = email.trim();
  const supabase = await getSupabase();

  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد ببيانات الاتصال الفعلية. يرجى ضبط المتغيرات.');
  }

  const { data, error } = await supabase.auth.signInWithPassword({
    email: cleanEmail,
    password,
  });

  if (error) {
    throw new Error(translateAuthError(error.message));
  }

  if (!data?.user) {
    throw new Error('فشل التحقق من بيانات الدخول.');
  }

  const profile = await getCurrentProfile(data.user.id);
  return { session: data.session, profile, user: data.user };
}

/**
 * Sign Out
 */
export async function logout() {
  const supabase = await getSupabase();
  if (supabase && CONFIG.isLiveConfigured()) {
    try {
      await supabase.auth.signOut();
    } catch (e) {
      console.warn('Signout note:', e);
    }
  }

  toast.info('تم تسجيل الخروج بنجاح.');
  setTimeout(() => {
    window.location.href = '/index.html';
  }, 400);
}

/**
 * Get active session from Supabase Auth
 */
export async function getSession() {
  const supabase = await getSupabase();
  if (!supabase || !CONFIG.isLiveConfigured()) return null;

  const { data, error } = await supabase.auth.getSession();
  if (error) {
    console.error('Error fetching auth session:', error);
    return null;
  }
  return data?.session || null;
}

/**
 * Get active JWT access token for Edge Functions
 */
export async function getAccessToken() {
  const session = await getSession();
  return session?.access_token || null;
}

/**
 * Get active user from Supabase Auth
 */
export async function getUser() {
  const supabase = await getSupabase();
  if (!supabase || !CONFIG.isLiveConfigured()) return null;

  const { data, error } = await supabase.auth.getUser();
  if (error) {
    console.error('Error fetching auth user:', error);
    return null;
  }
  return data?.user || null;
}

/**
 * Fetch profile for authenticated user (tenant-scoped)
 */
export async function getCurrentProfile(userId = null) {
  const supabase = await getSupabase();
  if (!supabase || !CONFIG.isLiveConfigured()) return null;

  let targetId = userId;
  if (!targetId) {
    const user = await getUser();
    targetId = user?.id;
  }

  if (!targetId) return null;

  const { data, error } = await supabase
    .from('profiles')
    .select('id, external_tenant_id, role, full_name, email, created_at')
    .eq('id', targetId)
    .maybeSingle();

  if (error) {
    console.error('Error fetching profile:', error);
    throw new Error('فشل جلب ملف المستخدم الشخصي من قاعدة البيانات.');
  }

  return data;
}

/**
 * Route Guard for Dashboards
 * Verifies authentication and role; redirects unauthenticated users or role mismatches.
 */
export async function requireAuth(allowedRoles = []) {
  const session = await getSession();
  if (!session) {
    const currentPath = window.location.pathname;
    window.location.href = `/index.html?redirect=${encodeURIComponent(currentPath)}`;
    return null;
  }

  const profile = await getCurrentProfile(session.user?.id);
  const role = profile?.role || 'student';

  if (allowedRoles.length > 0 && !allowedRoles.includes(role)) {
    if (role === 'student') {
      toast.warning('غير مصرح لك بالوصول إلى لوحة المعلم.');
      setTimeout(() => {
        window.location.href = '/student/dashboard.html';
      }, 600);
      return null;
    } else if (role === 'teacher' || role === 'admin') {
      window.location.href = '/teacher/dashboard.html';
      return null;
    }
  }

  return { session, profile, role, user: session.user };
}

/**
 * Arabic error translation helper
 */
function translateAuthError(message) {
  if (!message) return 'حدث خطأ في عملية المصادقة.';
  const lower = message.toLowerCase();
  if (lower.includes('invalid login credentials')) return 'بيانات الدخول غير صحيحة، يرجى التحقق من البريد الإلكتروني وكلمة المرور.';
  if (lower.includes('user already registered')) return 'المستخدم مسجل مسبقاً في النظام.';
  if (lower.includes('password should be at least')) return 'يجب ألا تقل كلمة المرور عن 6 أحرف.';
  if (lower.includes('email not confirmed')) return 'يرجى تأكيد البريد الإلكتروني أولاً.';
  if (lower.includes('rate limit')) return 'تم تجاوز الحد المسموح من المحاولات، يرجى الانتظار قليلاً.';
  return `خطأ في المصادقة: ${message}`;
}
