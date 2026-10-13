/**
 * منظومة تقييم واختبارات اللغة العربية - Arabic Assessment & Exam Module
 * Configuration Module - Supabase & Edge Functions Endpoints
 */

const getEnv = (key, fallback = '') => {
  if (typeof window !== 'undefined') {
    if (window.__ENV__ && window.__ENV__[key]) return window.__ENV__[key];
  }
  return fallback;
};

export const CONFIG = {
  // Supabase Core Configuration
  SUPABASE_URL: getEnv('SUPABASE_URL', 'https://your-project.supabase.co'),
  SUPABASE_ANON_KEY: getEnv('SUPABASE_ANON_KEY', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.example-anon-key'),

  // Default Tenant Fallback for display before profile loads
  DEFAULT_TENANT_ID: 'tenant_default',

  // Storage Bucket
  STORAGE_BUCKET_RECORDINGS: 'student-recordings',

  // Edge Functions Canonical Endpoints
  ENDPOINTS: {
    START_EXAM_ATTEMPT: '/functions/v1/start-exam-attempt',
    SAVE_EXAM_ANSWER: '/functions/v1/save-exam-answer',
    SUBMIT_AND_GRADE_EXAM_ATTEMPT: '/functions/v1/submit-and-grade-exam-attempt',
    GET_STUDENT_OFFICIAL_RESULT: '/functions/v1/get-student-official-result',
    SUBMIT_TEACHER_REVIEW: '/functions/v1/submit-teacher-review',
    RESPOND_TO_STUDENT_INQUIRY: '/functions/v1/respond-to-student-inquiry',
    GENERATE_PEDAGOGICAL_ANALYSIS: '/functions/v1/generate-pedagogical-analysis',
  },

  // Helper to build full Edge Function URL
  getFunctionUrl(endpointName) {
    const relativePath = this.ENDPOINTS[endpointName];
    if (!relativePath) {
      throw new Error(`Unknown function endpoint: ${endpointName}`);
    }
    const baseUrl = this.SUPABASE_URL.replace(/\/$/, '');
    return `${baseUrl}${relativePath}`;
  },

  // Check if live Supabase is configured
  isLiveConfigured() {
    return (
      Boolean(this.SUPABASE_URL) &&
      this.SUPABASE_URL !== 'https://your-project.supabase.co' &&
      Boolean(this.SUPABASE_ANON_KEY) &&
      this.SUPABASE_ANON_KEY !== 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.example-anon-key'
    );
  },
};
