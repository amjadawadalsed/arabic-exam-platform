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
