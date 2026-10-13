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
