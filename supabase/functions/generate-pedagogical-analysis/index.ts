// supabase/functions/generate-pedagogical-analysis/index.ts
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";

interface SkillAnalysisItem {
  skill_code: string;
  skill_name_ar: string;
  level_assessment: string;
  feedback: string;
}

interface CommonErrorItem {
  error_category: string;
  description: string;
  correction_advice: string;
}

interface StructuredPedagogicalAnalysis {
  strengths: string[];
  weaknesses: string[];
  skill_analysis: SkillAnalysisItem[];
  common_errors: CommonErrorItem[];
  learning_recommendations: string[];
  student_summary: string;
}

serve(async (req) => {
  const headers = { "Content-Type": "application/json" };
  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers });
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "unauthorized", message: "Missing Authorization header." }), { status: 401, headers });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const geminiApiKey = Deno.env.get("GEMINI_API_KEY");

    const supabaseAdmin = createClient(supabaseUrl, supabaseServiceKey);

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabaseAdmin.auth.getUser(token);
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "unauthorized", message: "Invalid or expired token." }), { status: 401, headers });
    }

    const body = await req.json().catch(() => ({}));
    const attemptId = body.attempt_id;
    if (!attemptId) {
      return new Response(JSON.stringify({ error: "missing_attempt_id" }), { status: 400, headers });
    }

    const { data: initResult, error: initRpcError } = await supabaseAdmin.rpc("initialize_pedagogical_analysis", {
      p_attempt_id: attemptId,
      p_caller_id: user.id
    });

    if (initRpcError || !initResult?.success) {
      const errCode = initResult?.error || "initialization_failed";
      let status = 400;
      if (errCode === "unauthorized") status = 401;
      if (errCode === "forbidden_ownership" || errCode === "tenant_mismatch") status = 403;
      if (errCode === "attempt_not_final") status = 422;
      return new Response(JSON.stringify({ error: errCode, message: initResult?.message || initRpcError?.message }), { status, headers });
    }

    if (initResult.action === "already_completed") {
      return new Response(JSON.stringify({
        status: "completed",
        analysis: initResult.analysis,
        cached: true
      }), { status: 200, headers });
    }

    if (initResult.action === "already_pending") {
      return new Response(JSON.stringify({
        status: "pending",
        message: "Analysis generation is currently in progress."
      }), { status: 202, headers });
    }

    const { data: attemptData, error: attemptFetchError } = await supabaseAdmin
      .from("exam_attempts")
      .select(`
        id,
        percentage_score,
        total_score,
        is_passed,
        placement_status,
        proficiency_levels(code, name_ar),
        exams(title, exam_type, passing_score_percentage),
        attempt_items(
          id,
          item_type,
          allocated_score,
          awarded_score,
          is_correct,
          frozen_question_text,
          language_skills(code, name_ar),
          attempt_answers(selected_option_key, text_response),
          teacher_reviews(assigned_score, feedback_text)
        )
      `)
      .eq("id", attemptId)
      .single();

    if (attemptFetchError || !attemptData) {
      await supabaseAdmin.rpc("save_pedagogical_analysis_result", {
        p_attempt_id: attemptId,
        p_status: "failed",
        p_error_message: "Failed to fetch attempt data for analysis."
      });
      return new Response(JSON.stringify({ error: "data_fetch_failed" }), { status: 500, headers });
    }

    if (!geminiApiKey) {
      await supabaseAdmin.rpc("save_pedagogical_analysis_result", {
        p_attempt_id: attemptId,
        p_status: "failed",
        p_error_message: "GEMINI_API_KEY environment variable is not configured."
      });
      return new Response(JSON.stringify({ error: "ai_service_unconfigured" }), { status: 503, headers });
    }

    // @ts-ignore - Supabase nested joins
    const examTitle = attemptData.exams?.title || "اختبار اللغة العربية";
    // @ts-ignore
    const placementLevel = attemptData.proficiency_levels?.name_ar || "غير محدد";

    const itemsSummary = (attemptData.attempt_items || []).map((item: any, idx: number) => {
      const skillName = item.language_skills?.name_ar || "مهارة لغوية";
      const answer = item.attempt_answers?.[0];
      const review = item.teacher_reviews?.[0];
      let details = `سؤال ${idx + 1} [${skillName} - ${item.item_type}]: نص السؤال: "${item.frozen_question_text}" | الدرجة المستحقة: ${item.allocated_score} | الدرجة الممنوحة: ${item.awarded_score ?? 0}`;
      
      if (item.is_correct === false) {
        details += ` | إجابة الطالب: "${answer?.selected_option_key || answer?.text_response || 'لا يوجد'}"`;
      }
      if (review?.feedback_text) {
        details += ` | ملاحظات المصحح: "${review.feedback_text}"`;
      }
      return details;
    }).join("\n");

    const systemPrompt = `أنت خبير تربوي في تعليم اللغة العربية للناطقين بغيرها. قم بتحليل نتائج هذا الاختبار وتقديم تحليل تشخيصي دقيق بلغة عربية فصيحة ومبسطة.`;
    const userPrompt = `بيانات الاختبار:
عنوان الاختبار: ${examTitle}
النسبة المئوية: ${attemptData.percentage_score}%
الدرجة الإجمالية: ${attemptData.total_score}
مستوى التسكين: ${placementLevel}
حالة الاجتياز: ${attemptData.is_passed ? "ناجح" : "غير مجتاز"}

تفاصيل الأسئلة والإجابات:
${itemsSummary}`;

    const responseSchema = {
      type: "OBJECT",
      properties: {
        strengths: {
          type: "ARRAY",
          items: { type: "STRING" },
          description: "نقاط القوة اللغوية"
        },
        weaknesses: {
          type: "ARRAY",
          items: { type: "STRING" },
          description: "نقاط الضعف التي تحتاج إلى تحسين"
        },
        skill_analysis: {
          type: "ARRAY",
          items: {
            type: "OBJECT",
            properties: {
              skill_code: { type: "STRING" },
              skill_name_ar: { type: "STRING" },
              level_assessment: { type: "STRING" },
              feedback: { type: "STRING" }
            },
            required: ["skill_code", "skill_name_ar", "level_assessment", "feedback"]
          },
          description: "تحليل مفصل لكل مهارة"
        },
        common_errors: {
          type: "ARRAY",
          items: {
            type: "OBJECT",
            properties: {
              error_category: { type: "STRING" },
              description: { type: "STRING" },
              correction_advice: { type: "STRING" }
            },
            required: ["error_category", "description", "correction_advice"]
          },
          description: "الأخطاء الشائعة والنصائح لتصحيحها"
        },
        learning_recommendations: {
          type: "ARRAY",
          items: { type: "STRING" },
          description: "توصيات تعليمية وخطوات عملية"
        },
        student_summary: {
          type: "STRING",
          description: "ملخص موجه للطالب"
        }
      },
      required: [
        "strengths",
        "weaknesses",
        "skill_analysis",
        "common_errors",
        "learning_recommendations",
        "student_summary"
      ]
    };

    const geminiUrl = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?key=${geminiApiKey}`;
    const geminiReqBody = {
      contents: [
        { role: "user", parts: [{ text: systemPrompt + "\n\n" + userPrompt }] }
      ],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: responseSchema,
        temperature: 0.3
      }
    };

    let structuredAnalysis: StructuredPedagogicalAnalysis;
    try {
      const geminiRes = await fetch(geminiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(geminiReqBody)
      });
      if (!geminiRes.ok) {
        const errText = await geminiRes.text();
        throw new Error(`Gemini API responded with status ${geminiRes.status}: ${errText}`);
      }
      const geminiData = await geminiRes.json();
      const rawText = geminiData.candidates?.[0]?.content?.parts?.[0]?.text;
      if (!rawText) {
        throw new Error("Empty candidate response from Gemini.");
      }
      structuredAnalysis = JSON.parse(rawText);
    } catch (apiErr: any) {
      await supabaseAdmin.rpc("save_pedagogical_analysis_result", {
        p_attempt_id: attemptId,
        p_status: "failed",
        p_error_message: apiErr.message
      });
      return new Response(JSON.stringify({
        error: "ai_analysis_generation_failed",
        message: "Failed to generate pedagogical analysis from AI provider."
      }), { status: 502, headers });
    }

    const isValid = 
      Array.isArray(structuredAnalysis.strengths) && structuredAnalysis.strengths.length > 0 &&
      Array.isArray(structuredAnalysis.weaknesses) && structuredAnalysis.weaknesses.length > 0 &&
      Array.isArray(structuredAnalysis.learning_recommendations) && structuredAnalysis.learning_recommendations.length > 0 &&
      typeof structuredAnalysis.student_summary === "string" && structuredAnalysis.student_summary.trim().length > 10;

    if (!isValid) {
      await supabaseAdmin.rpc("save_pedagogical_analysis_result", {
        p_attempt_id: attemptId,
        p_status: "failed",
        p_error_message: "Model response failed semantic schema constraints."
      });
      return new Response(JSON.stringify({
        error: "semantic_validation_failed",
        message: "The AI analysis response did not meet required pedagogical quality constraints."
      }), { status: 422, headers });
    }

    const { data: saveResult, error: saveRpcError } = await supabaseAdmin.rpc("save_pedagogical_analysis_result", {
      p_attempt_id: attemptId,
      p_status: "completed",
      p_structured_analysis: structuredAnalysis,
      p_error_message: null,
      p_model_version: "gemini-3.8-flash"
    });

    if (saveRpcError || !saveResult?.success) {
      return new Response(JSON.stringify({ error: "save_analysis_failed" }), { status: 500, headers });
    }

    return new Response(JSON.stringify({
      success: true,
      status: "completed",
      attempt_id: attemptId,
      analysis: structuredAnalysis
    }), { status: 200, headers });

  } catch (globalErr: any) {
    return new Response(JSON.stringify({
      error: "internal_error",
      message: "An unexpected error occurred during analysis processing."
    }), { status: 500, headers });
  }
});
