import worker from "./github-issue-relay-worker.js";

const originalFetch = globalThis.fetch;

try {
  await test("creates a GitHub issue through the relay", async () => {
    let githubURL;
    let githubRequest;

    globalThis.fetch = async (url, request) => {
      githubURL = url;
      githubRequest = request;
      return new Response(
        JSON.stringify({
          number: 42,
          html_url: "https://github.com/QuartzBrowser/Quartz/issues/42"
        }),
        {
          status: 201,
          headers: { "content-type": "application/json" }
        }
      );
    };

    const response = await worker.fetch(
      jsonRequest({
        repository: "QuartzBrowser/Quartz",
        title: "Quartz issue",
        body: "Submitted from test",
        pageURL: "https://example.com/page",
        pageTitle: "Example Page",
        operatingSystem: "macOS 26.0"
      }),
      { GITHUB_TOKEN: "server-token" }
    );
    const result = await response.json();
    const githubBody = JSON.parse(githubRequest.body);

    assert(response.status === 201, `expected 201, got ${response.status}`);
    assert(result.number === 42, "expected issue number from GitHub");
    assert(result.html_url.endsWith("/issues/42"), "expected GitHub issue URL");
    assert(
      githubURL === "https://api.github.com/repos/QuartzBrowser/Quartz/issues",
      "expected GitHub issues API URL"
    );
    assert(
      githubRequest.headers.Authorization === "Bearer server-token",
      "expected server-side GitHub token"
    );
    assert(githubBody.body.includes("- Page URL: https://example.com/page"), "expected page context");
  });

  await test("blocks browser-origin requests unless configured", async () => {
    const response = await worker.fetch(
      jsonRequest({ title: "Blocked" }, { Origin: "https://example.com" }),
      { GITHUB_TOKEN: "server-token" }
    );
    const result = await response.json();

    assert(response.status === 403, `expected 403, got ${response.status}`);
    assert(result.message === "Browser origins are not allowed", "expected origin rejection");
  });

  await test("allows configured CORS preflight", async () => {
    const response = await worker.fetch(
      new Request("https://relay.example/issues", {
        method: "OPTIONS",
        headers: { Origin: "https://example.com" }
      }),
      {
        GITHUB_TOKEN: "server-token",
        ALLOWED_ORIGIN: "https://example.com"
      }
    );

    assert(response.status === 204, `expected 204, got ${response.status}`);
    assert(
      response.headers.get("access-control-allow-origin") === "https://example.com",
      "expected allowed origin header"
    );
  });

  await test("rate limits through Workers KV when bound", async () => {
    const response = await worker.fetch(
      jsonRequest({ title: "Too many" }, { "CF-Connecting-IP": "203.0.113.10" }),
      {
        GITHUB_TOKEN: "server-token",
        RATE_LIMIT_MAX: "1",
        QUARTZ_ISSUE_RELAY_KV: memoryKV({
          "rate:203.0.113.10": { count: 1 }
        })
      }
    );
    const result = await response.json();

    assert(response.status === 429, `expected 429, got ${response.status}`);
    assert(result.message.includes("Too many"), "expected rate limit message");
  });
} finally {
  globalThis.fetch = originalFetch;
}

function jsonRequest(body, headers = {}) {
  return new Request("https://relay.example/issues", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...headers
    },
    body: JSON.stringify(body)
  });
}

function memoryKV(initial = {}) {
  const store = new Map(
    Object.entries(initial).map(([key, value]) => [key, JSON.stringify(value)])
  );

  return {
    async get(key, type) {
      const value = store.get(key);
      if (value === undefined) {
        return null;
      }

      return type === "json" ? JSON.parse(value) : value;
    },
    async put(key, value) {
      store.set(key, value);
    }
  };
}

async function test(name, operation) {
  try {
    await operation();
    console.log(`PASS ${name}`);
  } catch (error) {
    console.error(`FAIL ${name}`);
    throw error;
  }
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}
