// supabase/functions/get-student-official-result/index.ts
// PHASE 8B.8: Edge Function #5 - Get Student Official Result
// Invokes locked Official Result RPC: get_student_official_result(p_student_id UUID, p_attempt_id UUID)
// Server-authoritative student identity, official_final gating, data sanitization, zero direct writes

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
        message: "Only POST requests are supported for retrieving official exam results.",
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
      "get_student_official_result",
      {
        p_student_id: authenticatedStudentId,
        p_attempt_id: cleanAttemptId,
      }
    );

    if (rpcError) {
      console.error("RPC get_student_official_result execution error:", rpcError);
      return new Response(
        JSON.stringify({
          error: "rpc_execution_error",
          message: "Database transaction failed while retrieving official result.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!rpcResult || typeof rpcResult !== "object") {
      return new Response(
        JSON.stringify({
          error: "invalid_rpc_response",
          message: "Unexpected response returned from official result engine.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!rpcResult.success) {
      const errCode = (rpcResult.error as string) || "result_retrieval_failed";
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
        case "attempt_not_finalized":
        case "result_provisional":
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
          message: (rpcResult.message as string) || "Failed to retrieve official exam result.",
          ...(rpcResult.details ? { details: rpcResult.details } : {}),
        }),
        { status: httpStatus, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (rpcResult.final_scoring_status !== "official_final") {
      return new Response(
        JSON.stringify({
          error: "result_not_finalized",
          message: "Exam attempt result is still provisional and has not been officially finalized.",
          final_scoring_status: rpcResult.final_scoring_status || "provisional",
        }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const sanitizedResponse: Record<string, unknown> = {
      success: true,
      attempt_id: rpcResult.attempt_id || cleanAttemptId,
      exam_id: rpcResult.exam_id,
      final_scoring_status: "official_final",
      total_score: rpcResult.total_score,
      percentage_score: rpcResult.percentage_score,
      is_passed: rpcResult.is_passed,
      placement_level_id: rpcResult.placement_level_id ?? null,
      placement_status: rpcResult.placement_status ?? "not_applicable",
      completed_at: rpcResult.completed_at ?? null,
      ...(rpcResult.placement_level ? { placement_level: rpcResult.placement_level } : {}),
      ...(rpcResult.exam_title ? { exam_title: rpcResult.exam_title } : {}),
    };

    return new Response(
      JSON.stringify(sanitizedResponse),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("Unhandled error in get-student-official-result edge function:", err);
    return new Response(
      JSON.stringify({
        error: "internal_server_error",
        message: "An unexpected error occurred while processing the request.",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
