# WebMCP in Quartz

Quartz has experimental WebMCP compatibility for tools exposed by the current
website. Facet can discover those tools and ask to run them in the page, using
the page's existing session and application logic. This is a Quartz compatibility
layer in WKWebView, not a claim of native WebKit support or full conformance to
the evolving WebMCP draft.

## Use page tools

1. Open `quartz://flags/` (or **View > Experimental Features…**) and set **WebMCP**
   to **Enabled**. It is disabled by default and your choice is saved across
   launches. Reload any websites that were already open to apply the change.
2. Visit a website that registers WebMCP tools. Use HTTPS, or a loopback HTTP
   address such as `http://127.0.0.1:8000` for local development.
3. Open **Facet**, configure an OpenRouter API key, and select a model that
   supports function/tool calling.
4. Enable **Page tools**, which is off by default, and ask Facet to use a page
   feature. **Current page** separately controls the page-text attachment.
5. Review the native confirmation showing the website, tool, and arguments.
   Approve to run the tool or cancel to decline it. Every invocation requires
   confirmation, including tools labeled as read-only.

The flag applies across Quartz windows. Disabling it immediately stops Facet
page tools and dismisses pending tool approvals. Reload open websites to remove
the compatibility API from their documents; new page loads use the saved flag.
The **Page tools** checkbox is unavailable while the flag is disabled.

When **Page tools** is enabled, tool descriptions, parameter schemas, and results
are sent to OpenRouter and the selected model provider as part of that request.
Turn it off to stop exposing page tools to future requests. Your OpenRouter key
stays in Quartz's native networking code; it is never passed to the website.
Tool declarations and results are website-provided content, including their
safety hints. A completed Facet reply may discuss a result and is subject to
Facet's existing saved-chat and personalization behavior.

## Try the local example

From the repository root:

```sh
cd examples/webmcp
python3 -m http.server 8000 --bind 127.0.0.1
```

Enable **WebMCP** at `quartz://flags/`, open `http://127.0.0.1:8000` in Quartz,
and enable **Page tools** in Facet, then try:

- “List the workshop inventory using this page's tools.”
- “Search the inventory for paper.”
- “Add a task to prepare a watercolor study.”

The [example page](../examples/webmcp/index.html) has no remote dependencies or
backend. Its inventory is fixed sample data; tasks exist only in memory and reset
when you reload. The inventory search is a declarative form, while inventory
listing and adding a task use JavaScript registration. The human controls work
in browsers without WebMCP too. Calling tools through Facet still requires a
working OpenRouter account and may use provider credits.

## Website API

Use the current draft entry point, `document.modelContext`. Quartz also supplies
`navigator.modelContext` compatibility for earlier preview pages. Register tools
before asking Facet to discover them:

```js
const context = document.modelContext || navigator.modelContext;
const lifetime = new AbortController();
if (context) {
  await context.registerTool({
    name: "get_inventory",
    description: "List the sample items displayed on this page.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
    async execute(input, { signal }) {
      signal.throwIfAborted();
      return { items: ["Paper", "Pencils"] };
    }
  }, { signal: lifetime.signal });
}

// When the tool is no longer applicable:
// lifetime.abort();
```

The compatibility layer supports registration, discovery with `getTools()`,
execution with `executeTool()`, registration/execution abort signals, and
`toolchange` notifications. Tool callbacks return JSON-serializable values;
`executeTool()` resolves to the serialized result. Facet bridges these page tools
to its model's function-calling interface. Quartz does not start an external MCP
server or require an MCP URL from the website.

Earlier preview methods `unregisterTool()`, `provideContext()`, and `clearContext()`
are also accepted for compatibility. New pages should use `registerTool()` and
an `AbortSignal` for the registration lifetime.

Forms opt in with `toolname` and `tooldescription`. Named controls supply inputs;
`toolparamdescription` describes a parameter. Forms with `toolautosubmit` may
submit when invoked after Quartz's confirmation. Without it, the form is filled
for the user to review and submit. A submit handler can call `preventDefault()`
and, when `event.agentInvoked` is true, pass a promise to `event.respondWith()`.
See the local example for a search form that returns results without navigation.

## Compatibility boundaries

- Support is limited to secure top-level web pages. Cross-origin and same-origin
  iframe tool delegation are not implemented.
- Native confirmation is required for each Facet invocation. Site annotations
  such as `readOnlyHint` do not bypass it.
- Tools are associated with their page. Navigation, replacing a tool, and
  canceling a request can invalidate an outstanding invocation. Cancellation
  signals the callback to stop; it cannot undo effects already performed.
- Declarative forms support named text and numeric inputs, checkboxes, radio
  groups, and selects, including multiple selections. File controls and repeated
  text-input names are not supported. Native WebMCP CSS pseudo-classes are not
  implemented. A form tool requires `preventDefault()` and `respondWith()`;
  navigation results are reported as unsupported.
- JSON Schema support includes types, object properties and required fields,
  additional properties, array items, enums/constants, combinations
  (`anyOf`, `oneOf`, `allOf`, `not`), numeric bounds/multiples, and size/uniqueness
  constraints. Unsupported keywords, including `$ref`, `$defs`, `pattern`, and
  `format`, reject registration rather than silently skipping validation.
- A page can expose up to 64 tools. Facet limits each schema and argument object
  to 64 KiB of encoded JSON, and omits results larger than 64 KiB from model
  requests. The page compatibility layer also limits result size and execution
  duration; callbacks have a 30-second timeout. Facet bounds each request to
  eight rounds of tool calls and twelve individual calls.
  A denied, canceled, failed, or timed-out page tool ends the request. Facet does
  not automatically retry it; review the page before sending another request.
- Quartz applies the main document's `Permissions-Policy: tools` restriction to
  Facet discovery. The injected page API cannot reproduce all WebKit engine
  enforcement, including origin-agent-cluster behavior and page-side policy
  gating. Its presence is not a full browser conformance signal.
- Pages that do not declare tools continue to work through ordinary browsing.
  A model without function-calling support cannot invoke page tools.

The [WebMCP draft](https://webmachinelearning.github.io/webmcp/) is a W3C
Community Group report and remains subject to change. Its declarative processing
model is still under discussion; see the
[declarative explainer](https://github.com/webmachinelearning/webmcp/blob/main/declarative-api-explainer.md)
and [Chrome's form API guide](https://developer.chrome.com/docs/ai/webmcp/declarative-api).
