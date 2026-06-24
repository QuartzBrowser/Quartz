const GITHUB_OWNER = "QuartzBrowser";
const GITHUB_REPOSITORY = "Quartz";
const MAX_TITLE_LENGTH = 256;
const MAX_BODY_LENGTH = 16000;
const DEFAULT_RATE_LIMIT_MAX = 10;
const DEFAULT_RATE_LIMIT_WINDOW_SECONDS = 3600;

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return preflightResponse(request, env);
    }

    if (request.method !== "POST") {
      return jsonResponse({ message: "Method not allowed" }, 405, request);
    }

    const originError = validateOrigin(request, env);
    if (originError) {
      return originError;
    }

    if (!env.GITHUB_TOKEN) {
      return jsonResponse({ message: "Issue relay is missing GITHUB_TOKEN" }, 500, request);
    }

    const contentType = request.headers.get("content-type") || "";
    if (!contentType.toLowerCase().includes("application/json")) {
      return jsonResponse({ message: "Expected application/json" }, 415, request);
    }

    const rateLimitError = await enforceRateLimit(request, env);
    if (rateLimitError) {
      return rateLimitError;
    }

    let payload;
    try {
      payload = await request.json();
    } catch {
      return jsonResponse({ message: "Expected JSON body" }, 400, request);
    }

    if (payload.repository && payload.repository !== `${GITHUB_OWNER}/${GITHUB_REPOSITORY}`) {
      return jsonResponse({ message: "Unsupported repository" }, 400, request);
    }

    const title = cleanText(payload.title).slice(0, MAX_TITLE_LENGTH);
    const body = cleanText(payload.body || "Submitted from Quartz.").slice(0, MAX_BODY_LENGTH);

    if (!title) {
      return jsonResponse({ message: "Issue title is required" }, 400, request);
    }

    const githubResponse = await fetch(
      `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPOSITORY}/issues`,
      {
        method: "POST",
        headers: {
          "Accept": "application/vnd.github+json",
          "Authorization": `Bearer ${env.GITHUB_TOKEN}`,
          "Content-Type": "application/json",
          "User-Agent": "Quartz issue relay",
          "X-GitHub-Api-Version": "2022-11-28"
        },
        body: JSON.stringify({
          title,
          body: withContext(body, payload)
        })
      }
    );

    const result = await githubResponse.json().catch(() => ({}));
    if (!githubResponse.ok) {
      return jsonResponse(
        { message: result.message || "GitHub issue creation failed" },
        githubResponse.status,
        request
      );
    }

    if (!result.number || !result.html_url) {
      return jsonResponse({ message: "GitHub response did not include an issue URL" }, 502, request);
    }

    return jsonResponse(
      {
        number: result.number,
        html_url: result.html_url
      },
      201,
      request
    );
  }
};

function cleanText(value) {
  return String(value || "").trim();
}

function withContext(body, payload) {
  const context = [
    lineFor("Page URL", payload.pageURL),
    lineFor("Page title", payload.pageTitle),
    lineFor("macOS", payload.operatingSystem)
  ]
    .filter(Boolean)
    .filter((line) => !body.includes(line));

  const hasSubmissionMarker = body.includes("Submitted from Quartz") || body.includes("Submitted from: Quartz");
  if (context.length === 0 && hasSubmissionMarker) {
    return body;
  }

  const footer = [
    hasSubmissionMarker ? null : "Submitted from Quartz",
    ...context
  ].filter(Boolean);

  return `${body}\n\n---\n${footer.join("\n")}`;
}

function lineFor(label, value) {
  const text = cleanText(value);
  return text ? `- ${label}: ${text}` : null;
}

async function enforceRateLimit(request, env) {
  if (!env.QUARTZ_ISSUE_RELAY_KV) {
    return null;
  }

  const ipAddress = request.headers.get("CF-Connecting-IP") || "unknown";
  const key = `rate:${ipAddress}`;
  const maxRequests = numberFromEnv(env.RATE_LIMIT_MAX, DEFAULT_RATE_LIMIT_MAX);
  const windowSeconds = numberFromEnv(env.RATE_LIMIT_WINDOW_SECONDS, DEFAULT_RATE_LIMIT_WINDOW_SECONDS);
  const current = await env.QUARTZ_ISSUE_RELAY_KV.get(key, "json") || { count: 0 };

  if (current.count >= maxRequests) {
    return jsonResponse({ message: "Too many issue submissions. Try again later." }, 429, request);
  }

  await env.QUARTZ_ISSUE_RELAY_KV.put(
    key,
    JSON.stringify({ count: current.count + 1 }),
    { expirationTtl: windowSeconds }
  );

  return null;
}

function numberFromEnv(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

function validateOrigin(request, env) {
  const origin = request.headers.get("Origin");
  if (!origin) {
    return null;
  }

  if (!env.ALLOWED_ORIGIN) {
    return jsonResponse({ message: "Browser origins are not allowed" }, 403, request);
  }

  return origin === env.ALLOWED_ORIGIN
    ? null
    : jsonResponse({ message: "Origin not allowed" }, 403, request);
}

function preflightResponse(request, env) {
  const originError = validateOrigin(request, env);
  if (originError) {
    return originError;
  }

  return corsResponse(null, 204, {}, request);
}

function jsonResponse(body, status, request = null) {
  return corsResponse(JSON.stringify(body), status, {
    "Content-Type": "application/json"
  }, request);
}

function corsResponse(body, status, headers = {}, request = null) {
  const origin = request?.headers.get("Origin");
  const corsHeaders = origin
    ? {
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Origin": origin
      }
    : {};

  return new Response(body, {
    status,
    headers: {
      ...corsHeaders,
      "Vary": "Origin",
      ...headers
    }
  });
}
