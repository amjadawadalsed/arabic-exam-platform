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
