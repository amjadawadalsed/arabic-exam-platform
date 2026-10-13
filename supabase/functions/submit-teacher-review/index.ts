// supabase/functions/submit-teacher-review/index.ts
// PHASE 8B.7: Edge Function #4 - Submit Teacher Review
// Invokes locked Teacher Review RPC: submit_teacher_review_atomic(...)
// Single canonical RPC signature, strict validation, zero-score allowed, no aliases, no fallbacks

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_FEEDBACK_TEXT_LENGTH = 50000;

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({
        error: "method_not_allowed",
        message: "Only POST requests are supported for submitting teacher reviews.",
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

    const attemptItemIdRaw = body.attempt_item_id;
    if (!attemptItemIdRaw || typeof attemptItemIdRaw !== "string" || attemptItemIdRaw.trim() === "") {
      return new Response(
        JSON.stringify({
          error: "missing_attempt_item_id",
          message: "The 'attempt_item_id' field is required.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const cleanAttemptItemId = attemptItemIdRaw.trim();
    if (!UUID_REGEX.test(cleanAttemptItemId)) {
      return new Response(
        JSON.stringify({
          error: "invalid_attempt_item_id_format",
          message: "The 'attempt_item_id' field must be a valid UUID.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const rawScore = body.assigned_score;
    if (rawScore === undefined || rawScore === null) {
      return new Response(
        JSON.stringify({
          error: "missing_assigned_score",
          message: "The 'assigned_score' field is required.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (typeof rawScore !== "number" || !Number.isFinite(rawScore) || Number.isNaN(rawScore)) {
      return new Response(
        JSON.stringify({
          error: "invalid_assigned_score_format",
          message: "The 'assigned_score' field must be a valid finite number.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (rawScore < 0) {
      return new Response(
        JSON.stringify({
          error: "negative_assigned_score",
          message: "The 'assigned_score' cannot be negative.",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const cleanAssignedScore = Math.round(rawScore * 100) / 100;

    const rawFeedback = body.feedback_text;
    let cleanFeedbackText: string | null = null;
    if (rawFeedback !== undefined && rawFeedback !== null) {
      if (typeof rawFeedback !== "string") {
        return new Response(
          JSON.stringify({
            error: "invalid_feedback_text_format",
            message: "The 'feedback_text' field must be a string.",
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      if (rawFeedback.length > MAX_FEEDBACK_TEXT_LENGTH) {
        return new Response(
          JSON.stringify({
            error: "feedback_text_too_large",
            message: `The 'feedback_text' exceeds maximum allowed length of ${MAX_FEEDBACK_TEXT_LENGTH} characters.`,
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      cleanFeedbackText = rawFeedback;
    }

    let isFinalized = true;
    if (body.is_finalized !== undefined && body.is_finalized !== null) {
      if (typeof body.is_finalized !== "boolean") {
        return new Response(
          JSON.stringify({
            error: "invalid_is_finalized_format",
            message: "The 'is_finalized' field must be a boolean.",
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      isFinalized = body.is_finalized;
    }

    const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc(
      "submit_teacher_review_atomic",
      {
        p_attempt_item_id: cleanAttemptItemId,
        p_teacher_id: authenticatedTeacherId,
        p_assigned_score: cleanAssignedScore,
        p_feedback_text: cleanFeedbackText,
        p_is_finalized: isFinalized,
      }
    );

    if (rpcError) {
      console.error("RPC submit_teacher_review_atomic execution error:", rpcError);
      return new Response(
        JSON.stringify({
          error: "rpc_execution_error",
          message: "Database transaction failed while recording teacher review.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!rpcResult || typeof rpcResult !== "object") {
      return new Response(
        JSON.stringify({
          error: "invalid_rpc_response",
          message: "Unexpected response returned from teacher review engine.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!rpcResult.success) {
      const errCode = (rpcResult.error as string) || "review_submission_failed";
      let httpStatus = 400;
      switch (errCode) {
        case "forbidden_teacher_id":
        case "tenant_mismatch":
        case "review_not_permitted":
        case "not_a_teacher":
        case "teacher_not_authorized":
          httpStatus = 403;
          break;
        case "teacher_profile_not_found":
        case "attempt_not_found":
        case "attempt_item_not_found":
          httpStatus = 404;
          break;
        case "invalid_attempt_status":
        case "attempt_not_submitted":
        case "already_finalized":
        case "review_already_finalized":
          httpStatus = 409;
          break;
        case "invalid_score":
        case "score_exceeds_allocated":
        case "review_not_required":
          httpStatus = 400;
          break;
        default:
          httpStatus = 400;
          break;
      }
      return new Response(
        JSON.stringify({
          error: errCode,
          message: (rpcResult.message as string) || "Failed to submit teacher review.",
          ...(rpcResult.details ? { details: rpcResult.details } : {}),
        }),
        { status: httpStatus, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify(rpcResult),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("Unhandled error in submit-teacher-review edge function:", err);
    return new Response(
      JSON.stringify({
        error: "internal_server_error",
        message: "An unexpected error occurred while processing the request.",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
