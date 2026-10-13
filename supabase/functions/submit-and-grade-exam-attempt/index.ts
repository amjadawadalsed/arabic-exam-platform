// supabase/functions/submit-and-grade-exam-attempt/index.ts
// PHASE 8B.6: Edge Function #3 - Submit and Grade Exam Attempt Atomic
// Invokes locked RPC #3: submit_and_grade_exam_attempt_atomic(p_student_id UUID, p_attempt_id UUID)
// Server-authoritative student identity, auto-grading, and score finalization gateway

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({
        error: "method_not_allowed",
        message: "Only POST requests are supported for submitting exam attempts.",
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

    const authenticatedStudentId = user.id;

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

    const attemptIdRaw = body.attempt_id;
    if (!attemptIdRaw || typeof attemptIdRaw !== "string" || attemptIdRaw.trim() === "") {
      return new Response(
        JSON.stringify({
          error: "missing_attempt_id",
          message: "The 'attempt_id' field is required.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const cleanAttemptId = attemptIdRaw.trim();
    if (!UUID_REGEX.test(cleanAttemptId)) {
      return new Response(
        JSON.stringify({
          error: "invalid_attempt_id_format",
          message: "The 'attempt_id' field must be a valid UUID.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc(
      "submit_and_grade_exam_attempt_atomic",
      {
        p_student_id: authenticatedStudentId,
        p_attempt_id: cleanAttemptId,
      }
    );

    if (rpcError) {
      console.error("RPC submit_and_grade_exam_attempt_atomic execution error:", rpcError);
      return new Response(
        JSON.stringify({
          error: "rpc_execution_error",
          message: "Database transaction failed while submitting exam attempt.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!rpcResult || typeof rpcResult !== "object") {
      return new Response(
        JSON.stringify({
          error: "invalid_rpc_response",
          message: "Unexpected response returned from exam submission engine.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!rpcResult.success) {
      const errCode = (rpcResult.error as string) || "submission_failed";
      let httpStatus = 400;
      switch (errCode) {
        case "forbidden_student_id":
        case "tenant_mismatch":
        case "attempt_not_owned":
          httpStatus = 403;
          break;
        case "student_profile_not_found":
        case "attempt_not_found":
        case "exam_not_found":
          httpStatus = 404;
          break;
        case "invalid_attempt_status":
          httpStatus = 409;
          break;
        default:
          httpStatus = 400;
          break;
      }
      return new Response(
        JSON.stringify({
          error: errCode,
          message: (rpcResult.message as string) || "Failed to submit exam attempt.",
          ...(rpcResult.current_status ? { current_status: rpcResult.current_status } : {}),
        }),
        { status: httpStatus, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify(rpcResult),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("Unhandled error in submit-and-grade-exam-attempt edge function:", err);
    return new Response(
      JSON.stringify({
        error: "internal_server_error",
        message: "An unexpected error occurred while processing the request.",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
