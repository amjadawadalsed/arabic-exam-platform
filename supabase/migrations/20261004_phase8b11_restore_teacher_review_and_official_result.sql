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
