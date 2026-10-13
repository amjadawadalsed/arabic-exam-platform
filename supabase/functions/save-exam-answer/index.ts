// supabase/functions/save-exam-answer/index.ts
// PHASE 8B.5: Edge Function #2 - Save Exam Answer Atomic
// Invokes locked RPC #2: save_exam_answer_atomic(...)
// Server-authoritative student identity, timer validation, ownership, and storage checks

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_TEXT_RESPONSE_LENGTH = 50000;

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({
        error: "method_not_allowed",
        message: "Only POST requests are supported for saving exam answers.",
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

    let selectedOptionKey: string | null = null;
    if (body.selected_option_key !== undefined && body.selected_option_key !== null) {
      if (typeof body.selected_option_key !== "string") {
        return new Response(
          JSON.stringify({
            error: "invalid_selected_option_key_format",
            message: "The 'selected_option_key' field must be a string.",
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      selectedOptionKey = body.selected_option_key;
    }

    let textResponse: string | null = null;
    if (body.text_response !== undefined && body.text_response !== null) {
      if (typeof body.text_response !== "string") {
        return new Response(
          JSON.stringify({
            error: "invalid_text_response_format",
            message: "The 'text_response' field must be a string.",
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      if (body.text_response.length > MAX_TEXT_RESPONSE_LENGTH) {
        return new Response(
          JSON.stringify({
            error: "text_response_too_large",
            message: `The 'text_response' exceeds maximum allowed length of ${MAX_TEXT_RESPONSE_LENGTH} characters.`,
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      textResponse = body.text_response;
    }

    let audioStoragePath: string | null = null;
    if (body.audio_storage_path !== undefined && body.audio_storage_path !== null) {
      if (typeof body.audio_storage_path !== "string") {
        return new Response(
          JSON.stringify({
            error: "invalid_audio_storage_path_format",
            message: "The 'audio_storage_path' field must be a string.",
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      audioStoragePath = body.audio_storage_path;
    }

    let audioDurationSeconds: number | null = null;
    if (body.audio_duration_seconds !== undefined && body.audio_duration_seconds !== null) {
      if (
        typeof body.audio_duration_seconds !== "number" ||
        !Number.isFinite(body.audio_duration_seconds) ||
        Number.isNaN(body.audio_duration_seconds)
      ) {
        return new Response(
          JSON.stringify({
            error: "invalid_audio_duration_seconds",
            message: "The 'audio_duration_seconds' must be a valid finite number.",
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      audioDurationSeconds = body.audio_duration_seconds;
    }

    const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc(
      "save_exam_answer_atomic",
      {
        p_student_id: authenticatedStudentId,
        p_attempt_id: cleanAttemptId,
        p_attempt_item_id: cleanAttemptItemId,
        p_selected_option_key: selectedOptionKey,
        p_text_response: textResponse,
        p_audio_storage_path: audioStoragePath,
        p_audio_duration_seconds: audioDurationSeconds,
      }
    );

    if (rpcError) {
      console.error("RPC save_exam_answer_atomic execution error:", rpcError);
      return new Response(
        JSON.stringify({
          error: "rpc_execution_error",
          message: "Database transaction failed while saving exam answer.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!rpcResult || typeof rpcResult !== "object") {
      return new Response(
        JSON.stringify({
          error: "invalid_rpc_response",
          message: "Unexpected response returned from exam answer engine.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!rpcResult.success) {
      const errCode = (rpcResult.error as string) || "save_answer_failed";
      let httpStatus = 400;
      switch (errCode) {
        case "forbidden_student_id":
        case "tenant_mismatch":
        case "attempt_not_owned":
        case "attempt_item_mismatch":
          httpStatus = 403;
          break;
        case "student_profile_not_found":
        case "attempt_not_found":
        case "attempt_item_not_found":
          httpStatus = 404;
          break;
        case "attempt_not_in_progress":
        case "attempt_expired":
          httpStatus = 409;
          break;
        case "missing_selected_option":
        case "invalid_selected_option":
        case "missing_text_response":
        case "missing_audio_storage_path":
        case "invalid_audio_duration":
        case "invalid_audio_storage_path":
        case "audio_object_not_found":
        case "unsupported_question_type":
          httpStatus = 422;
          break;
        default:
          httpStatus = 400;
          break;
      }
      return new Response(
        JSON.stringify({
          error: errCode,
          message: (rpcResult.message as string) || "Failed to save exam answer.",
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
    console.error("Unhandled error in save-exam-answer edge function:", err);
    return new Response(
      JSON.stringify({
        error: "internal_server_error",
        message: "An unexpected error occurred while processing the request.",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
