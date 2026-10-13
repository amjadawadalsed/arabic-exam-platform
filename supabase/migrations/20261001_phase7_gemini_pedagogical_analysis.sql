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
