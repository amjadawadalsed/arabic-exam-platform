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
