-- ============================================================================
-- PHASE 8B.2: Core Security + Row Level Security (RLS) Reconstruction
-- Standalone Arabic Exam & Assessment Module
-- Strict Multi-Tenant Isolation, Role-Based Access & Server-Only Boundaries
-- ============================================================================

-- 0. SCHEMA & SEARCH PATH PREPARATION
CREATE SCHEMA IF NOT EXISTS private;

-- ============================================================================
-- 1. SECURITY DEFINER TRUSTED IDENTITY & TENANT HELPERS
-- Must adhere to: SECURITY DEFINER, SET search_path = '', fully schema-qualified
-- Never trust caller-supplied tenant, role, or user IDs.
-- ============================================================================

-- Returns the trusted profile of the currently authenticated caller (or NULL if unauthenticated)
CREATE OR REPLACE FUNCTION private.get_auth_profile()
RETURNS TABLE (
    id UUID,
    role public.user_role_enum,
    external_tenant_id VARCHAR(64)
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
    SELECT p.id, p.role, p.external_tenant_id
    FROM public.profiles p
    WHERE p.id = (SELECT auth.uid());
$$;

-- Returns the trusted tenant ID of the authenticated user
CREATE OR REPLACE FUNCTION private.get_auth_tenant_id()
RETURNS VARCHAR(64)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
    SELECT p.external_tenant_id
    FROM public.profiles p
    WHERE p.id = (SELECT auth.uid());
$$;

-- Returns the trusted role of the authenticated user
CREATE OR REPLACE FUNCTION private.get_auth_role()
RETURNS public.user_role_enum
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
    SELECT p.role
    FROM public.profiles p
    WHERE p.id = (SELECT auth.uid());
$$;

REVOKE EXECUTE ON FUNCTION private.get_auth_profile() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.get_auth_profile() TO authenticated;

REVOKE EXECUTE ON FUNCTION private.get_auth_tenant_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.get_auth_tenant_id() TO authenticated;

REVOKE EXECUTE ON FUNCTION private.get_auth_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.get_auth_role() TO authenticated;

-- ============================================================================
-- 2. ENABLE ROW LEVEL SECURITY ON ALL SENSITIVE & REFERENCE TABLES
-- ============================================================================
ALTER TABLE public.proficiency_levels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.language_skills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.question_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.question_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exam_sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exam_skill_weights ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.placement_level_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exam_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attempt_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attempt_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.teacher_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.student_teacher_inquiries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_pedagogical_analyses ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- 3. GLOBAL REFERENCE TABLES POLICIES (Read-only for authenticated users)
-- ============================================================================
DROP POLICY IF EXISTS "Allow authenticated read on proficiency_levels" ON public.proficiency_levels;
CREATE POLICY "Allow authenticated read on proficiency_levels" ON public.proficiency_levels
FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS "Allow authenticated read on language_skills" ON public.language_skills;
CREATE POLICY "Allow authenticated read on language_skills" ON public.language_skills
FOR SELECT TO authenticated
USING (true);

REVOKE INSERT, UPDATE, DELETE ON public.proficiency_levels FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.language_skills FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 4. PROFILES POLICIES
-- Users can only view self; Teachers/Admins can view profiles within their tenant.
-- Users cannot modify role or external_tenant_id.
-- ============================================================================
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile" ON public.profiles
FOR SELECT TO authenticated
USING (id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "Teachers and admins can view tenant profiles" ON public.profiles;
CREATE POLICY "Teachers and admins can view tenant profiles" ON public.profiles
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

DROP POLICY IF EXISTS "Users can update own profile name and email" ON public.profiles;
CREATE POLICY "Users can update own profile name and email" ON public.profiles
FOR UPDATE TO authenticated
USING (id = (SELECT auth.uid()))
WITH CHECK (
    id = (SELECT auth.uid())
    AND role = private.get_auth_role()
    AND external_tenant_id = private.get_auth_tenant_id()
);

REVOKE INSERT, DELETE ON public.profiles FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 5. QUESTION BANK POLICIES (Strictly protected from direct student access)
-- Questions, options, and answers visible only to teachers/admins in the same tenant.
-- ============================================================================

-- Questions
DROP POLICY IF EXISTS "Teachers and admins can view tenant questions" ON public.questions;
CREATE POLICY "Teachers and admins can view tenant questions" ON public.questions
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

DROP POLICY IF EXISTS "Teachers and admins can insert tenant questions" ON public.questions;
CREATE POLICY "Teachers and admins can insert tenant questions" ON public.questions
FOR INSERT TO authenticated
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

DROP POLICY IF EXISTS "Teachers and admins can update tenant questions" ON public.questions;
CREATE POLICY "Teachers and admins can update tenant questions" ON public.questions
FOR UPDATE TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
)
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

REVOKE DELETE ON public.questions FROM PUBLIC, anon, authenticated;

-- Question Options
DROP POLICY IF EXISTS "Teachers and admins can view question options" ON public.question_options;
CREATE POLICY "Teachers and admins can view question options" ON public.question_options
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.questions q
        WHERE q.id = question_options.question_id
          AND q.external_tenant_id = private.get_auth_tenant_id()
    )
);

DROP POLICY IF EXISTS "Teachers and admins can manage question options" ON public.question_options;
DROP POLICY IF EXISTS "Teachers and admins can insert draft question options" ON public.question_options;
CREATE POLICY "Teachers and admins can insert draft question options" ON public.question_options
FOR INSERT TO authenticated
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.questions q
        WHERE q.id = question_options.question_id
          AND q.external_tenant_id = private.get_auth_tenant_id()
          AND q.status = 'draft'::public.content_status_enum
    )
);

DROP POLICY IF EXISTS "Teachers and admins can update draft question options" ON public.question_options;
CREATE POLICY "Teachers and admins can update draft question options" ON public.question_options
FOR UPDATE TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.questions q
        WHERE q.id = question_options.question_id
          AND q.external_tenant_id = private.get_auth_tenant_id()
          AND q.status = 'draft'::public.content_status_enum
    )
)
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.questions q
        WHERE q.id = question_options.question_id
          AND q.external_tenant_id = private.get_auth_tenant_id()
          AND q.status = 'draft'::public.content_status_enum
    )
);

DROP POLICY IF EXISTS "Teachers and admins can delete draft question options" ON public.question_options;
CREATE POLICY "Teachers and admins can delete draft question options" ON public.question_options
FOR DELETE TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.questions q
        WHERE q.id = question_options.question_id
          AND q.external_tenant_id = private.get_auth_tenant_id()
          AND q.status = 'draft'::public.content_status_enum
    )
);

-- Question Answers (Server-side grading & answer keys - completely hidden from students)
DROP POLICY IF EXISTS "Teachers and admins can view question answers" ON public.question_answers;
CREATE POLICY "Teachers and admins can view question answers" ON public.question_answers
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.questions q
        WHERE q.id = question_answers.question_id
          AND q.external_tenant_id = private.get_auth_tenant_id()
    )
);

DROP POLICY IF EXISTS "Teachers and admins can manage question answers" ON public.question_answers;
DROP POLICY IF EXISTS "Teachers and admins can insert draft question answers" ON public.question_answers;
CREATE POLICY "Teachers and admins can insert draft question answers" ON public.question_answers
FOR INSERT TO authenticated
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.questions q
        WHERE q.id = question_answers.question_id
          AND q.external_tenant_id = private.get_auth_tenant_id()
          AND q.status = 'draft'::public.content_status_enum
    )
);

DROP POLICY IF EXISTS "Teachers and admins can update draft question answers" ON public.question_answers;
CREATE POLICY "Teachers and admins can update draft question answers" ON public.question_answers
FOR UPDATE TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.questions q
        WHERE q.id = question_answers.question_id
          AND q.external_tenant_id = private.get_auth_tenant_id()
          AND q.status = 'draft'::public.content_status_enum
    )
)
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.questions q
        WHERE q.id = question_answers.question_id
          AND q.external_tenant_id = private.get_auth_tenant_id()
          AND q.status = 'draft'::public.content_status_enum
    )
);

REVOKE DELETE ON public.question_answers FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 6. EXAMS, SECTIONS & SKILL WEIGHTS POLICIES
-- Students interact with exams exclusively through server-side attempt workflows.
-- Direct student SELECT on public.exams is removed to prevent internal configuration exposure.
-- Internal exam sections, skill weights, and placement rules are hidden from students.
-- Approved exam content and configuration are immutable.
-- ============================================================================

-- Exams
DROP POLICY IF EXISTS "Teachers and admins can view tenant exams" ON public.exams;
CREATE POLICY "Teachers and admins can view tenant exams" ON public.exams
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

DROP POLICY IF EXISTS "Students can view approved tenant exams" ON public.exams;

DROP POLICY IF EXISTS "Teachers and admins can insert tenant exams" ON public.exams;
CREATE POLICY "Teachers and admins can insert tenant exams" ON public.exams
FOR INSERT TO authenticated
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

DROP POLICY IF EXISTS "Teachers and admins can update tenant exams" ON public.exams;
CREATE POLICY "Teachers and admins can update tenant exams" ON public.exams
FOR UPDATE TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
    AND status = 'draft'::public.content_status_enum
)
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
    AND status = 'draft'::public.content_status_enum
);

REVOKE DELETE ON public.exams FROM PUBLIC, anon, authenticated;

-- Exam Sections
DROP POLICY IF EXISTS "Teachers and admins can view exam sections" ON public.exam_sections;
CREATE POLICY "Teachers and admins can view exam sections" ON public.exam_sections
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.exams e
        WHERE e.id = exam_sections.exam_id
          AND e.external_tenant_id = private.get_auth_tenant_id()
    )
);

DROP POLICY IF EXISTS "Teachers and admins can manage exam sections" ON public.exam_sections;
CREATE POLICY "Teachers and admins can manage exam sections for draft exams" ON public.exam_sections
FOR ALL TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.exams e
        WHERE e.id = exam_sections.exam_id
          AND e.external_tenant_id = private.get_auth_tenant_id()
          AND e.status = 'draft'::public.content_status_enum
    )
)
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.exams e
        WHERE e.id = exam_sections.exam_id
          AND e.external_tenant_id = private.get_auth_tenant_id()
          AND e.status = 'draft'::public.content_status_enum
    )
);

-- Exam Skill Weights
DROP POLICY IF EXISTS "Teachers and admins can view exam skill weights" ON public.exam_skill_weights;
CREATE POLICY "Teachers and admins can view exam skill weights" ON public.exam_skill_weights
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.exams e
        WHERE e.id = exam_skill_weights.exam_id
          AND e.external_tenant_id = private.get_auth_tenant_id()
    )
);

DROP POLICY IF EXISTS "Teachers and admins can manage exam skill weights" ON public.exam_skill_weights;
CREATE POLICY "Teachers and admins can manage exam skill weights for draft exams" ON public.exam_skill_weights
FOR ALL TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.exams e
        WHERE e.id = exam_skill_weights.exam_id
          AND e.external_tenant_id = private.get_auth_tenant_id()
          AND e.status = 'draft'::public.content_status_enum
    )
)
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.exams e
        WHERE e.id = exam_skill_weights.exam_id
          AND e.external_tenant_id = private.get_auth_tenant_id()
          AND e.status = 'draft'::public.content_status_enum
    )
);

-- Placement Level Rules
DROP POLICY IF EXISTS "Teachers and admins can view placement rules" ON public.placement_level_rules;
CREATE POLICY "Teachers and admins can view placement rules" ON public.placement_level_rules
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

DROP POLICY IF EXISTS "Teachers and admins can manage placement rules" ON public.placement_level_rules;
CREATE POLICY "Teachers and admins can manage placement rules" ON public.placement_level_rules
FOR ALL TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
)
WITH CHECK (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

-- ============================================================================
-- 7. EXAM ATTEMPTS (Server-Authoritative Lifecycle & Timer)
-- Direct client INSERT, UPDATE, DELETE are completely revoked.
-- Mutations occur exclusively through server-side atomic RPCs.
-- ============================================================================
DROP POLICY IF EXISTS "Students can view own exam attempts" ON public.exam_attempts;
CREATE POLICY "Students can view own exam attempts" ON public.exam_attempts
FOR SELECT TO authenticated
USING (
    student_id = (SELECT auth.uid())
    AND external_tenant_id = private.get_auth_tenant_id()
);

DROP POLICY IF EXISTS "Teachers and admins can view tenant exam attempts" ON public.exam_attempts;
CREATE POLICY "Teachers and admins can view tenant exam attempts" ON public.exam_attempts
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

REVOKE INSERT, UPDATE, DELETE ON public.exam_attempts FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 8. ATTEMPT ITEMS (Frozen Snapshot of Questions)
-- Direct client INSERT, UPDATE, DELETE are completely revoked.
-- Students view only frozen question snapshot fields for their own attempts.
-- ============================================================================
DROP POLICY IF EXISTS "Students can view own attempt items" ON public.attempt_items;
CREATE POLICY "Students can view own attempt items" ON public.attempt_items
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.exam_attempts ea
        WHERE ea.id = attempt_items.attempt_id
          AND ea.student_id = (SELECT auth.uid())
          AND ea.external_tenant_id = private.get_auth_tenant_id()
    )
);

DROP POLICY IF EXISTS "Teachers and admins can view tenant attempt items" ON public.attempt_items;
CREATE POLICY "Teachers and admins can view tenant attempt items" ON public.attempt_items
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.exam_attempts ea
        WHERE ea.id = attempt_items.attempt_id
          AND ea.external_tenant_id = private.get_auth_tenant_id()
    )
);

REVOKE INSERT, UPDATE, DELETE ON public.attempt_items FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 9. ATTEMPT ANSWERS (Authoritative Submission Boundary)
-- Direct client INSERT, UPDATE, DELETE are completely revoked.
-- Mutations occur exclusively via save_exam_answer_atomic RPC to enforce timer & validity.
-- ============================================================================
DROP POLICY IF EXISTS "Students can view own attempt answers" ON public.attempt_answers;
CREATE POLICY "Students can view own attempt answers" ON public.attempt_answers
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.attempt_items ai
        JOIN public.exam_attempts ea ON ea.id = ai.attempt_id
        WHERE ai.id = attempt_answers.attempt_item_id
          AND ea.student_id = (SELECT auth.uid())
          AND ea.external_tenant_id = private.get_auth_tenant_id()
    )
);

DROP POLICY IF EXISTS "Teachers and admins can view tenant attempt answers" ON public.attempt_answers;
CREATE POLICY "Teachers and admins can view tenant attempt answers" ON public.attempt_answers
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.attempt_items ai
        JOIN public.exam_attempts ea ON ea.id = ai.attempt_id
        WHERE ai.id = attempt_answers.attempt_item_id
          AND ea.external_tenant_id = private.get_auth_tenant_id()
    )
);

REVOKE INSERT, UPDATE, DELETE ON public.attempt_answers FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 10. TEACHER REVIEWS (Locked Review & Grading Boundary)
-- Students can only view finalized reviews when final_scoring_status = official_final.
-- Direct client INSERT, UPDATE, DELETE are completely revoked from authenticated users.
-- Mutations occur exclusively via submit_teacher_review_atomic RPC.
-- ============================================================================
DROP POLICY IF EXISTS "Students can view finalized reviews for their finalized attempts" ON public.teacher_reviews;
CREATE POLICY "Students can view finalized reviews for their finalized attempts" ON public.teacher_reviews
FOR SELECT TO authenticated
USING (
    is_finalized = true
    AND EXISTS (
        SELECT 1 FROM public.attempt_items ai
        JOIN public.exam_attempts ea ON ea.id = ai.attempt_id
        WHERE ai.id = teacher_reviews.attempt_item_id
          AND ea.student_id = (SELECT auth.uid())
          AND ea.external_tenant_id = private.get_auth_tenant_id()
          AND ea.final_scoring_status = 'official_final'::public.scoring_status_enum
    )
);

DROP POLICY IF EXISTS "Teachers and admins can view tenant teacher reviews" ON public.teacher_reviews;
CREATE POLICY "Teachers and admins can view tenant teacher reviews" ON public.teacher_reviews
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND EXISTS (
        SELECT 1 FROM public.attempt_items ai
        JOIN public.exam_attempts ea ON ea.id = ai.attempt_id
        WHERE ai.id = teacher_reviews.attempt_item_id
          AND ea.external_tenant_id = private.get_auth_tenant_id()
    )
);

REVOKE INSERT, UPDATE, DELETE ON public.teacher_reviews FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 11. STUDENT-TEACHER INQUIRIES
-- Students can insert/update only open inquiries for their own attempts.
-- Students cannot assign teacher, cannot write teacher response, cannot alter status.
-- Teacher responses are submitted via server-side service role.
-- ============================================================================
DROP POLICY IF EXISTS "Students can view own inquiries" ON public.student_teacher_inquiries;
CREATE POLICY "Students can view own inquiries" ON public.student_teacher_inquiries
FOR SELECT TO authenticated
USING (
    student_id = (SELECT auth.uid())
    AND external_tenant_id = private.get_auth_tenant_id()
);

DROP POLICY IF EXISTS "Teachers and admins can view tenant inquiries" ON public.student_teacher_inquiries;
CREATE POLICY "Teachers and admins can view tenant inquiries" ON public.student_teacher_inquiries
FOR SELECT TO authenticated
USING (
    private.get_auth_role() IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
    AND external_tenant_id = private.get_auth_tenant_id()
);

DROP POLICY IF EXISTS "Students can create own inquiries" ON public.student_teacher_inquiries;
CREATE POLICY "Students can create own inquiries" ON public.student_teacher_inquiries
FOR INSERT TO authenticated
WITH CHECK (
    student_id = (SELECT auth.uid())
    AND external_tenant_id = private.get_auth_tenant_id()
    AND status = 'open'::public.inquiry_status_enum
    AND teacher_id IS NULL
    AND teacher_response IS NULL
    AND EXISTS (
        SELECT 1 FROM public.exam_attempts ea
        WHERE ea.id = student_teacher_inquiries.attempt_id
          AND ea.student_id = (SELECT auth.uid())
          AND ea.external_tenant_id = private.get_auth_tenant_id()
    )
    AND (
        attempt_item_id IS NULL OR
        EXISTS (
            SELECT 1 FROM public.attempt_items ai
            WHERE ai.id = student_teacher_inquiries.attempt_item_id
              AND ai.attempt_id = student_teacher_inquiries.attempt_id
        )
    )
);

DROP POLICY IF EXISTS "Students can update own open inquiries" ON public.student_teacher_inquiries;
CREATE POLICY "Students can update own open inquiries" ON public.student_teacher_inquiries
FOR UPDATE TO authenticated
USING (
    student_id = (SELECT auth.uid())
    AND external_tenant_id = private.get_auth_tenant_id()
    AND status = 'open'::public.inquiry_status_enum
)
WITH CHECK (
    student_id = (SELECT auth.uid())
    AND external_tenant_id = private.get_auth_tenant_id()
    AND status = 'open'::public.inquiry_status_enum
    AND teacher_id IS NULL
    AND teacher_response IS NULL
);

REVOKE DELETE ON public.student_teacher_inquiries FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 12. AI PEDAGOGICAL ANALYSES (Phase 7 RLS Hardening)
-- Mutations are restricted exclusively to server-side service role.
-- Students view only completed analyses for official_final attempts.
-- ============================================================================
REVOKE INSERT, UPDATE, DELETE ON public.ai_pedagogical_analyses FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 13. GLOBAL TABLE PERMISSION GRANTS
-- Grant SELECT and necessary safe client DML to authenticated role so RLS can filter.
-- Unauthenticated (anon) and PUBLIC receive zero privileges on data tables.
-- ============================================================================
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, PUBLIC;
GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT ON public.proficiency_levels TO authenticated;
GRANT SELECT ON public.language_skills TO authenticated;
GRANT SELECT, UPDATE (full_name, email) ON public.profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.questions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.question_options TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.question_answers TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.exams TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exam_sections TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exam_skill_weights TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.placement_level_rules TO authenticated;
GRANT SELECT ON public.exam_attempts TO authenticated;
GRANT SELECT ON public.attempt_items TO authenticated;
GRANT SELECT ON public.attempt_answers TO authenticated;
GRANT SELECT ON public.teacher_reviews TO authenticated;
GRANT SELECT, INSERT, UPDATE (subject, student_message) ON public.student_teacher_inquiries TO authenticated;
GRANT SELECT ON public.ai_pedagogical_analyses TO authenticated;
