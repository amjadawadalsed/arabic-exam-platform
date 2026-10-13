-- ============================================================
-- CONSOLIDATED SUPABASE DEPLOYMENT SCRIPT (MIGRATIONS 1 TO 10)
-- Standalone Arabic Exam & Assessment System
-- Generated: 2026-10-05 (All 10 Migrations Verified & Ordered)
-- ============================================================

-- ============================================================
-- MIGRATION 1
-- Original file: supabase/migrations/20261001_phase8b1_base_schema_reconstruction.sql
-- ============================================================

-- ============================================================================
-- PHASE 8B.1: Controlled Base Schema Reconstruction
-- Standalone Arabic Exam & Assessment Module
-- Foundational Tables, Enums, Constraints, and Indexes
-- ============================================================================

-- 0. Required Extensions & Schemas
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE SCHEMA IF NOT EXISTS private;

-- ============================================================================
-- 1. ENUMS (Ordered Creation with Idempotency Checks)
-- ============================================================================
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role_enum') THEN
        CREATE TYPE public.user_role_enum AS ENUM ('student', 'teacher', 'admin');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'exam_type_enum') THEN
        CREATE TYPE public.exam_type_enum AS ENUM ('placement', 'formative', 'summative', 'diagnostic');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'content_status_enum') THEN
        CREATE TYPE public.content_status_enum AS ENUM ('draft', 'approved', 'archived');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'question_type_enum') THEN
        CREATE TYPE public.question_type_enum AS ENUM (
            'mcq', 
            'true_false', 
            'short_answer', 
            'writing', 
            'listening', 
            'speaking'
        );
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'attempt_status_enum') THEN
        CREATE TYPE public.attempt_status_enum AS ENUM ('in_progress', 'completed', 'expired');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'scoring_status_enum') THEN
        CREATE TYPE public.scoring_status_enum AS ENUM ('provisional', 'official_final');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'placement_status_enum') THEN
        CREATE TYPE public.placement_status_enum AS ENUM ('pending', 'assigned', 'review_required');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'review_status_enum') THEN
        CREATE TYPE public.review_status_enum AS ENUM ('not_required', 'pending_teacher_review', 'completed');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'inquiry_status_enum') THEN
        CREATE TYPE public.inquiry_status_enum AS ENUM ('open', 'in_progress', 'answered', 'closed');
    END IF;
END $$;

-- ============================================================================
-- 2. GLOBAL REFERENCE TABLES
-- ============================================================================

-- Proficiency Levels (Global Reference Table)
CREATE TABLE IF NOT EXISTS public.proficiency_levels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(32) NOT NULL UNIQUE,
    name_ar TEXT NOT NULL,
    rank_order INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- Language Skills (Global Reference Table)
CREATE TABLE IF NOT EXISTS public.language_skills (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(32) NOT NULL UNIQUE,
    name_ar TEXT NOT NULL,
    description TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ============================================================================
-- 3. PROFILES (Tenant-Scoped Identity)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_tenant_id VARCHAR(64) NOT NULL,
    role public.user_role_enum NOT NULL DEFAULT 'student',
    full_name TEXT NULL,
    email TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ============================================================================
-- 4. QUESTION BANK (Tenant-Scoped, Immutable Content Model)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.questions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_tenant_id VARCHAR(64) NOT NULL,
    skill_id UUID NOT NULL REFERENCES public.language_skills(id) ON DELETE RESTRICT,
    question_type public.question_type_enum NOT NULL,
    question_text TEXT NOT NULL,
    default_score NUMERIC(5,2) NOT NULL DEFAULT 1.00 CHECK (default_score > 0),
    status public.content_status_enum NOT NULL DEFAULT 'draft',
    version_group_id UUID NOT NULL DEFAULT gen_random_uuid(),
    version_number INTEGER NOT NULL DEFAULT 1,
    is_current_version BOOLEAN NOT NULL DEFAULT true,
    media_storage_path TEXT NULL,
    created_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS public.question_options (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    question_id UUID NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
    option_key VARCHAR(16) NOT NULL,
    option_text TEXT NOT NULL,
    sort_order INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_question_options_key UNIQUE (question_id, option_key),
    CONSTRAINT uq_question_options_sort UNIQUE (question_id, sort_order)
);

CREATE TABLE IF NOT EXISTS public.question_answers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    question_id UUID NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
    correct_option_key VARCHAR(16) NULL,
    accepted_text_answers JSONB NULL,
    explanation TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ============================================================================
-- 5. EXAMS, SECTIONS & SKILL WEIGHTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.exams (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_tenant_id VARCHAR(64) NOT NULL,
    title TEXT NOT NULL,
    exam_type public.exam_type_enum NOT NULL,
    status public.content_status_enum NOT NULL DEFAULT 'draft',
    duration_minutes INTEGER NOT NULL CHECK (duration_minutes > 0),
    passing_score_percentage NUMERIC(5,2) NOT NULL CHECK (passing_score_percentage >= 0 AND passing_score_percentage <= 100),
    scoring_policy VARCHAR(32) NOT NULL DEFAULT 'standard',
    placement_rule_id UUID NULL,
    created_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS public.exam_sections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id UUID NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    sort_order INTEGER NOT NULL,
    skill_id UUID NULL REFERENCES public.language_skills(id) ON DELETE RESTRICT,
    section_instructions TEXT NULL,
    allocated_questions_count INTEGER NOT NULL DEFAULT 1 CHECK (allocated_questions_count > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_exam_sections_sort UNIQUE (exam_id, sort_order)
);

CREATE TABLE IF NOT EXISTS public.exam_skill_weights (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id UUID NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
    skill_id UUID NOT NULL REFERENCES public.language_skills(id) ON DELETE RESTRICT,
    weight_percentage NUMERIC(5,2) NOT NULL CHECK (weight_percentage > 0 AND weight_percentage <= 100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_exam_skill_weights UNIQUE (exam_id, skill_id)
);

-- ============================================================================
-- 6. PLACEMENT LEVEL RULES (Tenant-Scoped)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.placement_level_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_tenant_id VARCHAR(64) NOT NULL,
    proficiency_level_id UUID NOT NULL REFERENCES public.proficiency_levels(id) ON DELETE RESTRICT,
    min_percentage NUMERIC(5,2) NOT NULL CHECK (min_percentage >= 0 AND min_percentage <= 100),
    max_percentage NUMERIC(5,2) NOT NULL CHECK (max_percentage >= 0 AND max_percentage <= 100),
    skill_id UUID NULL REFERENCES public.language_skills(id) ON DELETE RESTRICT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_placement_percentage_range CHECK (min_percentage <= max_percentage)
);

-- ============================================================================
-- 7. EXAM ATTEMPTS (Server-Authoritative Lifecycle & Timer)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.exam_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id UUID NOT NULL REFERENCES public.exams(id) ON DELETE RESTRICT,
    student_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    external_tenant_id VARCHAR(64) NOT NULL,
    status public.attempt_status_enum NOT NULL DEFAULT 'in_progress',
    attempt_number INTEGER NOT NULL DEFAULT 1,
    started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    expires_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ NULL,
    total_score NUMERIC(6,2) NULL,
    percentage_score NUMERIC(5,2) NULL,
    is_passed BOOLEAN NULL,
    placement_level_id UUID NULL REFERENCES public.proficiency_levels(id) ON DELETE SET NULL,
    placement_status public.placement_status_enum NOT NULL DEFAULT 'pending',
    final_scoring_status public.scoring_status_enum NOT NULL DEFAULT 'provisional',
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ============================================================================
-- 8. ATTEMPT ITEMS (Frozen Snapshot of Questions)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.attempt_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    attempt_id UUID NOT NULL REFERENCES public.exam_attempts(id) ON DELETE CASCADE,
    question_id UUID NOT NULL REFERENCES public.questions(id) ON DELETE RESTRICT,
    skill_id UUID NOT NULL REFERENCES public.language_skills(id) ON DELETE RESTRICT,
    item_type public.question_type_enum NOT NULL,
    allocated_score NUMERIC(5,2) NOT NULL CHECK (allocated_score >= 0),
    awarded_score NUMERIC(5,2) NULL,
    is_correct BOOLEAN NULL,
    frozen_question_text TEXT NOT NULL,
    frozen_options JSONB NULL,
    review_status public.review_status_enum NOT NULL DEFAULT 'not_required',
    sort_order INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ============================================================================
-- 9. ATTEMPT ANSWERS & TEACHER REVIEWS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.attempt_answers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    attempt_item_id UUID NOT NULL REFERENCES public.attempt_items(id) ON DELETE CASCADE,
    selected_option_key VARCHAR(16) NULL,
    text_response TEXT NULL,
    audio_storage_path TEXT NULL,
    audio_duration_seconds NUMERIC(6,2) NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_attempt_answers_item UNIQUE (attempt_item_id)
);

CREATE TABLE IF NOT EXISTS public.teacher_reviews (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    attempt_item_id UUID NOT NULL REFERENCES public.attempt_items(id) ON DELETE CASCADE,
    teacher_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    assigned_score NUMERIC(5,2) NULL,
    feedback_text TEXT NULL,
    is_finalized BOOLEAN NOT NULL DEFAULT false,
    finalized_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_teacher_reviews_item UNIQUE (attempt_item_id),
    CONSTRAINT chk_teacher_review_finalized_score CHECK (
        is_finalized = false OR (is_finalized = true AND assigned_score IS NOT NULL)
    )
);

-- ============================================================================
-- 10. STUDENT-TEACHER INQUIRIES
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.student_teacher_inquiries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_tenant_id VARCHAR(64) NOT NULL,
    attempt_id UUID NOT NULL REFERENCES public.exam_attempts(id) ON DELETE RESTRICT,
    attempt_item_id UUID NULL REFERENCES public.attempt_items(id) ON DELETE SET NULL,
    student_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    teacher_id UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    subject TEXT NOT NULL,
    student_message TEXT NOT NULL,
    teacher_response TEXT NULL,
    status public.inquiry_status_enum NOT NULL DEFAULT 'open',
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ============================================================================
-- 11. INDEXES FOR PERFORMANCE & TENANT ISOLATION
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_profiles_tenant ON public.profiles(external_tenant_id);
CREATE INDEX IF NOT EXISTS idx_exams_tenant ON public.exams(external_tenant_id);
CREATE INDEX IF NOT EXISTS idx_questions_tenant ON public.questions(external_tenant_id);
CREATE INDEX IF NOT EXISTS idx_questions_skill ON public.questions(skill_id);
CREATE INDEX IF NOT EXISTS idx_placement_level_rules_tenant ON public.placement_level_rules(external_tenant_id);
CREATE INDEX IF NOT EXISTS idx_exam_attempts_tenant ON public.exam_attempts(external_tenant_id);
CREATE INDEX IF NOT EXISTS idx_exam_attempts_student ON public.exam_attempts(student_id);
CREATE INDEX IF NOT EXISTS idx_exam_attempts_exam ON public.exam_attempts(exam_id);
CREATE INDEX IF NOT EXISTS idx_attempt_items_attempt ON public.attempt_items(attempt_id);
CREATE INDEX IF NOT EXISTS idx_attempt_items_question ON public.attempt_items(question_id);
CREATE INDEX IF NOT EXISTS idx_attempt_answers_item ON public.attempt_answers(attempt_item_id);
CREATE INDEX IF NOT EXISTS idx_teacher_reviews_item ON public.teacher_reviews(attempt_item_id);
CREATE INDEX IF NOT EXISTS idx_inquiries_tenant ON public.student_teacher_inquiries(external_tenant_id);
CREATE INDEX IF NOT EXISTS idx_inquiries_attempt ON public.student_teacher_inquiries(attempt_id);



-- ============================================================
-- MIGRATION 2
-- Original file: supabase/migrations/20261004_phase8b3a_restore_exam_max_attempts.sql
-- ============================================================

-- ============================================================================
-- PHASE 8B.3A: Schema Correction - Restore Exam Max Attempts
-- Standalone Arabic Exam & Assessment Module
-- Controlled restoration of max_attempts column on public.exams
-- ============================================================================

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 
        FROM information_schema.columns 
        WHERE table_schema = 'public' 
          AND table_name = 'exams' 
          AND column_name = 'max_attempts'
    ) THEN
        ALTER TABLE public.exams 
        ADD COLUMN max_attempts INTEGER NOT NULL DEFAULT 1;

        ALTER TABLE public.exams 
        ADD CONSTRAINT chk_exams_max_attempts CHECK (max_attempts >= 1);
    END IF;
END $$;



-- ============================================================
-- MIGRATION 3
-- Original file: supabase/migrations/20261001_phase7_gemini_pedagogical_analysis.sql
-- ============================================================

-- ============================================================================
-- PHASE 7 MIGRATION: Gemini Pedagogical AI Analysis
-- ============================================================================
-- 1. Enum
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_analysis_status_enum') THEN
        CREATE TYPE public.ai_analysis_status_enum AS ENUM (
            'pending',
            'completed',
            'failed'
        );
    END IF;
END $$;

-- 2. Table: ai_pedagogical_analyses
CREATE TABLE IF NOT EXISTS public.ai_pedagogical_analyses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    attempt_id UUID NOT NULL REFERENCES public.exam_attempts(id) ON DELETE CASCADE,
    external_tenant_id VARCHAR(64) NOT NULL,
    status public.ai_analysis_status_enum NOT NULL DEFAULT 'pending',
    pedagogical_feedback JSONB NOT NULL DEFAULT '{}'::jsonb,
    strengths_weaknesses JSONB NOT NULL DEFAULT '{}'::jsonb,
    structured_analysis JSONB NULL,
    model_version VARCHAR(64) NOT NULL DEFAULT 'gemini-3.8-flash',
    error_message TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_ai_pedagogical_analyses_attempt UNIQUE(attempt_id)
);

ALTER TABLE public.ai_pedagogical_analyses 
ADD COLUMN IF NOT EXISTS external_tenant_id VARCHAR(64);
ALTER TABLE public.ai_pedagogical_analyses 
ADD COLUMN IF NOT EXISTS status public.ai_analysis_status_enum NOT NULL DEFAULT 'pending';
ALTER TABLE public.ai_pedagogical_analyses 
ADD COLUMN IF NOT EXISTS structured_analysis JSONB NULL;
ALTER TABLE public.ai_pedagogical_analyses 
ADD COLUMN IF NOT EXISTS model_version VARCHAR(64) NOT NULL DEFAULT 'gemini-3.8-flash';
ALTER TABLE public.ai_pedagogical_analyses 
ADD COLUMN IF NOT EXISTS error_message TEXT NULL;
ALTER TABLE public.ai_pedagogical_analyses 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp();

UPDATE public.ai_pedagogical_analyses apa 
SET external_tenant_id = ea.external_tenant_id 
FROM public.exam_attempts ea 
WHERE apa.attempt_id = ea.id AND apa.external_tenant_id IS NULL;

ALTER TABLE public.ai_pedagogical_analyses 
ALTER COLUMN external_tenant_id SET NOT NULL;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'uq_ai_pedagogical_analyses_attempt'
    ) THEN
        ALTER TABLE public.ai_pedagogical_analyses 
        ADD CONSTRAINT uq_ai_pedagogical_analyses_attempt UNIQUE (attempt_id);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_ai_pedagogical_analyses_tenant 
ON public.ai_pedagogical_analyses(external_tenant_id);
CREATE INDEX IF NOT EXISTS idx_ai_pedagogical_analyses_status 
ON public.ai_pedagogical_analyses(status);

-- 3. RLS for ai_pedagogical_analyses
ALTER TABLE public.ai_pedagogical_analyses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Students can view their own completed analysis" ON public.ai_pedagogical_analyses;
CREATE POLICY "Students can view their own completed analysis" ON public.ai_pedagogical_analyses FOR SELECT TO authenticated USING (
    status = 'completed'::public.ai_analysis_status_enum AND
    EXISTS (
        SELECT 1 FROM public.exam_attempts ea
        WHERE ea.id = ai_pedagogical_analyses.attempt_id
          AND ea.student_id = (SELECT auth.uid())
          AND ea.final_scoring_status = 'official_final'::public.scoring_status_enum
    )
);

DROP POLICY IF EXISTS "Teachers and admins can view tenant analyses" ON public.ai_pedagogical_analyses;
CREATE POLICY "Teachers and admins can view tenant analyses" ON public.ai_pedagogical_analyses FOR SELECT TO authenticated USING (
    EXISTS (
        SELECT 1 FROM public.profiles p
        WHERE p.id = (SELECT auth.uid())
          AND p.role IN ('teacher'::public.user_role_enum, 'admin'::public.user_role_enum)
          AND p.external_tenant_id = ai_pedagogical_analyses.external_tenant_id
    )
);

REVOKE INSERT, UPDATE, DELETE ON public.ai_pedagogical_analyses FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 4. Functions
-- ============================================================================
CREATE OR REPLACE FUNCTION private.initialize_pedagogical_analysis(
    p_attempt_id UUID,
    p_caller_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_attempt RECORD;
    v_caller RECORD;
    v_existing RECORD;
BEGIN
    SELECT id, role, external_tenant_id
    INTO v_caller
    FROM public.profiles
    WHERE id = p_caller_id;

    IF v_caller.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized', 'message', 'Caller profile not found.');
    END IF;

    SELECT id, student_id, external_tenant_id, status, final_scoring_status, placement_status
    INTO v_attempt
    FROM public.exam_attempts
    WHERE id = p_attempt_id
    FOR UPDATE;

    IF v_attempt.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'attempt_not_found');
    END IF;

    IF v_attempt.external_tenant_id <> v_caller.external_tenant_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_mismatch');
    END IF;

    IF v_caller.role = 'student'::public.user_role_enum AND v_attempt.student_id <> v_caller.id THEN
        RETURN jsonb_build_object('success', false, 'error', 'forbidden_ownership');
    END IF;

    IF v_attempt.final_scoring_status <> 'official_final'::public.scoring_status_enum THEN
        RETURN jsonb_build_object(
            'success', false, 
            'error', 'attempt_not_final', 
            'current_status', v_attempt.final_scoring_status,
            'message', 'Pedagogical analysis can only be generated for officially finalized attempts.'
        );
    END IF;

    SELECT id, status, structured_analysis, error_message
    INTO v_existing
    FROM public.ai_pedagogical_analyses
    WHERE attempt_id = p_attempt_id
    FOR UPDATE;

    IF v_existing.id IS NOT NULL THEN
        IF v_existing.status = 'completed'::public.ai_analysis_status_enum THEN
            RETURN jsonb_build_object(
                'success', true,
                'action', 'already_completed',
                'analysis_id', v_existing.id,
                'status', 'completed',
                'analysis', v_existing.structured_analysis
            );
        ELSIF v_existing.status = 'pending'::public.ai_analysis_status_enum THEN
            RETURN jsonb_build_object(
                'success', true,
                'action', 'already_pending',
                'analysis_id', v_existing.id,
                'status', 'pending',
                'message', 'Analysis is currently being generated.'
            );
        END IF;
    END IF;

    INSERT INTO public.ai_pedagogical_analyses (
        attempt_id,
        external_tenant_id,
        status,
        pedagogical_feedback,
        strengths_weaknesses,
        updated_at
    ) VALUES (
        p_attempt_id,
        v_attempt.external_tenant_id,
        'pending'::public.ai_analysis_status_enum,
        '{}'::jsonb,
        '{}'::jsonb,
        clock_timestamp()
    )
    ON CONFLICT (attempt_id) DO UPDATE SET
        status = 'pending'::public.ai_analysis_status_enum,
        error_message = NULL,
        updated_at = clock_timestamp();

    RETURN jsonb_build_object(
        'success', true,
        'action', 'ready_for_generation',
        'attempt_id', p_attempt_id,
        'tenant_id', v_attempt.external_tenant_id
    );
END;
$$;

REVOKE ALL ON FUNCTION private.initialize_pedagogical_analysis(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.initialize_pedagogical_analysis(UUID, UUID) TO service_role;

CREATE OR REPLACE FUNCTION private.save_pedagogical_analysis_result(
    p_attempt_id UUID,
    p_status public.ai_analysis_status_enum,
    p_structured_analysis JSONB DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL,
    p_model_version VARCHAR(64) DEFAULT 'gemini-3.8-flash'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_analysis RECORD;
    v_pedagogical_feedback JSONB := '{}'::jsonb;
    v_strengths_weaknesses JSONB := '{}'::jsonb;
BEGIN
    SELECT id, status
    INTO v_analysis
    FROM public.ai_pedagogical_analyses
    WHERE attempt_id = p_attempt_id
    FOR UPDATE;

    IF v_analysis.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'analysis_record_not_found');
    END IF;

    IF p_status = 'completed'::public.ai_analysis_status_enum THEN
        IF p_structured_analysis IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'missing_structured_analysis');
        END IF;

        v_pedagogical_feedback := jsonb_build_object(
            'student_summary', p_structured_analysis->>'student_summary',
            'learning_recommendations', p_structured_analysis->'learning_recommendations',
            'skill_analysis', p_structured_analysis->'skill_analysis'
        );
        v_strengths_weaknesses := jsonb_build_object(
            'strengths', p_structured_analysis->'strengths',
            'weaknesses', p_structured_analysis->'weaknesses',
            'common_errors', p_structured_analysis->'common_errors'
        );

        UPDATE public.ai_pedagogical_analyses
        SET status = 'completed'::public.ai_analysis_status_enum,
            structured_analysis = p_structured_analysis,
            pedagogical_feedback = v_pedagogical_feedback,
            strengths_weaknesses = v_strengths_weaknesses,
            model_version = p_model_version,
            error_message = NULL,
            updated_at = clock_timestamp()
        WHERE attempt_id = p_attempt_id;

        RETURN jsonb_build_object(
            'success', true,
            'status', 'completed',
            'attempt_id', p_attempt_id
        );
    ELSE
        UPDATE public.ai_pedagogical_analyses
        SET status = 'failed'::public.ai_analysis_status_enum,
            error_message = p_error_message,
            updated_at = clock_timestamp()
        WHERE attempt_id = p_attempt_id;

        RETURN jsonb_build_object(
            'success', true,
            'status', 'failed',
            'attempt_id', p_attempt_id,
            'error_logged', p_error_message
        );
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.save_pedagogical_analysis_result(UUID, public.ai_analysis_status_enum, JSONB, TEXT, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.save_pedagogical_analysis_result(UUID, public.ai_analysis_status_enum, JSONB, TEXT, VARCHAR) TO service_role;

CREATE OR REPLACE FUNCTION public.initialize_pedagogical_analysis(
    p_attempt_id UUID,
    p_caller_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN private.initialize_pedagogical_analysis(p_attempt_id, p_caller_id);
END;
$$;

REVOKE ALL ON FUNCTION public.initialize_pedagogical_analysis(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.initialize_pedagogical_analysis(UUID, UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.save_pedagogical_analysis_result(
    p_attempt_id UUID,
    p_status public.ai_analysis_status_enum,
    p_structured_analysis JSONB DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL,
    p_model_version VARCHAR(64) DEFAULT 'gemini-3.8-flash'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN private.save_pedagogical_analysis_result(
        p_attempt_id,
        p_status,
        p_structured_analysis,
        p_error_message,
        p_model_version
    );
END;
$$;

REVOKE ALL ON FUNCTION public.save_pedagogical_analysis_result(UUID, public.ai_analysis_status_enum, JSONB, TEXT, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_pedagogical_analysis_result(UUID, public.ai_analysis_status_enum, JSONB, TEXT, VARCHAR) TO service_role;



-- ============================================================
-- MIGRATION 4
-- Original file: supabase/migrations/20261001_phase7_historical_retention_and_retry_fix.sql
-- ============================================================

-- ============================================================================
-- PHASE 7 FIX: Historical Retention & Failed Retry Semantics
-- ============================================================================
-- 1. Foreign Key (ON DELETE RESTRICT)
ALTER TABLE public.ai_pedagogical_analyses 
DROP CONSTRAINT IF EXISTS ai_pedagogical_analyses_attempt_id_fkey;

ALTER TABLE public.ai_pedagogical_analyses 
ADD CONSTRAINT ai_pedagogical_analyses_attempt_id_fkey 
FOREIGN KEY (attempt_id) 
REFERENCES public.exam_attempts(id) 
ON DELETE RESTRICT;

-- 2. Function private.initialize_pedagogical_analysis
CREATE OR REPLACE FUNCTION private.initialize_pedagogical_analysis(
    p_attempt_id UUID,
    p_caller_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_attempt RECORD;
    v_caller RECORD;
    v_existing RECORD;
BEGIN
    SELECT id, role, external_tenant_id
    INTO v_caller
    FROM public.profiles
    WHERE id = p_caller_id;

    IF v_caller.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized', 'message', 'Caller profile not found.');
    END IF;

    SELECT id, student_id, external_tenant_id, status, final_scoring_status, placement_status
    INTO v_attempt
    FROM public.exam_attempts
    WHERE id = p_attempt_id
    FOR UPDATE;

    IF v_attempt.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'attempt_not_found');
    END IF;

    IF v_attempt.external_tenant_id <> v_caller.external_tenant_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_mismatch', 'message', 'Cross-tenant access prohibited.');
    END IF;

    IF v_caller.role = 'student'::public.user_role_enum AND v_attempt.student_id <> v_caller.id THEN
        RETURN jsonb_build_object('success', false, 'error', 'forbidden_ownership', 'message', 'Student can only analyze own attempt.');
    END IF;

    IF v_attempt.final_scoring_status <> 'official_final'::public.scoring_status_enum THEN
        RETURN jsonb_build_object(
            'success', false, 
            'error', 'attempt_not_final', 
            'current_status', v_attempt.final_scoring_status,
            'message', 'Pedagogical analysis can only be generated for officially finalized attempts.'
        );
    END IF;

    SELECT id, status, structured_analysis, error_message
    INTO v_existing
    FROM public.ai_pedagogical_analyses
    WHERE attempt_id = p_attempt_id
    FOR UPDATE;

    IF v_existing.id IS NOT NULL THEN
        IF v_existing.status = 'completed'::public.ai_analysis_status_enum THEN
            RETURN jsonb_build_object(
                'success', true,
                'action', 'already_completed',
                'analysis_id', v_existing.id,
                'status', 'completed',
                'analysis', v_existing.structured_analysis
            );
        ELSIF v_existing.status = 'pending'::public.ai_analysis_status_enum THEN
            RETURN jsonb_build_object(
                'success', true,
                'action', 'already_pending',
                'analysis_id', v_existing.id,
                'status', 'pending',
                'message', 'Analysis is currently being generated.'
            );
        ELSIF v_existing.status = 'failed'::public.ai_analysis_status_enum THEN
            UPDATE public.ai_pedagogical_analyses
            SET status = 'pending'::public.ai_analysis_status_enum,
                error_message = NULL,
                updated_at = clock_timestamp()
            WHERE id = v_existing.id;

            RETURN jsonb_build_object(
                'success', true,
                'action', 'retry_initiated',
                'analysis_id', v_existing.id,
                'attempt_id', p_attempt_id,
                'tenant_id', v_attempt.external_tenant_id
            );
        END IF;
    END IF;

    INSERT INTO public.ai_pedagogical_analyses (
        attempt_id,
        external_tenant_id,
        status,
        pedagogical_feedback,
        strengths_weaknesses,
        updated_at
    ) VALUES (
        p_attempt_id,
        v_attempt.external_tenant_id,
        'pending'::public.ai_analysis_status_enum,
        '{}'::jsonb,
        '{}'::jsonb,
        clock_timestamp()
    );

    RETURN jsonb_build_object(
        'success', true,
        'action', 'ready_for_generation',
        'attempt_id', p_attempt_id,
        'tenant_id', v_attempt.external_tenant_id
    );
END;
$$;

REVOKE ALL ON FUNCTION private.initialize_pedagogical_analysis(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.initialize_pedagogical_analysis(UUID, UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.initialize_pedagogical_analysis(
    p_attempt_id UUID,
    p_caller_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN private.initialize_pedagogical_analysis(p_attempt_id, p_caller_id);
END;
$$;

REVOKE ALL ON FUNCTION public.initialize_pedagogical_analysis(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.initialize_pedagogical_analysis(UUID, UUID) TO service_role;



-- ============================================================
-- MIGRATION 5
-- Original file: supabase/migrations/20261001_phase7_stale_pending_recovery.sql
-- ============================================================

-- ============================================================================
-- PHASE 7 MICRO-FIX: Stale Pending Recovery & Concurrency Hardening
-- ============================================================================
CREATE OR REPLACE FUNCTION private.initialize_pedagogical_analysis(
    p_attempt_id UUID,
    p_caller_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_attempt RECORD;
    v_caller RECORD;
    v_existing RECORD;
    v_stale_threshold CONSTANT INTERVAL := INTERVAL '10 minutes';
BEGIN
    SELECT id, role, external_tenant_id
    INTO v_caller
    FROM public.profiles
    WHERE id = p_caller_id;

    IF v_caller.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized', 'message', 'Caller profile not found.');
    END IF;

    SELECT id, student_id, external_tenant_id, status, final_scoring_status, placement_status
    INTO v_attempt
    FROM public.exam_attempts
    WHERE id = p_attempt_id
    FOR UPDATE;

    IF v_attempt.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'attempt_not_found');
    END IF;

    IF v_attempt.external_tenant_id <> v_caller.external_tenant_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_mismatch', 'message', 'Cross-tenant access prohibited.');
    END IF;

    IF v_caller.role = 'student'::public.user_role_enum AND v_attempt.student_id <> v_caller.id THEN
        RETURN jsonb_build_object('success', false, 'error', 'forbidden_ownership', 'message', 'Student can only analyze own attempt.');
    END IF;

    IF v_attempt.final_scoring_status <> 'official_final'::public.scoring_status_enum THEN
        RETURN jsonb_build_object(
            'success', false, 
            'error', 'attempt_not_final', 
            'current_status', v_attempt.final_scoring_status,
            'message', 'Pedagogical analysis can only be generated for officially finalized attempts.'
        );
    END IF;

    SELECT id, status, structured_analysis, error_message, updated_at
    INTO v_existing
    FROM public.ai_pedagogical_analyses
    WHERE attempt_id = p_attempt_id
    FOR UPDATE;

    IF v_existing.id IS NOT NULL THEN
        IF v_existing.status = 'completed'::public.ai_analysis_status_enum THEN
            RETURN jsonb_build_object(
                'success', true,
                'action', 'already_completed',
                'analysis_id', v_existing.id,
                'status', 'completed',
                'analysis', v_existing.structured_analysis
            );
        ELSIF v_existing.status = 'pending'::public.ai_analysis_status_enum THEN
            IF (clock_timestamp() - v_existing.updated_at) > v_stale_threshold THEN
                UPDATE public.ai_pedagogical_analyses
                SET updated_at = clock_timestamp(),
                    error_message = NULL
                WHERE id = v_existing.id;

                RETURN jsonb_build_object(
                    'success', true,
                    'action', 'retry_initiated',
                    'analysis_id', v_existing.id,
                    'attempt_id', p_attempt_id,
                    'tenant_id', v_attempt.external_tenant_id,
                    'recovered_from_stale', true
                );
            ELSE
                RETURN jsonb_build_object(
                    'success', true,
                    'action', 'already_pending',
                    'analysis_id', v_existing.id,
                    'status', 'pending',
                    'message', 'Analysis is currently being generated.'
                );
            END IF;
        ELSIF v_existing.status = 'failed'::public.ai_analysis_status_enum THEN
            UPDATE public.ai_pedagogical_analyses
            SET status = 'pending'::public.ai_analysis_status_enum,
                error_message = NULL,
                updated_at = clock_timestamp()
            WHERE id = v_existing.id;

            RETURN jsonb_build_object(
                'success', true,
                'action', 'retry_initiated',
                'analysis_id', v_existing.id,
                'attempt_id', p_attempt_id,
                'tenant_id', v_attempt.external_tenant_id
            );
        END IF;
    END IF;

    INSERT INTO public.ai_pedagogical_analyses (
        attempt_id,
        external_tenant_id,
        status,
        pedagogical_feedback,
        strengths_weaknesses,
        updated_at
    ) VALUES (
        p_attempt_id,
        v_attempt.external_tenant_id,
        'pending'::public.ai_analysis_status_enum,
        '{}'::jsonb,
        '{}'::jsonb,
        clock_timestamp()
    );

    RETURN jsonb_build_object(
        'success', true,
        'action', 'ready_for_generation',
        'attempt_id', p_attempt_id,
        'tenant_id', v_attempt.external_tenant_id
    );
END;
$$;

REVOKE ALL ON FUNCTION private.initialize_pedagogical_analysis(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.initialize_pedagogical_analysis(UUID, UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.initialize_pedagogical_analysis(
    p_attempt_id UUID,
    p_caller_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN private.initialize_pedagogical_analysis(p_attempt_id, p_caller_id);
END;
$$;

REVOKE ALL ON FUNCTION public.initialize_pedagogical_analysis(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.initialize_pedagogical_analysis(UUID, UUID) TO service_role;



-- ============================================================
-- MIGRATION 6
-- Original file: supabase/migrations/20261003_phase8b2_core_security_rls.sql
-- ============================================================

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



-- ============================================================
-- MIGRATION 7
-- Original file: supabase/migrations/20261004_phase8b3_create_exam_attempt_atomic.sql
-- ============================================================

-- ============================================================================
-- PHASE 8B.3: Server-Side RPC Reconstruction
-- Standalone Arabic Exam & Assessment Module
-- RPC #1: create_exam_attempt_atomic(p_student_id UUID, p_exam_id UUID)
-- ============================================================================

CREATE OR REPLACE FUNCTION private.create_exam_attempt_atomic(
    p_student_id UUID,
    p_exam_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_auth_uid UUID;
    v_student RECORD;
    v_exam RECORD;
    v_existing_attempt RECORD;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_previous_attempts_count INTEGER := 0;
    v_next_attempt_number INTEGER := 1;
    v_new_attempt_id UUID;
    v_started_at TIMESTAMPTZ;
    v_expires_at TIMESTAMPTZ;
    v_section RECORD;
    v_sections_count INTEGER := 0;
    v_eligible_count INTEGER := 0;
    v_q RECORD;
    v_selected_question_ids UUID[] := ARRAY[]::UUID[];
    v_item_sort_order INTEGER := 0;
    v_frozen_options JSONB;
BEGIN
    v_auth_uid := (SELECT auth.uid());
    IF v_auth_uid IS NOT NULL AND v_auth_uid <> p_student_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'forbidden_student_id',
            'message', 'Authenticated user cannot create an attempt for another student.'
        );
    END IF;

    SELECT id, role, external_tenant_id
    INTO v_student
    FROM public.profiles
    WHERE id = p_student_id
    FOR UPDATE;

    IF v_student.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'profile_not_found',
            'message', 'Student profile does not exist.'
        );
    END IF;

    IF v_student.role <> 'student'::public.user_role_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invalid_role',
            'message', 'Only users with student role can start an exam attempt.'
        );
    END IF;

    IF v_student.external_tenant_id IS NULL OR v_student.external_tenant_id = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invalid_tenant',
            'message', 'Student profile does not possess a valid tenant association.'
        );
    END IF;

    SELECT id, external_tenant_id, status, duration_minutes, max_attempts
    INTO v_exam
    FROM public.exams
    WHERE id = p_exam_id;

    IF v_exam.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'exam_not_found',
            'message', 'Exam not found.'
        );
    END IF;

    IF v_exam.status <> 'approved'::public.content_status_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'exam_not_approved',
            'message', 'Exam is not in approved status.'
        );
    END IF;

    IF v_exam.external_tenant_id <> v_student.external_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_mismatch',
            'message', 'Cross-tenant exam access is strictly prohibited.'
        );
    END IF;

    IF v_exam.duration_minutes IS NULL OR v_exam.duration_minutes <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invalid_duration',
            'message', 'Exam duration must be greater than zero.'
        );
    END IF;

    IF v_exam.max_attempts IS NULL OR v_exam.max_attempts < 1 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invalid_max_attempts',
            'message', 'Exam max_attempts configuration must be at least 1.'
        );
    END IF;

    SELECT id, attempt_number, started_at, expires_at, status
    INTO v_existing_attempt
    FROM public.exam_attempts
    WHERE student_id = v_student.id
      AND exam_id = v_exam.id
      AND status = 'in_progress'::public.attempt_status_enum
    FOR UPDATE;

    IF v_existing_attempt.id IS NOT NULL THEN
        IF v_now < v_existing_attempt.expires_at THEN
            RETURN jsonb_build_object(
                'success', true,
                'resumed', true,
                'action', 'attempt_resumed',
                'attempt_id', v_existing_attempt.id,
                'exam_id', v_exam.id,
                'attempt_number', v_existing_attempt.attempt_number,
                'started_at', v_existing_attempt.started_at,
                'expires_at', v_existing_attempt.expires_at,
                'status', v_existing_attempt.status
            );
        ELSE
            UPDATE public.exam_attempts
            SET status = 'expired'::public.attempt_status_enum,
                completed_at = v_existing_attempt.expires_at,
                updated_at = v_now
            WHERE id = v_existing_attempt.id;
        END IF;
    END IF;

    SELECT count(*)
    INTO v_previous_attempts_count
    FROM public.exam_attempts
    WHERE student_id = v_student.id
      AND exam_id = v_exam.id;

    IF v_previous_attempts_count >= v_exam.max_attempts THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'max_attempts_reached',
            'message', 'Maximum attempts reached for this exam.',
            'max_attempts', v_exam.max_attempts,
            'previous_attempts_count', v_previous_attempts_count
        );
    END IF;

    v_next_attempt_number := v_previous_attempts_count + 1;

    SELECT count(*)
    INTO v_sections_count
    FROM public.exam_sections
    WHERE exam_id = v_exam.id;

    IF v_sections_count = 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'no_sections_defined',
            'message', 'Exam has no configured sections.'
        );
    END IF;

    FOR v_section IN
        SELECT id, sort_order, skill_id, allocated_questions_count
        FROM public.exam_sections
        WHERE exam_id = v_exam.id
        ORDER BY sort_order ASC
    LOOP
        SELECT count(*)
        INTO v_eligible_count
        FROM public.questions q
        WHERE q.status = 'approved'::public.content_status_enum
          AND q.is_current_version = true
          AND q.external_tenant_id = v_student.external_tenant_id
          AND (v_section.skill_id IS NULL OR q.skill_id = v_section.skill_id)
          AND (
              cardinality(v_selected_question_ids) = 0 
              OR NOT (q.id = ANY(v_selected_question_ids))
          );

        IF v_eligible_count < v_section.allocated_questions_count THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'insufficient_question_pool',
                'message', 'Not enough approved questions available in question pool for exam section.',
                'section_sort_order', v_section.sort_order,
                'required_count', v_section.allocated_questions_count,
                'available_count', v_eligible_count
            );
        END IF;

        FOR v_q IN
            SELECT q.id
            FROM public.questions q
            WHERE q.status = 'approved'::public.content_status_enum
              AND q.is_current_version = true
              AND q.external_tenant_id = v_student.external_tenant_id
              AND (v_section.skill_id IS NULL OR q.skill_id = v_section.skill_id)
              AND (
                  cardinality(v_selected_question_ids) = 0 
                  OR NOT (q.id = ANY(v_selected_question_ids))
              )
            ORDER BY md5(q.id::text || v_student.id::text || v_exam.id::text || v_next_attempt_number::text || v_section.id::text)
            LIMIT v_section.allocated_questions_count
        LOOP
            v_selected_question_ids := array_append(v_selected_question_ids, v_q.id);
        END LOOP;
    END LOOP;

    v_new_attempt_id := gen_random_uuid();
    v_started_at := clock_timestamp();
    v_expires_at := v_started_at + (v_exam.duration_minutes || ' minutes')::interval;

    INSERT INTO public.exam_attempts (
        id,
        exam_id,
        student_id,
        external_tenant_id,
        status,
        attempt_number,
        started_at,
        expires_at,
        completed_at,
        total_score,
        percentage_score,
        is_passed,
        placement_level_id,
        placement_status,
        final_scoring_status,
        created_at,
        updated_at
    ) VALUES (
        v_new_attempt_id,
        v_exam.id,
        v_student.id,
        v_student.external_tenant_id,
        'in_progress'::public.attempt_status_enum,
        v_next_attempt_number,
        v_started_at,
        v_expires_at,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        'pending'::public.placement_status_enum,
        'provisional'::public.scoring_status_enum,
        v_started_at,
        v_started_at
    );

    FOR v_section IN
        SELECT id, sort_order, skill_id, allocated_questions_count
        FROM public.exam_sections
        WHERE exam_id = v_exam.id
        ORDER BY sort_order ASC
    LOOP
        FOR v_q IN
            SELECT q.id, q.skill_id, q.question_type, q.question_text, q.default_score
            FROM public.questions q
            WHERE q.id = ANY(v_selected_question_ids)
              AND (v_section.skill_id IS NULL OR q.skill_id = v_section.skill_id)
            ORDER BY md5(q.id::text || v_student.id::text || v_exam.id::text || v_next_attempt_number::text || v_section.id::text)
        LOOP
            v_item_sort_order := v_item_sort_order + 1;

            SELECT jsonb_agg(
                jsonb_build_object(
                    'option_key', qo.option_key,
                    'option_text', qo.option_text,
                    'sort_order', qo.sort_order
                ) ORDER BY qo.sort_order ASC
            )
            INTO v_frozen_options
            FROM public.question_options qo
            WHERE qo.question_id = v_q.id;

            INSERT INTO public.attempt_items (
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
                sort_order,
                created_at,
                updated_at
            ) VALUES (
                gen_random_uuid(),
                v_new_attempt_id,
                v_q.id,
                v_q.skill_id,
                v_q.question_type,
                v_q.default_score,
                NULL,
                NULL,
                v_q.question_text,
                v_frozen_options,
                'not_required'::public.review_status_enum,
                v_item_sort_order,
                v_started_at,
                v_started_at
            );
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'resumed', false,
        'action', 'attempt_created',
        'attempt_id', v_new_attempt_id,
        'exam_id', v_exam.id,
        'attempt_number', v_next_attempt_number,
        'started_at', v_started_at,
        'expires_at', v_expires_at,
        'status', 'in_progress',
        'items_count', v_item_sort_order
    );
END;
$$;

REVOKE ALL ON FUNCTION private.create_exam_attempt_atomic(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.create_exam_attempt_atomic(UUID, UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.create_exam_attempt_atomic(
    p_student_id UUID,
    p_exam_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN private.create_exam_attempt_atomic(p_student_id, p_exam_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_exam_attempt_atomic(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_exam_attempt_atomic(UUID, UUID) TO service_role;



-- ============================================================
-- MIGRATION 8
-- Original file: supabase/migrations/20261004_phase8b3_rpc2_save_exam_answer_atomic.sql
-- ============================================================

-- ============================================================================
-- PHASE 8B.3: Server-Side RPC Reconstruction
-- Standalone Arabic Exam & Assessment Module
-- RPC #2: save_exam_answer_atomic(...)
-- Server-authoritative answer saving with timer, ownership, and validation
-- ============================================================================

CREATE OR REPLACE FUNCTION private.save_exam_answer_atomic(
    p_student_id UUID,
    p_attempt_id UUID,
    p_attempt_item_id UUID,
    p_selected_option_key TEXT DEFAULT NULL,
    p_text_response TEXT DEFAULT NULL,
    p_audio_storage_path TEXT DEFAULT NULL,
    p_audio_duration_seconds NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_auth_uid UUID;
    v_student RECORD;
    v_attempt RECORD;
    v_item RECORD;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_normalized_text TEXT;
    v_expected_audio_path TEXT;
    v_save_option_key VARCHAR(16) := NULL;
    v_save_text TEXT := NULL;
    v_save_audio_path TEXT := NULL;
    v_save_audio_duration NUMERIC(6,2) := NULL;
BEGIN
    v_auth_uid := (SELECT auth.uid());
    IF v_auth_uid IS NOT NULL AND v_auth_uid <> p_student_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'forbidden_student_id',
            'message', 'Authenticated user cannot save answers for another student.'
        );
    END IF;

    SELECT id, role, external_tenant_id
    INTO v_student
    FROM public.profiles
    WHERE id = p_student_id;

    IF v_student.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'student_profile_not_found',
            'message', 'Student profile does not exist.'
        );
    END IF;

    IF v_student.external_tenant_id IS NULL OR v_student.external_tenant_id = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_mismatch',
            'message', 'Student has no valid tenant association.'
        );
    END IF;

    SELECT id, student_id, exam_id, external_tenant_id, status, expires_at
    INTO v_attempt
    FROM public.exam_attempts
    WHERE id = p_attempt_id
    FOR UPDATE;

    IF v_attempt.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_not_found',
            'message', 'Exam attempt does not exist.'
        );
    END IF;

    IF v_attempt.student_id <> p_student_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_not_owned',
            'message', 'Student does not own this exam attempt.'
        );
    END IF;

    IF v_attempt.external_tenant_id <> v_student.external_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_mismatch',
            'message', 'Cross-tenant answer submission is strictly prohibited.'
        );
    END IF;

    IF v_attempt.status <> 'in_progress'::public.attempt_status_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_not_in_progress',
            'message', 'Answers can only be submitted for in-progress attempts.',
            'current_status', v_attempt.status
        );
    END IF;

    IF v_now >= v_attempt.expires_at THEN
        UPDATE public.exam_attempts
        SET status = 'expired'::public.attempt_status_enum,
            completed_at = v_attempt.expires_at,
            updated_at = v_now
        WHERE id = v_attempt.id;

        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_expired',
            'message', 'The exam attempt duration has expired. Answer cannot be saved.'
        );
    END IF;

    SELECT id, attempt_id, item_type, frozen_question_text, frozen_options
    INTO v_item
    FROM public.attempt_items
    WHERE id = p_attempt_item_id;

    IF v_item.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_item_not_found',
            'message', 'Attempt item does not exist.'
        );
    END IF;

    IF v_item.attempt_id <> p_attempt_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_item_mismatch',
            'message', 'Attempt item does not belong to the specified exam attempt.'
        );
    END IF;

    CASE v_item.item_type
        WHEN 'mcq'::public.question_type_enum, 'true_false'::public.question_type_enum THEN
            IF p_selected_option_key IS NULL OR trim(p_selected_option_key) = '' THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'missing_selected_option',
                    'message', 'Selected option key is required for multiple choice and true/false items.'
                );
            END IF;

            IF v_item.frozen_options IS NULL OR NOT EXISTS (
                SELECT 1
                FROM jsonb_array_elements(v_item.frozen_options) AS opt
                WHERE opt->>'option_key' = trim(p_selected_option_key)
            ) THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'invalid_selected_option',
                    'message', 'Selected option key is not a valid choice for this question.'
                );
            END IF;

            v_save_option_key := trim(p_selected_option_key)::VARCHAR(16);

        WHEN 'short_answer'::public.question_type_enum THEN
            IF p_text_response IS NULL THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'missing_text_response',
                    'message', 'Text response is required for short answer items.'
                );
            END IF;

            v_normalized_text := trim(regexp_replace(p_text_response, '\s+', ' ', 'g'));
            IF v_normalized_text = '' THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'missing_text_response',
                    'message', 'Text response cannot be empty.'
                );
            END IF;
            v_save_text := v_normalized_text;

        WHEN 'writing'::public.question_type_enum THEN
            IF p_text_response IS NULL THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'missing_text_response',
                    'message', 'Text response is required for writing items.'
                );
            END IF;

            v_normalized_text := trim(p_text_response);
            IF v_normalized_text = '' THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'missing_text_response',
                    'message', 'Writing response cannot be empty.'
                );
            END IF;
            v_save_text := v_normalized_text;

            UPDATE public.attempt_items
            SET review_status = 'pending_teacher_review'::public.review_status_enum,
                awarded_score = 0.00,
                is_correct = NULL,
                updated_at = v_now
            WHERE id = v_item.id;

        WHEN 'speaking'::public.question_type_enum THEN
            IF p_audio_storage_path IS NULL OR trim(p_audio_storage_path) = '' THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'missing_audio_storage_path',
                    'message', 'Audio storage path is required for speaking items.'
                );
            END IF;

            IF p_audio_duration_seconds IS NULL OR p_audio_duration_seconds <= 0 THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'invalid_audio_duration',
                    'message', 'Audio duration must be provided and greater than 0.'
                );
            END IF;

            v_expected_audio_path := v_student.external_tenant_id || '/' || 
                                     p_student_id::text || '/' || 
                                     p_attempt_id::text || '/' || 
                                     p_attempt_item_id::text || '.webm';

            IF trim(p_audio_storage_path) <> v_expected_audio_path THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'invalid_audio_storage_path',
                    'message', 'Audio storage path does not conform to the required tenant/attempt path hierarchy.'
                );
            END IF;

            IF EXISTS (
                SELECT 1 
                FROM information_schema.tables 
                WHERE table_schema = 'storage' AND table_name = 'objects'
            ) THEN
                IF NOT EXISTS (
                    SELECT 1 
                    FROM storage.objects
                    WHERE bucket_id = 'student-recordings'
                      AND name = trim(p_audio_storage_path)
                ) THEN
                    RETURN jsonb_build_object(
                        'success', false,
                        'error', 'audio_object_not_found',
                        'message', 'Audio recording object does not exist in student-recordings storage.'
                    );
                END IF;
            END IF;

            v_save_audio_path := trim(p_audio_storage_path);
            v_save_audio_duration := p_audio_duration_seconds::NUMERIC(6,2);

            UPDATE public.attempt_items
            SET review_status = 'pending_teacher_review'::public.review_status_enum,
                awarded_score = 0.00,
                is_correct = NULL,
                updated_at = v_now
            WHERE id = v_item.id;

        WHEN 'listening'::public.question_type_enum THEN
            IF v_item.frozen_options IS NOT NULL AND jsonb_array_length(v_item.frozen_options) > 0 THEN
                IF p_selected_option_key IS NULL OR trim(p_selected_option_key) = '' THEN
                    RETURN jsonb_build_object(
                        'success', false,
                        'error', 'missing_selected_option',
                        'message', 'Selected option key is required for this listening item.'
                    );
                END IF;

                IF NOT EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(v_item.frozen_options) AS opt
                    WHERE opt->>'option_key' = trim(p_selected_option_key)
                ) THEN
                    RETURN jsonb_build_object(
                        'success', false,
                        'error', 'invalid_selected_option',
                        'message', 'Selected option key is invalid for this listening item.'
                    );
                END IF;
                v_save_option_key := trim(p_selected_option_key)::VARCHAR(16);
            ELSE
                IF p_text_response IS NULL OR trim(p_text_response) = '' THEN
                    RETURN jsonb_build_object(
                        'success', false,
                        'error', 'missing_text_response',
                        'message', 'Text response is required for this listening item.'
                    );
                END IF;
                v_save_text := trim(p_text_response);
            END IF;

        ELSE
            RETURN jsonb_build_object(
                'success', false,
                'error', 'unsupported_question_type',
                'message', 'Unsupported question type for answer submission.'
            );
    END CASE;

    INSERT INTO public.attempt_answers (
        id,
        attempt_item_id,
        selected_option_key,
        text_response,
        audio_storage_path,
        audio_duration_seconds,
        created_at,
        updated_at
    ) VALUES (
        gen_random_uuid(),
        p_attempt_item_id,
        v_save_option_key,
        v_save_text,
        v_save_audio_path,
        v_save_audio_duration,
        v_now,
        v_now
    )
    ON CONFLICT (attempt_item_id) DO UPDATE SET
        selected_option_key = EXCLUDED.selected_option_key,
        text_response = EXCLUDED.text_response,
        audio_storage_path = EXCLUDED.audio_storage_path,
        audio_duration_seconds = EXCLUDED.audio_duration_seconds,
        updated_at = v_now;

    RETURN jsonb_build_object(
        'success', true,
        'saved', true,
        'attempt_id', p_attempt_id,
        'attempt_item_id', p_attempt_item_id,
        'updated_at', v_now
    );
END;
$$;

REVOKE ALL ON FUNCTION private.save_exam_answer_atomic(UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.save_exam_answer_atomic(UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC) TO service_role;

CREATE OR REPLACE FUNCTION public.save_exam_answer_atomic(
    p_student_id UUID,
    p_attempt_id UUID,
    p_attempt_item_id UUID,
    p_selected_option_key TEXT DEFAULT NULL,
    p_text_response TEXT DEFAULT NULL,
    p_audio_storage_path TEXT DEFAULT NULL,
    p_audio_duration_seconds NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN private.save_exam_answer_atomic(
        p_student_id,
        p_attempt_id,
        p_attempt_item_id,
        p_selected_option_key,
        p_text_response,
        p_audio_storage_path,
        p_audio_duration_seconds
    );
END;
$$;

REVOKE ALL ON FUNCTION public.save_exam_answer_atomic(UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_exam_answer_atomic(UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC) TO service_role;



-- ============================================================
-- MIGRATION 9
-- Original file: supabase/migrations/20261004_phase8b3_rpc3_submit_and_grade_exam_attempt_atomic.sql
-- ============================================================

-- ============================================================================
-- PHASE 8B.3: Server-Side RPC Reconstruction
-- Standalone Arabic Exam & Assessment Module
-- RPC #3: submit_and_grade_exam_attempt_atomic(p_student_id UUID, p_attempt_id UUID)
-- Atomic Exam Submission, Multi-Type Auto-Grading & Score Finalization
-- ============================================================================

CREATE OR REPLACE FUNCTION private.submit_and_grade_exam_attempt_atomic(
    p_student_id UUID,
    p_attempt_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_auth_uid UUID;
    v_student RECORD;
    v_attempt RECORD;
    v_exam RECORD;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_item RECORD;
    v_qa RECORD;
    v_item_is_correct BOOLEAN;
    v_item_awarded_score NUMERIC(5,2);
    v_item_review_status public.review_status_enum;
    v_has_pending_reviews BOOLEAN := false;
    v_total_allocated NUMERIC(6,2) := 0.00;
    v_total_awarded NUMERIC(6,2) := 0.00;
    v_total_score NUMERIC(6,2) := 0.00;
    v_percentage_score NUMERIC(5,2) := 0.00;
    v_is_passed BOOLEAN := NULL;
    v_scoring_status public.scoring_status_enum;
    v_processed_student TEXT;
    v_accepted_text TEXT;
    v_processed_accepted TEXT;
    v_text_matched BOOLEAN;
    v_final_attempt_status public.attempt_status_enum;
BEGIN
    v_auth_uid := (SELECT auth.uid());
    IF p_student_id IS NULL THEN
        IF v_auth_uid IS NOT NULL THEN
            p_student_id := v_auth_uid;
        ELSE
            SELECT student_id INTO p_student_id
            FROM public.exam_attempts
            WHERE id = p_attempt_id;
        END IF;
    END IF;

    IF v_auth_uid IS NOT NULL AND v_auth_uid <> p_student_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'forbidden_student_id',
            'message', 'Authenticated user cannot submit an exam attempt for another student.'
        );
    END IF;

    SELECT id, role, external_tenant_id
    INTO v_student
    FROM public.profiles
    WHERE id = p_student_id;

    IF v_student.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'student_profile_not_found',
            'message', 'Student profile does not exist.'
        );
    END IF;

    IF v_student.external_tenant_id IS NULL OR v_student.external_tenant_id = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_mismatch',
            'message', 'Student profile does not possess a valid tenant association.'
        );
    END IF;

    SELECT 
        id, 
        student_id, 
        exam_id, 
        external_tenant_id, 
        status, 
        started_at, 
        expires_at, 
        completed_at, 
        total_score, 
        percentage_score, 
        is_passed, 
        placement_level_id, 
        placement_status, 
        final_scoring_status
    INTO v_attempt
    FROM public.exam_attempts
    WHERE id = p_attempt_id
    FOR UPDATE;

    IF v_attempt.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_not_found',
            'message', 'Exam attempt does not exist.'
        );
    END IF;

    IF v_attempt.student_id <> p_student_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_not_owned',
            'message', 'Student does not own this exam attempt.'
        );
    END IF;

    IF v_attempt.external_tenant_id <> v_student.external_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_mismatch',
            'message', 'Cross-tenant exam submission is strictly prohibited.'
        );
    END IF;

    IF v_attempt.status = 'completed'::public.attempt_status_enum THEN
        RETURN jsonb_build_object(
            'success', true,
            'action', 'already_submitted',
            'attempt_id', v_attempt.id,
            'exam_id', v_attempt.exam_id,
            'student_id', v_attempt.student_id,
            'status', v_attempt.status,
            'final_scoring_status', v_attempt.final_scoring_status,
            'total_score', v_attempt.total_score,
            'percentage_score', v_attempt.percentage_score,
            'is_passed', v_attempt.is_passed,
            'placement_status', v_attempt.placement_status,
            'placement_level_id', v_attempt.placement_level_id,
            'completed_at', v_attempt.completed_at
        );
    END IF;

    IF v_attempt.status = 'expired'::public.attempt_status_enum AND v_attempt.total_score IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', true,
            'action', 'already_submitted',
            'attempt_id', v_attempt.id,
            'exam_id', v_attempt.exam_id,
            'student_id', v_attempt.student_id,
            'status', v_attempt.status,
            'final_scoring_status', v_attempt.final_scoring_status,
            'total_score', v_attempt.total_score,
            'percentage_score', v_attempt.percentage_score,
            'is_passed', v_attempt.is_passed,
            'placement_status', v_attempt.placement_status,
            'placement_level_id', v_attempt.placement_level_id,
            'completed_at', v_attempt.completed_at
        );
    END IF;

    IF v_attempt.status <> 'in_progress'::public.attempt_status_enum AND v_attempt.status <> 'expired'::public.attempt_status_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invalid_attempt_status',
            'message', 'Exam attempt cannot be submitted in its current status.',
            'current_status', v_attempt.status
        );
    END IF;

    SELECT id, external_tenant_id, title, exam_type, status, duration_minutes, passing_score_percentage, scoring_policy
    INTO v_exam
    FROM public.exams
    WHERE id = v_attempt.exam_id;

    IF v_exam.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'exam_not_found',
            'message', 'Referenced exam does not exist.'
        );
    END IF;

    FOR v_item IN
        SELECT 
            ai.id, 
            ai.question_id, 
            ai.skill_id, 
            ai.item_type, 
            ai.allocated_score,
            ai.review_status,
            ans.selected_option_key,
            ans.text_response,
            ans.audio_storage_path,
            ans.audio_duration_seconds
        FROM public.attempt_items ai
        LEFT JOIN public.attempt_answers ans ON ans.attempt_item_id = ai.id
        WHERE ai.attempt_id = v_attempt.id
        ORDER BY ai.sort_order ASC
    LOOP
        SELECT correct_option_key, accepted_text_answers, explanation
        INTO v_qa
        FROM public.question_answers
        WHERE question_id = v_item.question_id;

        v_item_is_correct := false;
        v_item_awarded_score := 0.00;
        v_item_review_status := 'not_required'::public.review_status_enum;

        CASE v_item.item_type
            WHEN 'mcq'::public.question_type_enum, 'true_false'::public.question_type_enum THEN
                IF v_item.selected_option_key IS NOT NULL
                    AND v_qa.correct_option_key IS NOT NULL
                    AND trim(v_item.selected_option_key) = trim(v_qa.correct_option_key) THEN
                    v_item_is_correct := true;
                    v_item_awarded_score := v_item.allocated_score;
                ELSE
                    v_item_is_correct := false;
                    v_item_awarded_score := 0.00;
                END IF;
                v_item_review_status := 'not_required'::public.review_status_enum;

            WHEN 'short_answer'::public.question_type_enum THEN
                v_text_matched := false;
                IF v_item.text_response IS NOT NULL AND trim(v_item.text_response) <> '' THEN
                    v_processed_student := trim(regexp_replace(v_item.text_response, '\s+', ' ', 'g'));
                    IF v_qa.correct_option_key IS NOT NULL THEN
                        v_processed_accepted := trim(regexp_replace(v_qa.correct_option_key, '\s+', ' ', 'g'));
                        IF v_processed_student = v_processed_accepted THEN
                            v_text_matched := true;
                        END IF;
                    END IF;
                    IF NOT v_text_matched AND v_qa.accepted_text_answers IS NOT NULL AND jsonb_typeof(v_qa.accepted_text_answers) = 'array' THEN
                        FOR v_accepted_text IN SELECT jsonb_array_elements_text(v_qa.accepted_text_answers)
                        LOOP
                            v_processed_accepted := trim(regexp_replace(v_accepted_text, '\s+', ' ', 'g'));
                            IF v_processed_student = v_processed_accepted THEN
                                v_text_matched := true;
                                EXIT;
                            END IF;
                        END LOOP;
                    END IF;
                END IF;

                IF v_text_matched THEN
                    v_item_is_correct := true;
                    v_item_awarded_score := v_item.allocated_score;
                ELSE
                    v_item_is_correct := false;
                    v_item_awarded_score := 0.00;
                END IF;
                v_item_review_status := 'not_required'::public.review_status_enum;

            WHEN 'listening'::public.question_type_enum THEN
                IF v_item.selected_option_key IS NOT NULL THEN
                    IF v_qa.correct_option_key IS NOT NULL
                        AND trim(v_item.selected_option_key) = trim(v_qa.correct_option_key) THEN
                        v_item_is_correct := true;
                        v_item_awarded_score := v_item.allocated_score;
                    ELSE
                        v_item_is_correct := false;
                        v_item_awarded_score := 0.00;
                    END IF;
                ELSE
                    v_text_matched := false;
                    IF v_item.text_response IS NOT NULL AND trim(v_item.text_response) <> '' THEN
                        v_processed_student := trim(regexp_replace(v_item.text_response, '\s+', ' ', 'g'));
                        IF v_qa.correct_option_key IS NOT NULL THEN
                            v_processed_accepted := trim(regexp_replace(v_qa.correct_option_key, '\s+', ' ', 'g'));
                            IF v_processed_student = v_processed_accepted THEN
                                v_text_matched := true;
                            END IF;
                        END IF;
                        IF NOT v_text_matched AND v_qa.accepted_text_answers IS NOT NULL AND jsonb_typeof(v_qa.accepted_text_answers) = 'array' THEN
                            FOR v_accepted_text IN SELECT jsonb_array_elements_text(v_qa.accepted_text_answers)
                            LOOP
                                v_processed_accepted := trim(regexp_replace(v_accepted_text, '\s+', ' ', 'g'));
                                IF v_processed_student = v_processed_accepted THEN
                                    v_text_matched := true;
                                    EXIT;
                                END IF;
                            END LOOP;
                        END IF;
                    END IF;

                    IF v_text_matched THEN
                        v_item_is_correct := true;
                        v_item_awarded_score := v_item.allocated_score;
                    ELSE
                        v_item_is_correct := false;
                        v_item_awarded_score := 0.00;
                    END IF;
                END IF;
                v_item_review_status := 'not_required'::public.review_status_enum;

            WHEN 'writing'::public.question_type_enum THEN
                IF v_item.text_response IS NOT NULL AND trim(v_item.text_response) <> '' THEN
                    v_item_is_correct := NULL;
                    v_item_awarded_score := 0.00;
                    v_item_review_status := 'pending_teacher_review'::public.review_status_enum;
                    v_has_pending_reviews := true;
                ELSE
                    v_item_is_correct := false;
                    v_item_awarded_score := 0.00;
                    v_item_review_status := 'not_required'::public.review_status_enum;
                END IF;

            WHEN 'speaking'::public.question_type_enum THEN
                IF v_item.audio_storage_path IS NOT NULL AND trim(v_item.audio_storage_path) <> '' THEN
                    v_item_is_correct := NULL;
                    v_item_awarded_score := 0.00;
                    v_item_review_status := 'pending_teacher_review'::public.review_status_enum;
                    v_has_pending_reviews := true;
                ELSE
                    v_item_is_correct := false;
                    v_item_awarded_score := 0.00;
                    v_item_review_status := 'not_required'::public.review_status_enum;
                END IF;

            ELSE
                v_item_is_correct := false;
                v_item_awarded_score := 0.00;
                v_item_review_status := 'not_required'::public.review_status_enum;
        END CASE;

        UPDATE public.attempt_items
        SET awarded_score = v_item_awarded_score,
            is_correct = v_item_is_correct,
            review_status = v_item_review_status,
            updated_at = v_now
        WHERE id = v_item.id;

        v_total_allocated := v_total_allocated + v_item.allocated_score;
        v_total_awarded := v_total_awarded + v_item_awarded_score;
    END LOOP;

    v_total_score := v_total_awarded;

    IF v_exam.scoring_policy = 'weighted' AND EXISTS (
        SELECT 1 FROM public.exam_skill_weights WHERE exam_id = v_exam.id
    ) THEN
        SELECT COALESCE(
            ROUND(
                SUM(
                    CASE 
                        WHEN skill_stats.allocated > 0 THEN 
                            (skill_stats.awarded / skill_stats.allocated) * esw.weight_percentage
                        ELSE 0.00
                    END
                ),
                2
            ),
            0.00
        )
        INTO v_percentage_score
        FROM public.exam_skill_weights esw
        LEFT JOIN (
            SELECT 
                ai.skill_id,
                SUM(ai.allocated_score) AS allocated,
                SUM(COALESCE(ai.awarded_score, 0.00)) AS awarded
            FROM public.attempt_items ai
            WHERE ai.attempt_id = v_attempt.id
            GROUP BY ai.skill_id
        ) skill_stats ON skill_stats.skill_id = esw.skill_id
        WHERE esw.exam_id = v_exam.id;
    ELSE
        IF v_total_allocated > 0 THEN
            v_percentage_score := ROUND((v_total_awarded / v_total_allocated) * 100.00, 2);
        ELSE
            v_percentage_score := 0.00;
        END IF;
    END IF;

    v_percentage_score := GREATEST(0.00, LEAST(100.00, v_percentage_score));

    IF v_has_pending_reviews THEN
        v_scoring_status := 'provisional'::public.scoring_status_enum;
    ELSE
        v_scoring_status := 'official_final'::public.scoring_status_enum;
    END IF;

    IF v_scoring_status = 'official_final'::public.scoring_status_enum THEN
        v_is_passed := (v_percentage_score >= v_exam.passing_score_percentage);
    ELSE
        v_is_passed := NULL;
    END IF;

    v_final_attempt_status := 'completed'::public.attempt_status_enum;

    UPDATE public.exam_attempts
    SET status = v_final_attempt_status,
        completed_at = COALESCE(v_attempt.completed_at, v_now),
        total_score = v_total_score,
        percentage_score = v_percentage_score,
        is_passed = v_is_passed,
        placement_level_id = NULL,
        placement_status = v_attempt.placement_status,
        final_scoring_status = v_scoring_status,
        updated_at = v_now
    WHERE id = v_attempt.id;

    RETURN jsonb_build_object(
        'success', true,
        'action', 'submitted_and_graded',
        'attempt_id', v_attempt.id,
        'exam_id', v_exam.id,
        'student_id', v_student.id,
        'status', v_final_attempt_status,
        'final_scoring_status', v_scoring_status,
        'total_score', v_total_score,
        'percentage_score', v_percentage_score,
        'is_passed', v_is_passed,
        'placement_status', v_attempt.placement_status,
        'placement_level_id', NULL,
        'has_pending_teacher_reviews', v_has_pending_reviews,
        'completed_at', COALESCE(v_attempt.completed_at, v_now)
    );
END;
$$;

REVOKE ALL ON FUNCTION private.submit_and_grade_exam_attempt_atomic(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.submit_and_grade_exam_attempt_atomic(UUID, UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.submit_and_grade_exam_attempt_atomic(
    p_student_id UUID,
    p_attempt_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN private.submit_and_grade_exam_attempt_atomic(p_student_id, p_attempt_id);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_and_grade_exam_attempt_atomic(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_and_grade_exam_attempt_atomic(UUID, UUID) TO service_role;



-- ============================================================
-- MIGRATION 10
-- Original file: supabase/migrations/20261004_phase8b11_restore_teacher_review_and_official_result.sql
-- ============================================================

-- ============================================================================
-- PHASE 8B.11: RESTORE TEACHER REVIEW, OFFICIAL RESULT & PLACEMENT CONTRACTS
-- ============================================================================

CREATE OR REPLACE FUNCTION private.recalculate_and_finalize_attempt_atomic(
    p_attempt_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_attempt RECORD;
    v_total_allocated NUMERIC(6,2) := 0.00;
    v_total_awarded NUMERIC(6,2) := 0.00;
    v_percentage_score NUMERIC(5,2) := 0.00;
    v_is_passed BOOLEAN := NULL;
    v_matched_placement_level_id UUID := NULL;
    v_placement_status public.placement_status_enum := 'pending';
    v_level_matches BOOLEAN;
    v_student_skill_pct NUMERIC(5,2);
    r_level RECORD;
    r_overall_rule RECORD;
    r_skill_rule RECORD;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    SELECT ea.*, e.scoring_policy, e.passing_score_percentage, e.exam_type
    INTO v_attempt
    FROM public.exam_attempts ea
    JOIN public.exams e ON e.id = ea.exam_id
    WHERE ea.id = p_attempt_id
    FOR UPDATE OF ea;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_not_found',
            'message', 'Exam attempt does not exist.'
        );
    END IF;

    IF v_attempt.final_scoring_status = 'official_final'::public.scoring_status_enum THEN
        RETURN jsonb_build_object(
            'success', true,
            'action', 'already_finalized',
            'attempt_id', p_attempt_id,
            'final_scoring_status', 'official_final',
            'total_score', v_attempt.total_score,
            'percentage_score', v_attempt.percentage_score,
            'is_passed', v_attempt.is_passed,
            'placement_level_id', v_attempt.placement_level_id,
            'placement_status', v_attempt.placement_status
        );
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.attempt_items
        WHERE attempt_id = p_attempt_id
          AND review_status = 'pending_teacher_review'::public.review_status_enum
    ) THEN
        RETURN jsonb_build_object(
            'success', true,
            'action', 'still_pending_reviews',
            'attempt_id', p_attempt_id,
            'final_scoring_status', 'provisional'
        );
    END IF;

    SELECT 
        COALESCE(SUM(ai.allocated_score), 0.00),
        COALESCE(SUM(COALESCE(ai.awarded_score, 0.00)), 0.00)
    INTO v_total_allocated, v_total_awarded
    FROM public.attempt_items ai
    WHERE ai.attempt_id = p_attempt_id;

    IF v_attempt.scoring_policy = 'weighted' AND EXISTS (
        SELECT 1 FROM public.exam_skill_weights WHERE exam_id = v_attempt.exam_id
    ) THEN
        SELECT COALESCE(
            ROUND(
                SUM(
                    CASE 
                        WHEN skill_stats.allocated > 0 THEN 
                            (skill_stats.awarded / skill_stats.allocated) * esw.weight_percentage
                        ELSE 0.00
                    END
                ),
                2
            ),
            0.00
        )
        INTO v_percentage_score
        FROM public.exam_skill_weights esw
        LEFT JOIN (
            SELECT 
                ai.skill_id,
                SUM(ai.allocated_score) AS allocated,
                SUM(COALESCE(ai.awarded_score, 0.00)) AS awarded
            FROM public.attempt_items ai
            WHERE ai.attempt_id = p_attempt_id
            GROUP BY ai.skill_id
        ) skill_stats ON skill_stats.skill_id = esw.skill_id
        WHERE esw.exam_id = v_attempt.exam_id;
    ELSE
        IF v_total_allocated > 0 THEN
            v_percentage_score := ROUND((v_total_awarded / v_total_allocated) * 100.00, 2);
        ELSE
            v_percentage_score := 0.00;
        END IF;
    END IF;

    v_percentage_score := GREATEST(0.00, LEAST(100.00, v_percentage_score));
    v_is_passed := (v_percentage_score >= v_attempt.passing_score_percentage);

    IF v_attempt.exam_type = 'placement'::public.exam_type_enum OR EXISTS (
        SELECT 1 FROM public.placement_level_rules
        WHERE external_tenant_id = v_attempt.external_tenant_id AND is_active = true
    ) THEN
        v_placement_status := 'review_required'::public.placement_status_enum;

        FOR r_level IN (
            SELECT pl.id, pl.rank_order
            FROM public.proficiency_levels pl
            WHERE EXISTS (
                SELECT 1 FROM public.placement_level_rules plr
                WHERE plr.proficiency_level_id = pl.id
                  AND plr.external_tenant_id = v_attempt.external_tenant_id
                  AND plr.is_active = true
            )
            ORDER BY pl.rank_order DESC
        ) LOOP
            SELECT * INTO r_overall_rule
            FROM public.placement_level_rules
            WHERE external_tenant_id = v_attempt.external_tenant_id
              AND proficiency_level_id = r_level.id
              AND skill_id IS NULL
              AND is_active = true
            LIMIT 1;

            v_level_matches := false;
            IF FOUND THEN
                IF v_percentage_score >= r_overall_rule.min_percentage AND (
                    (r_overall_rule.max_percentage = 100.00 AND v_percentage_score <= 100.00) OR
                    (r_overall_rule.max_percentage < 100.00 AND v_percentage_score < r_overall_rule.max_percentage)
                ) THEN
                    v_level_matches := true;

                    FOR r_skill_rule IN (
                        SELECT * FROM public.placement_level_rules
                        WHERE external_tenant_id = v_attempt.external_tenant_id
                          AND proficiency_level_id = r_level.id
                          AND skill_id IS NOT NULL
                          AND is_active = true
                    ) LOOP
                        SELECT 
                            CASE 
                                WHEN SUM(ai.allocated_score) > 0 THEN
                                    ROUND((SUM(COALESCE(ai.awarded_score, 0.00)) / SUM(ai.allocated_score)) * 100.00, 2)
                                ELSE 0.00
                            END
                        INTO v_student_skill_pct
                        FROM public.attempt_items ai
                        WHERE ai.attempt_id = p_attempt_id
                          AND ai.skill_id = r_skill_rule.skill_id;

                        IF v_student_skill_pct < r_skill_rule.min_percentage THEN
                            v_level_matches := false;
                            EXIT;
                        END IF;
                    END LOOP;
                END IF;
            END IF;

            IF v_level_matches THEN
                v_matched_placement_level_id := r_level.id;
                v_placement_status := 'assigned'::public.placement_status_enum;
                EXIT;
            END IF;
        END LOOP;
    ELSE
        v_matched_placement_level_id := NULL;
        v_placement_status := 'pending'::public.placement_status_enum;
    END IF;

    UPDATE public.exam_attempts
    SET total_score = v_total_awarded,
        percentage_score = v_percentage_score,
        is_passed = v_is_passed,
        final_scoring_status = 'official_final'::public.scoring_status_enum,
        placement_level_id = v_matched_placement_level_id,
        placement_status = v_placement_status,
        updated_at = v_now
    WHERE id = p_attempt_id;

    RETURN jsonb_build_object(
        'success', true,
        'action', 'finalized',
        'attempt_id', p_attempt_id,
        'final_scoring_status', 'official_final',
        'total_score', v_total_awarded,
        'percentage_score', v_percentage_score,
        'is_passed', v_is_passed,
        'placement_level_id', v_matched_placement_level_id,
        'placement_status', v_placement_status
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_teacher_review_atomic(
    p_attempt_item_id UUID,
    p_teacher_id UUID,
    p_assigned_score NUMERIC,
    p_feedback_text TEXT DEFAULT NULL,
    p_is_finalized BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_teacher RECORD;
    v_item RECORD;
    v_existing_review RECORD;
    v_review_id UUID;
    v_finalize_result JSONB;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_finalized_at TIMESTAMPTZ := NULL;
BEGIN
    SELECT p.* INTO v_teacher
    FROM public.profiles p
    WHERE p.id = p_teacher_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'teacher_profile_not_found',
            'message', 'Teacher profile does not exist.'
        );
    END IF;

    IF v_teacher.role <> 'teacher'::public.user_role_enum AND v_teacher.role <> 'admin'::public.user_role_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'teacher_not_authorized',
            'message', 'User does not possess teacher or administrator privileges.'
        );
    END IF;

    IF v_teacher.external_tenant_id IS NULL OR trim(v_teacher.external_tenant_id) = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_mismatch',
            'message', 'Teacher profile has no external tenant assigned.'
        );
    END IF;

    SELECT 
        ai.id,
        ai.attempt_id,
        ai.item_type,
        ai.allocated_score,
        ai.review_status,
        ea.external_tenant_id AS attempt_tenant_id,
        ea.status AS attempt_status,
        ea.final_scoring_status
    INTO v_item
    FROM public.attempt_items ai
    JOIN public.exam_attempts ea ON ea.id = ai.attempt_id
    WHERE ai.id = p_attempt_item_id
    FOR UPDATE OF ai;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_item_not_found',
            'message', 'Attempt item does not exist.'
        );
    END IF;

    IF v_teacher.external_tenant_id <> v_item.attempt_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_mismatch',
            'message', 'Cross-tenant teacher review access prohibited.'
        );
    END IF;

    IF v_item.item_type <> 'writing'::public.question_type_enum AND v_item.item_type <> 'speaking'::public.question_type_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'review_not_required',
            'message', 'Teacher review is only applicable for writing and speaking items.'
        );
    END IF;

    IF v_item.attempt_status <> 'completed'::public.attempt_status_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invalid_attempt_status',
            'message', 'Teacher review is only permitted on submitted completed exam attempts.'
        );
    END IF;

    IF v_item.final_scoring_status = 'official_final'::public.scoring_status_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'already_finalized',
            'message', 'Attempt has already been officially finalized; review modification is locked.'
        );
    END IF;

    SELECT tr.* INTO v_existing_review
    FROM public.teacher_reviews tr
    WHERE tr.attempt_item_id = p_attempt_item_id;

    IF FOUND AND v_existing_review.is_finalized = true THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'review_already_finalized',
            'message', 'A finalized teacher review already exists for this item and cannot be modified.'
        );
    END IF;

    IF p_assigned_score IS NULL OR p_assigned_score < 0.00 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invalid_score',
            'message', 'Assigned score must be a non-negative number.'
        );
    END IF;

    IF p_assigned_score > v_item.allocated_score THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'score_exceeds_allocated',
            'message', 'Assigned score cannot exceed the item allocated score.'
        );
    END IF;

    IF p_is_finalized THEN
        v_finalized_at := v_now;
    END IF;

    INSERT INTO public.teacher_reviews (
        attempt_item_id,
        teacher_id,
        assigned_score,
        feedback_text,
        is_finalized,
        finalized_at,
        created_at,
        updated_at
    ) VALUES (
        p_attempt_item_id,
        p_teacher_id,
        p_assigned_score,
        p_feedback_text,
        p_is_finalized,
        v_finalized_at,
        v_now,
        v_now
    )
    ON CONFLICT (attempt_item_id) DO UPDATE
    SET teacher_id = EXCLUDED.teacher_id,
        assigned_score = EXCLUDED.assigned_score,
        feedback_text = EXCLUDED.feedback_text,
        is_finalized = EXCLUDED.is_finalized,
        finalized_at = EXCLUDED.finalized_at,
        updated_at = v_now
    RETURNING id INTO v_review_id;

    IF p_is_finalized THEN
        UPDATE public.attempt_items
        SET awarded_score = p_assigned_score,
            is_correct = (p_assigned_score > 0),
            review_status = 'completed'::public.review_status_enum,
            updated_at = v_now
        WHERE id = p_attempt_item_id;

        v_finalize_result := private.recalculate_and_finalize_attempt_atomic(v_item.attempt_id);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'action', 'review_recorded',
        'review_id', v_review_id,
        'attempt_id', v_item.attempt_id,
        'attempt_item_id', p_attempt_item_id,
        'assigned_score', p_assigned_score,
        'is_finalized', p_is_finalized,
        'finalized_at', v_finalized_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_student_official_result(
    p_student_id UUID,
    p_attempt_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_student RECORD;
    v_attempt RECORD;
    v_placement_level_obj JSONB := NULL;
BEGIN
    SELECT p.* INTO v_student
    FROM public.profiles p
    WHERE p.id = p_student_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'student_profile_not_found',
            'message', 'Student profile does not exist.'
        );
    END IF;

    SELECT 
        ea.id,
        ea.exam_id,
        ea.student_id,
        ea.external_tenant_id,
        ea.status,
        ea.final_scoring_status,
        ea.total_score,
        ea.percentage_score,
        ea.is_passed,
        ea.placement_level_id,
        ea.placement_status,
        ea.completed_at,
        e.title AS exam_title
    INTO v_attempt
    FROM public.exam_attempts ea
    JOIN public.exams e ON e.id = ea.exam_id
    WHERE ea.id = p_attempt_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_not_found',
            'message', 'Exam attempt does not exist.'
        );
    END IF;

    IF v_attempt.student_id <> p_student_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_not_owned',
            'message', 'Attempt does not belong to the authenticated student.'
        );
    END IF;

    IF v_attempt.external_tenant_id <> v_student.external_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_mismatch',
            'message', 'Cross-tenant access prohibited.'
        );
    END IF;

    IF v_attempt.final_scoring_status <> 'official_final'::public.scoring_status_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'attempt_not_finalized',
            'message', 'Exam attempt result is still provisional and has not been officially finalized.',
            'final_scoring_status', v_attempt.final_scoring_status
        );
    END IF;

    IF v_attempt.placement_level_id IS NOT NULL THEN
        SELECT jsonb_build_object(
            'code', pl.code,
            'name_ar', pl.name_ar
        )
        INTO v_placement_level_obj
        FROM public.proficiency_levels pl
        WHERE pl.id = v_attempt.placement_level_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'attempt_id', v_attempt.id,
        'exam_id', v_attempt.exam_id,
        'exam_title', v_attempt.exam_title,
        'final_scoring_status', 'official_final',
        'total_score', v_attempt.total_score,
        'percentage_score', v_attempt.percentage_score,
        'is_passed', v_attempt.is_passed,
        'placement_level_id', v_attempt.placement_level_id,
        'placement_status', v_attempt.placement_status,
        'completed_at', v_attempt.completed_at,
        'placement_level', v_placement_level_obj
    );
END;
$$;

REVOKE ALL ON FUNCTION private.recalculate_and_finalize_attempt_atomic(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.recalculate_and_finalize_attempt_atomic(UUID) TO service_role;

REVOKE ALL ON FUNCTION public.submit_teacher_review_atomic(UUID, UUID, NUMERIC, TEXT, BOOLEAN) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_teacher_review_atomic(UUID, UUID, NUMERIC, TEXT, BOOLEAN) TO service_role;

REVOKE ALL ON FUNCTION public.get_student_official_result(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_student_official_result(UUID, UUID) TO service_role;


