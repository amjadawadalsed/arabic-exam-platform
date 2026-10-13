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
