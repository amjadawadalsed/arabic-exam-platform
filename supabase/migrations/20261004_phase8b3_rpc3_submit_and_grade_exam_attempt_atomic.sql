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
