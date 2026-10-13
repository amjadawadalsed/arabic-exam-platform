/**
 * منظومة تقييم واختبارات اللغة العربية - Arabic Assessment & Exam Module
 * API Layer Service - Edge Functions & Supabase Database RPC / RLS Operations
 * Strict Anti-Tampering, Zero Mock Fallbacks, Truthful Error Reporting
 */

import { CONFIG } from '../config.js';
import { getSupabase, getAccessToken, getCurrentProfile } from './auth.js';

/**
 * Generic caller for Supabase Edge Functions with Bearer JWT
 */
async function callEdgeFunction(endpointKey, payload = {}) {
  const token = await getAccessToken();

  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد. يرجى ضبط المتغيرات للاتصال بالنظام الفعلي.');
  }

  if (!token) {
    throw new Error('جلسة الدخول غير صالحة أو منتهية. يرجى تسجيل الدخول مرة أخرى.');
  }

  const url = CONFIG.getFunctionUrl(endpointKey);
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
  });

  const responseData = await response.json().catch(() => ({}));
  if (!response.ok) {
    const errorMsg = responseData.message || responseData.error || `فشل استدعاء الخدمة (رمز: ${response.status})`;
    const err = new Error(errorMsg);
    err.status = response.status;
    err.code = responseData.error;
    err.data = responseData;
    throw err;
  }

  return responseData;
}

// ==========================================================================
// 1. Edge Function Calls
// ==========================================================================

/**
 * Start or resume exam attempt (Edge Function: start-exam-attempt -> RPC #1)
 * @param {string} examId - UUID
 */
export async function startExamAttempt(examId) {
  if (!examId) throw new Error('معرف الاختبار مطلوب لبدء المحاولة.');
  return await callEdgeFunction('START_EXAM_ATTEMPT', { exam_id: examId });
}

/**
 * Save candidate answer during active attempt (Edge Function: save-exam-answer -> RPC #2)
 * @param {Object} params
 * @param {string} params.attemptId - UUID
 * @param {string} params.attemptItemId - UUID
 * @param {string|null} [params.selectedOptionKey] - e.g. "A", "B", "C"
 * @param {string|null} [params.textResponse] - string
 * @param {string|null} [params.audioStoragePath] - string
 * @param {number|null} [params.audioDurationSeconds] - number > 0
 */
export async function saveExamAnswer({
  attemptId,
  attemptItemId,
  selectedOptionKey = null,
  textResponse = null,
  audioStoragePath = null,
  audioDurationSeconds = null,
}) {
  if (!attemptId || !attemptItemId) {
    throw new Error('معرف المحاولة ومعرف السؤال مطلوبان لحفظ الإجابة.');
  }

  const payload = {
    attempt_id: attemptId,
    attempt_item_id: attemptItemId,
  };

  if (selectedOptionKey !== null && selectedOptionKey !== undefined) {
    payload.selected_option_key = selectedOptionKey;
  }
  if (textResponse !== null && textResponse !== undefined) {
    payload.text_response = textResponse;
  }
  if (audioStoragePath !== null && audioStoragePath !== undefined) {
    payload.audio_storage_path = audioStoragePath;
  }
  if (
    audioDurationSeconds !== null &&
    audioDurationSeconds !== undefined &&
    typeof audioDurationSeconds === 'number' &&
    Number.isFinite(audioDurationSeconds)
  ) {
    payload.audio_duration_seconds = audioDurationSeconds;
  }

  return await callEdgeFunction('SAVE_EXAM_ANSWER', payload);
}

/**
 * Submit and auto-grade exam attempt (Edge Function: submit-and-grade-exam-attempt -> RPC #3)
 * @param {string} attemptId - UUID
 */
export async function submitAndGradeExamAttempt(attemptId) {
  if (!attemptId) throw new Error('معرف المحاولة مطلوب لإرسال الاختبار.');
  return await callEdgeFunction('SUBMIT_AND_GRADE_EXAM_ATTEMPT', { attempt_id: attemptId });
}

/**
 * Fetch official finalized result (Edge Function: get-student-official-result)
 * @param {string} attemptId - UUID
 */
export async function getStudentOfficialResult(attemptId) {
  if (!attemptId) throw new Error('معرف المحاولة مطلوب لعرض النتيجة الرسمية.');
  return await callEdgeFunction('GET_STUDENT_OFFICIAL_RESULT', { attempt_id: attemptId });
}

/**
 * Submit teacher manual grading and review (Edge Function: submit-teacher-review)
 * @param {Object} params
 * @param {string} params.attemptItemId - UUID
 * @param {number} params.assignedScore - number >= 0
 * @param {string|null} [params.feedbackText] - optional feedback
 * @param {boolean} [params.isFinalized] - default true
 */
export async function submitTeacherReview({
  attemptItemId,
  assignedScore,
  feedbackText = null,
  isFinalized = true,
}) {
  if (!attemptItemId) throw new Error('معرف السؤال مطلوب لتقييم المصحح.');
  if (assignedScore === undefined || assignedScore === null || assignedScore < 0) {
    throw new Error('الدرجة الممنوحة يجب أن تكون قيمة رقمية غير سالبة.');
  }

  const payload = {
    attempt_item_id: attemptItemId,
    assigned_score: assignedScore,
    is_finalized: Boolean(isFinalized),
  };

  if (feedbackText) {
    payload.feedback_text = feedbackText;
  }

  return await callEdgeFunction('SUBMIT_TEACHER_REVIEW', payload);
}

/**
 * Teacher response to student inquiry (Edge Function: respond-to-student-inquiry)
 * @param {string} inquiryId - UUID
 * @param {string} teacherResponse - response text
 */
export async function respondToStudentInquiry(inquiryId, teacherResponse) {
  if (!inquiryId || !teacherResponse || !teacherResponse.trim()) {
    throw new Error('نص الرد ومعرف الاستفسار مطلوبان.');
  }

  return await callEdgeFunction('RESPOND_TO_STUDENT_INQUIRY', {
    inquiry_id: inquiryId,
    teacher_response: teacherResponse.trim(),
  });
}

/**
 * Request pedagogical analysis from Gemini (Edge Function: generate-pedagogical-analysis)
 * @param {string} attemptId - UUID
 */
export async function generatePedagogicalAnalysis(attemptId) {
  if (!attemptId) throw new Error('معرف المحاولة مطلوب لتوليد التحليل التربوي الذكي.');
  return await callEdgeFunction('GENERATE_PEDAGOGICAL_ANALYSIS', { attempt_id: attemptId });
}

// ==========================================================================
// 2. Database Queries via Supabase Client (RLS Protected, No Mock Fallbacks)
// ==========================================================================

/**
 * Fetch candidate attempts for authenticated student.
 * Note: Under the locked security model, students cannot directly join public.exams.
 * Therefore, safe attempt fields are retrieved directly from public.exam_attempts.
 */
export async function fetchStudentAttempts() {
  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const { data, error } = await supabase
    .from('exam_attempts')
    .select(`
      id,
      exam_id,
      attempt_number,
      status,
      started_at,
      expires_at,
      completed_at,
      total_score,
      percentage_score,
      is_passed,
      final_scoring_status,
      placement_status
    `)
    .order('started_at', { ascending: false });

  if (error) {
    console.error('Error fetching student attempts:', error);
    throw new Error('فشل جلب سجل محاولات الاختبارات من الخادم.');
  }

  return data || [];
}

/**
 * Fetch frozen attempt items for the authenticated student's attempt.
 * Under RLS, only the student's own attempt items are returned.
 * Exposes only safe frozen fields without question bank or answer keys.
 */
export async function fetchAttemptItems(attemptId) {
  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const { data, error } = await supabase
    .from('attempt_items')
    .select(`
      id,
      attempt_id,
      question_id,
      skill_id,
      item_type,
      allocated_score,
      frozen_question_text,
      frozen_options,
      review_status,
      awarded_score,
      is_correct,
      sort_order
    `)
    .eq('attempt_id', attemptId)
    .order('sort_order', { ascending: true });

  if (error) {
    console.error('Error fetching attempt items:', error);
    throw new Error('فشل جلب أسئلة المحاولة من الخادم.');
  }

  return data || [];
}

/**
 * Fetch existing answers previously saved for an attempt's items.
 */
export async function fetchAttemptAnswers(itemIds = []) {
  if (!itemIds || itemIds.length === 0) return [];
  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const { data, error } = await supabase
    .from('attempt_answers')
    .select('attempt_item_id, selected_option_key, text_response, audio_storage_path, audio_duration_seconds')
    .in('attempt_item_id', itemIds);

  if (error) {
    console.error('Error fetching existing answers:', error);
    return [];
  }

  return data || [];
}

/**
 * Upload student speaking recording to 'student-recordings' storage bucket.
 * The path is constructed strictly on the client according to backend rule:
 * {external_tenant_id}/{student_id}/{attempt_id}/{attempt_item_id}.webm
 */
export async function uploadSpeakingRecording({ externalTenantId, studentId, attemptId, attemptItemId, audioBlob }) {
  if (!externalTenantId || !studentId || !attemptId || !attemptItemId || !audioBlob) {
    throw new Error('بيانات التسجيل الصوتي أو معرّفات المسار غير مكتملة.');
  }

  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const storagePath = `${externalTenantId}/${studentId}/${attemptId}/${attemptItemId}.webm`;

  const { data, error } = await supabase.storage
    .from('student-recordings')
    .upload(storagePath, audioBlob, {
      contentType: 'audio/webm',
      upsert: true,
    });

  if (error) {
    console.error('Storage upload error for speaking recording:', error);
    throw new Error(`فشل رفع التسجيل الصوتي إلى التخزين السحابي: ${error.message}`);
  }

  return storagePath;
}

/**
 * Fetch a single exam attempt for the authenticated student.
 */
export async function fetchAttemptById(attemptId) {
  if (!attemptId) return null;
  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const { data, error } = await supabase
    .from('exam_attempts')
    .select(`
      id,
      exam_id,
      student_id,
      status,
      attempt_number,
      started_at,
      expires_at,
      completed_at,
      total_score,
      percentage_score,
      is_passed,
      final_scoring_status,
      placement_status
    `)
    .eq('id', attemptId)
    .maybeSingle();

  if (error) {
    console.error('Error fetching attempt by id:', error);
    return null;
  }

  return data;
}

/**
 * Fetch student inquiries for authenticated student
 */
export async function fetchStudentInquiries() {
  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const { data, error } = await supabase
    .from('student_teacher_inquiries')
    .select('id, attempt_id, attempt_item_id, subject, student_message, teacher_response, status, created_at, updated_at')
    .order('created_at', { ascending: false });

  if (error) {
    console.error('Error fetching student inquiries:', error);
    throw new Error('فشل جلب قائمة استفسارات الطالب.');
  }

  return data || [];
}

/**
 * Create a new inquiry from student to teacher
 */
export async function createStudentInquiry({ attemptId, attemptItemId = null, subject, studentMessage }) {
  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  if (!attemptId || !subject || !studentMessage) {
    throw new Error('جميع حقول الاستفسار الأساسية مطلوبة.');
  }

  const profile = await getCurrentProfile();
  if (!profile) {
    throw new Error('تعذر التحقق من هوية الطالب.');
  }

  const insertPayload = {
    attempt_id: attemptId,
    student_id: profile.id,
    external_tenant_id: profile.external_tenant_id,
    subject: subject.trim(),
    student_message: studentMessage.trim(),
    status: 'open',
  };

  if (attemptItemId) {
    insertPayload.attempt_item_id = attemptItemId;
  }

  const { data, error } = await supabase
    .from('student_teacher_inquiries')
    .insert(insertPayload)
    .select()
    .single();

  if (error) {
    console.error('Error creating inquiry:', error);
    throw new Error(`فشل إرسال الاستفسار: ${error.message}`);
  }

  return data;
}

/**
 * Fetch pending attempts requiring teacher review (Teacher / Admin only)
 * Filtered by: status = 'completed' AND final_scoring_status = 'provisional'
 * Prevents in_progress attempts from appearing in the grading queue.
 */
export async function fetchTeacherPendingAttempts() {
  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const profile = await getCurrentProfile();
  if (!profile || !profile.external_tenant_id) {
    throw new Error('الملف الشخصي للمعلم غير مكتمل أو غير مرتبط بنطاق تعليمي.');
  }

  // 1. Fetch completed provisional attempts within the teacher's tenant
  const { data: attempts, error } = await supabase
    .from('exam_attempts')
    .select(`
      id,
      exam_id,
      student_id,
      attempt_number,
      status,
      started_at,
      completed_at,
      total_score,
      percentage_score,
      final_scoring_status,
      external_tenant_id
    `)
    .eq('external_tenant_id', profile.external_tenant_id)
    .eq('status', 'completed')
    .eq('final_scoring_status', 'provisional')
    .order('completed_at', { ascending: false });

  if (error) {
    console.error('Error fetching teacher pending attempts:', error);
    throw new Error('فشل جلب قائمة المحاولات المعلقة للتصحيح.');
  }

  if (!attempts || attempts.length === 0) return [];

  // 2. Safely enrich metadata (student profile names and exam titles)
  const studentIds = [...new Set(attempts.map(a => a.student_id).filter(Boolean))];
  const examIds = [...new Set(attempts.map(a => a.exam_id).filter(Boolean))];
  const attemptIds = attempts.map(a => a.id);

  const profilesMap = {};
  if (studentIds.length > 0) {
    try {
      const { data: profiles } = await supabase
        .from('profiles')
        .select('id, full_name, email')
        .in('id', studentIds);
      (profiles || []).forEach(p => { profilesMap[p.id] = p; });
    } catch (e) {
      console.warn('Could not enrich student profiles:', e);
    }
  }

  const examsMap = {};
  if (examIds.length > 0) {
    try {
      const { data: exams } = await supabase
        .from('exams')
        .select('id, title, exam_type')
        .in('id', examIds);
      (exams || []).forEach(e => { examsMap[e.id] = e; });
    } catch (e) {
      console.warn('Could not enrich exam titles:', e);
    }
  }

  // 3. Count pending reviewable items (writing/speaking)
  const pendingCountMap = {};
  if (attemptIds.length > 0) {
    try {
      const { data: items } = await supabase
        .from('attempt_items')
        .select('id, attempt_id, item_type, review_status')
        .in('attempt_id', attemptIds)
        .in('item_type', ['writing', 'speaking']);

      (items || []).forEach(it => {
        if (!pendingCountMap[it.attempt_id]) {
          pendingCountMap[it.attempt_id] = { total: 0, pending: 0 };
        }
        pendingCountMap[it.attempt_id].total++;
        if (it.review_status === 'pending_teacher_review') {
          pendingCountMap[it.attempt_id].pending++;
        }
      });
    } catch (e) {
      console.warn('Could not calculate pending review item counts:', e);
    }
  }

  return attempts.map(att => ({
    ...att,
    student: profilesMap[att.student_id] || { full_name: `طالب (${att.student_id.substring(0, 8)})` },
    exam: examsMap[att.exam_id] || { title: `اختبار (${att.exam_id.substring(0, 8)})` },
    pendingReviewsCount: pendingCountMap[att.id]?.pending ?? 0,
    totalReviewableCount: pendingCountMap[att.id]?.total ?? 0,
  }));
}

/**
 * Fetch full attempt review details for authorized teacher.
 * Validates UUID, enforces tenant check, and loads attempt items, student answers, and teacher reviews.
 * @param {string} attemptId - UUID
 */
export async function fetchAttemptForTeacherReview(attemptId) {
  if (!attemptId || typeof attemptId !== 'string') {
    throw new Error('معرف المحاولة مطلوب.');
  }

  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const profile = await getCurrentProfile();
  if (!profile || (profile.role !== 'teacher' && profile.role !== 'admin')) {
    throw new Error('غير مصرح لك بالوصول: يتطلب هذا الإجراء صلاحيات المعلم أو المشرف.');
  }

  // 1. Fetch Attempt
  const { data: attempt, error: attError } = await supabase
    .from('exam_attempts')
    .select(`
      id,
      exam_id,
      student_id,
      external_tenant_id,
      status,
      attempt_number,
      started_at,
      completed_at,
      total_score,
      percentage_score,
      is_passed,
      placement_status,
      final_scoring_status
    `)
    .eq('id', attemptId)
    .single();

  if (attError || !attempt) {
    console.error('Error fetching attempt for review:', attError);
    throw new Error('المحاولة غير موجودة أو غير مصرح لك بمراجعتها.');
  }

  // Tenant check
  if (attempt.external_tenant_id !== profile.external_tenant_id) {
    throw new Error('غير مصرح بالوصول إلى محاولات مؤسسة تعليمية أخرى (Tenant Mismatch).');
  }

  // 2. Fetch Student Profile & Exam Info
  let student = { full_name: `طالب (${attempt.student_id.substring(0, 8)})`, email: '' };
  try {
    const { data: studentProf } = await supabase
      .from('profiles')
      .select('id, full_name, email')
      .eq('id', attempt.student_id)
      .maybeSingle();
    if (studentProf) student = studentProf;
  } catch (e) {
    console.warn('Student profile query note:', e);
  }

  let exam = { title: `اختبار (${attempt.exam_id.substring(0, 8)})` };
  try {
    const { data: examData } = await supabase
      .from('exams')
      .select('id, title, exam_type')
      .eq('id', attempt.exam_id)
      .maybeSingle();
    if (examData) exam = examData;
  } catch (e) {
    console.warn('Exam query note:', e);
  }

  // 3. Fetch Attempt Items
  const { data: items, error: itemsError } = await supabase
    .from('attempt_items')
    .select(`
      id,
      attempt_id,
      question_id,
      skill_id,
      item_type,
      allocated_score,
      awarded_score,
      is_correct,
      frozen_question_text,
      frozen_options,
      review_status,
      sort_order
    `)
    .eq('attempt_id', attemptId)
    .order('sort_order', { ascending: true });

  if (itemsError) {
    console.error('Error fetching attempt items:', itemsError);
    throw new Error('فشل جلب عناصر المحاولة.');
  }

  const attemptItems = items || [];
  const itemIds = attemptItems.map(i => i.id);

  // 4. Fetch Student Answers for Items
  const answersMap = {};
  if (itemIds.length > 0) {
    const { data: answers } = await supabase
      .from('attempt_answers')
      .select('attempt_item_id, selected_option_key, text_response, audio_storage_path, audio_duration_seconds')
      .in('attempt_item_id', itemIds);

    (answers || []).forEach(ans => {
      answersMap[ans.attempt_item_id] = ans;
    });
  }

  // 5. Fetch Existing Teacher Reviews for Items
  const reviewsMap = {};
  if (itemIds.length > 0) {
    const { data: reviews } = await supabase
      .from('teacher_reviews')
      .select('id, attempt_item_id, teacher_id, assigned_score, feedback_text, is_finalized, finalized_at, updated_at')
      .in('attempt_item_id', itemIds);

    (reviews || []).forEach(rev => {
      reviewsMap[rev.attempt_item_id] = rev;
    });
  }

  return {
    attempt,
    student,
    exam,
    items: attemptItems,
    answersMap,
    reviewsMap,
  };
}

/**
 * Fetch open inquiries for teacher review (Teacher / Admin only)
 */
export async function fetchTeacherInquiries() {
  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const profile = await getCurrentProfile();
  if (!profile || !profile.external_tenant_id) {
    throw new Error('الملف الشخصي للمعلم غير مكتمل.');
  }

  const { data, error } = await supabase
    .from('student_teacher_inquiries')
    .select(`
      id,
      attempt_id,
      attempt_item_id,
      student_id,
      subject,
      student_message,
      teacher_response,
      status,
      created_at,
      profiles:student_id (
        full_name,
        email
      )
    `)
    .eq('external_tenant_id', profile.external_tenant_id)
    .order('created_at', { ascending: false });

  if (error) {
    console.error('Error fetching teacher inquiries:', error);
    throw new Error('فشل جلب قائمة استفسارات الطلاب.');
  }

  return data || [];
}

/**
 * Fetch tenant exams for Teacher overview
 * Uses approved status enum ('approved') under teacher RLS.
 */
export async function fetchTeacherTenantExams() {
  const supabase = await getSupabase();
  if (!CONFIG.isLiveConfigured()) {
    throw new Error('خدمة Supabase غير مهيأة بعد.');
  }

  const profile = await getCurrentProfile();
  if (!profile || !profile.external_tenant_id) {
    throw new Error('الملف الشخصي للمعلم غير مكتمل.');
  }

  const { data, error } = await supabase
    .from('exams')
    .select('id, title, exam_type, duration_minutes, passing_score_percentage, scoring_policy, external_tenant_id, status')
    .eq('status', 'approved')
    .eq('external_tenant_id', profile.external_tenant_id)
    .order('created_at', { ascending: false });

  if (error) {
    console.error('Error fetching teacher tenant exams:', error);
    throw new Error('فشل جلب قائمة اختبارات المؤسسة.');
  }

  return data || [];
}
