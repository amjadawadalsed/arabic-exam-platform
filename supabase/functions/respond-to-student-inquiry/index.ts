// supabase/functions/respond-to-student-inquiry/index.ts
// PHASE 8B.9: Edge Function #6 - Respond to Student Inquiry
// Server-authoritative teacher identity, strict role/tenant verification,
// inquiry lifecycle gating (open/in_progress -> answered), race-condition prevention,
// and service-role atomic update for public.student_teacher_inquiries

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_TEACHER_RESPONSE_LENGTH = 5000;

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({
        error: "method_not_allowed",
        message: "Only POST requests are supported for responding to student inquiries.",
      }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({
          error: "unauthorized",
          message: "Missing or malformed Authorization header.",
        }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) {
      return new Response(
        JSON.stringify({
          error: "unauthorized",
          message: "Empty authentication bearer token.",
        }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !supabaseServiceKey) {
      console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in environment.");
      return new Response(
        JSON.stringify({
          error: "internal_server_error",
          message: "Server environment misconfigured.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseAdmin = createClient(supabaseUrl, supabaseServiceKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });

    const { data: { user }, error: userError } = await supabaseAdmin.auth.getUser(token);
    if (userError || !user || !user.id) {
      return new Response(
        JSON.stringify({
          error: "unauthorized",
          message: "Invalid or expired authentication credentials.",
        }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const authenticatedTeacherId = user.id;

    let body: Record<string, unknown>;
    try {
      const text = await req.text();
      if (!text || text.trim() === "") {
        return new Response(
          JSON.stringify({
            error: "invalid_body",
            message: "Request payload body cannot be empty.",
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      body = JSON.parse(text);
    } catch {
      return new Response(
        JSON.stringify({
          error: "invalid_json",
          message: "Malformed JSON payload.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      return new Response(
        JSON.stringify({
          error: "invalid_body",
          message: "Request payload must be a valid JSON object.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const inquiryIdRaw = body.inquiry_id;
    if (!inquiryIdRaw || typeof inquiryIdRaw !== "string" || inquiryIdRaw.trim() === "") {
      return new Response(
        JSON.stringify({
          error: "missing_inquiry_id",
          message: "The 'inquiry_id' field is required.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const cleanInquiryId = inquiryIdRaw.trim();
    if (!UUID_REGEX.test(cleanInquiryId)) {
      return new Response(
        JSON.stringify({
          error: "invalid_inquiry_id_format",
          message: "The 'inquiry_id' field must be a valid UUID.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const rawResponse = body.teacher_response;
    if (rawResponse === undefined || rawResponse === null) {
      return new Response(
        JSON.stringify({
          error: "missing_teacher_response",
          message: "The 'teacher_response' field is required.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (typeof rawResponse !== "string") {
      return new Response(
        JSON.stringify({
          error: "invalid_teacher_response_format",
          message: "The 'teacher_response' field must be a string.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (rawResponse.length > MAX_TEACHER_RESPONSE_LENGTH) {
      return new Response(
        JSON.stringify({
          error: "teacher_response_too_large",
          message: `The 'teacher_response' exceeds maximum allowed length of ${MAX_TEACHER_RESPONSE_LENGTH} characters.`,
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const cleanTeacherResponse = rawResponse.trim();
    if (cleanTeacherResponse.length === 0) {
      return new Response(
        JSON.stringify({
          error: "empty_teacher_response",
          message: "The 'teacher_response' field cannot be empty or whitespace only.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: teacherProfile, error: profileError } = await supabaseAdmin
      .from("profiles")
      .select("id, external_tenant_id, role")
      .eq("id", authenticatedTeacherId)
      .single();

    if (profileError || !teacherProfile) {
      return new Response(
        JSON.stringify({
          error: "teacher_profile_not_found",
          message: "Teacher profile does not exist.",
        }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (teacherProfile.role !== "teacher" && teacherProfile.role !== "admin") {
      return new Response(
        JSON.stringify({
          error: "forbidden_role",
          message: "Only teachers and administrators can respond to student inquiries.",
        }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!teacherProfile.external_tenant_id || teacherProfile.external_tenant_id.trim() === "") {
      return new Response(
        JSON.stringify({
          error: "tenant_not_configured",
          message: "Teacher profile has no external tenant assigned.",
        }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: inquiry, error: inquiryError } = await supabaseAdmin
      .from("student_teacher_inquiries")
      .select("id, external_tenant_id, attempt_id, attempt_item_id, student_id, teacher_id, subject, student_message, teacher_response, status, created_at, updated_at")
      .eq("id", cleanInquiryId)
      .single();

    if (inquiryError || !inquiry) {
      return new Response(
        JSON.stringify({
          error: "inquiry_not_found",
          message: "Student inquiry does not exist.",
        }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (inquiry.external_tenant_id !== teacherProfile.external_tenant_id) {
      return new Response(
        JSON.stringify({
          error: "tenant_mismatch",
          message: "Cross-tenant inquiry access prohibited.",
        }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (inquiry.status === "answered") {
      return new Response(
        JSON.stringify({
          error: "inquiry_already_answered",
          message: "Cannot respond to an inquiry that has already been answered.",
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (inquiry.status === "closed") {
      return new Response(
        JSON.stringify({
          error: "inquiry_already_closed",
          message: "Cannot respond to an inquiry that is already closed.",
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (inquiry.status !== "open" && inquiry.status !== "in_progress") {
      return new Response(
        JSON.stringify({
          error: "inquiry_not_actionable",
          message: `Cannot respond to inquiry in '${inquiry.status}' status.`,
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const nowIso = new Date().toISOString();
    const { data: updatedInquiry, error: updateError } = await supabaseAdmin
      .from("student_teacher_inquiries")
      .update({
        teacher_id: authenticatedTeacherId,
        teacher_response: cleanTeacherResponse,
        status: "answered",
        updated_at: nowIso,
      })
      .eq("id", cleanInquiryId)
      .in("status", ["open", "in_progress"])
      .select("id, external_tenant_id, attempt_id, attempt_item_id, student_id, teacher_id, subject, student_message, teacher_response, status, created_at, updated_at")
      .maybeSingle();

    if (updateError) {
      console.error("Failed to update student inquiry:", updateError);
      return new Response(
        JSON.stringify({
          error: "database_update_failed",
          message: "Failed to persist teacher response in database.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!updatedInquiry) {
      return new Response(
        JSON.stringify({
          error: "inquiry_state_conflict",
          message: "Inquiry status was concurrently modified or answered by another request.",
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        data: {
          inquiry_id: updatedInquiry.id,
          attempt_id: updatedInquiry.attempt_id,
          attempt_item_id: updatedInquiry.attempt_item_id,
          student_id: updatedInquiry.student_id,
          teacher_id: updatedInquiry.teacher_id,
          subject: updatedInquiry.subject,
          student_message: updatedInquiry.student_message,
          teacher_response: updatedInquiry.teacher_response,
          status: updatedInquiry.status,
          created_at: updatedInquiry.created_at,
          updated_at: updatedInquiry.updated_at,
        },
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: unknown) {
    console.error("Unhandled error in respond-to-student-inquiry:", err);
    return new Response(
      JSON.stringify({
        error: "internal_server_error",
        message: "An unexpected error occurred while processing the response.",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
