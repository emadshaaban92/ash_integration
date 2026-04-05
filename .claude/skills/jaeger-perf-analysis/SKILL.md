---
name: jaeger-perf-analysis
description: Analyze LiveView, Phoenix, and API endpoint performance using Jaeger distributed tracing. Use this skill whenever you want to check performance after modifying a LiveView, handle_event, handle_params, mount, Ash action, or API endpoint — or whenever the user mentions Jaeger, tracing, performance analysis, slow pages, slow events, slow API requests, span counts, N+1 queries, render performance, or API response times. Also use this when the user asks you to verify that a code change didn't regress performance, or to profile a specific page, event, or API endpoint. This skill teaches you how to query the Jaeger API, interpret trace waterfalls, and spot common performance anti-patterns in Phoenix LiveView + Ash Framework apps and their REST/JSON API endpoints.
---

# Jaeger Performance Analysis for Phoenix LiveView & API Endpoints

This skill lets you query Jaeger's HTTP API to analyze real trace data and find performance issues in a Phoenix LiveView + Ash Framework application **and its REST API endpoints**. It's especially useful as a **post-change verification step** — after modifying a LiveView, event handler, Ash action, or API controller, run this analysis to confirm you haven't introduced regressions.

This is a **generic skill** — it works in any Phoenix + Ash project with OpenTelemetry tracing. If the current project has a companion project-specific perf skill, read that too for span names, known patterns, and auth details.

## Prerequisites

- Jaeger is running and accessible (default URL: `http://jaeger:16686`, override with `--jaeger-url`)
- The app exports traces via OpenTelemetry (OTEL) to Jaeger
- The service name is configured via the `OTEL_SERVICE_NAME` environment variable (check `docker-compose.yml` if unsure)

To discover the service name:
```bash
python3 .claude/skills/jaeger-perf-analysis/scripts/analyze_traces.py --discover-services
```

## How Traces Are Structured in Phoenix + Ash Apps

Phoenix + Ash apps have **two types of traffic**: LiveView (WebSocket) interactions and REST API requests (if the app has an API). Understanding both trace hierarchies is critical.

### Trace types you'll see

| Trace Root | When It Fires | What It Means |
|---|---|---|
| `GET /some_path` | Initial page load (dead render) | HTTP request → only happens once per page visit |
| `SomeLive.mount` | WebSocket connect | LiveView connected mount — loads initial data |
| `SomeLive.handle_params` | URL changes within LiveView | Navigation, filtering, pagination via URL params |
| `SomeLive.handle_event#event_name` | User interaction | Button clicks, form submits, searches — **this is the bulk of LiveView usage** |
| `SomeLive.render` | After any assign change | Template rendering — can contain many child spans |
| `PUT /api/...` | API write request | REST API mutation (create/update) |
| `POST /api/...` | API write request | REST API create |
| `GET /api/...` | API read request | REST API read — list or show endpoints |
| `DELETE /api/...` | API delete request | REST API delete |
| `Elixir.Oban.* process` | Background jobs | Oban workers — not user-facing |

**For LiveView analysis:** HTTP `GET` traces for page paths are the *least* interesting for ongoing performance. After the first page load, everything is WebSocket. Focus on `handle_event`, `handle_params`, and `handle_info`.

**For API analysis:** Every API request is a full HTTP trace. The root span operation is `METHOD /path` (e.g., `PUT /api/v1/resources`).

### Child spans within a trace

Both LiveView and API traces contain similar nested spans from the Ash Framework:
- **Ash actions**: `domain:resource.action` (e.g., `accounts:user.read`, `inventory:item.list`)
- **Changesets**: `changeset:resource:action` — shows action setup including changes and validations
- **DB queries**: `<app>.repo.query:table_name` — actual SQL with timing (the repo prefix varies by project)
- **Calculations**: `resource:calculation:name`
- **Changes/Validations**: Individual Ash lifecycle steps (`change:*`, `validate:*`)

API traces additionally contain:
- **Auth pipeline**: Token validation, user loading — varies by auth setup
- **HTTP tags**: Root span contains `http.method`, `http.route`, `http.status_code`, `http.target` tags

## Workflow

### Step 1: Discover what's being traced

The user will typically tell you which LiveView or event to analyze. If not, start by listing all operations:

```bash
curl -s "http://jaeger:16686/api/operations?service=SERVICE_NAME" | python3 -c "
import json, sys
data = json.load(sys.stdin)['data']
for d in sorted(data, key=lambda x: x['name']):
    print(d['name'])
"
```

This tells you what LiveViews have been active and which events have been triggered. If the operation you need isn't here, you can generate traces yourself (see below) or ask the user to trigger it.

### Step 1b: Generate traces yourself (Tidewave-specific)

> **Note**: This step is for **Tidewave** agents that have access to `browser_eval`, `project_eval`, and `shell_eval` tools. Other agents (Copilot, Claude Code, etc.) should ask the user to trigger the operation instead.

If there are no recent traces for the operation you need, you don't have to wait for the user — you can trigger the operations directly. This is especially useful for post-change verification: make a code change, generate a trace, then analyze it immediately.

**For LiveView interactions** — use `browser_eval` to navigate to the page and interact with it:
```javascript
// Navigate to the page (generates mount + handle_params traces)
await browser.reload("/some-page");

// Interact with the page (generates handle_event traces)
await browser.click(browser.locator('button', { hasText: 'Submit' }));
```

After browser interactions, wait a few seconds for traces to be exported, then run the analysis script.

**For API endpoints** — use `shell_eval` with `curl` or `project_eval` with `:httpc`. You'll need a bearer token for authenticated endpoints — check the project-specific companion skill for how to obtain one.
```bash
# GET endpoint
curl -s -o /dev/null -w "%{http_code}" http://localhost:4000/api/v1/resource

# POST/PUT with payload
curl -s -X PUT http://localhost:4000/api/v1/resource \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer TOKEN" \
  -d '{"data": {"attributes": {...}}}'
```

**For Ash actions without HTTP** — use `project_eval` to call domain functions directly. These still generate OTEL spans:
```elixir
# Read action
MyApp.Domain.read!(MyApp.Resource, actor: actor)

# Create/update action
MyApp.Domain.create!(MyApp.Resource, %{name: "test"}, actor: actor)
```

**Timing tip**: After triggering an operation, the trace may take 1-2 seconds to appear in Jaeger. Use `--lookback 5m` when analyzing to narrow the window to your recent traces.

### Step 2: Fetch and analyze traces

Use the analysis script bundled with this skill. It handles the Jaeger API queries and produces a structured report. The script auto-detects both the service name (if only one exists) and the Ecto repo prefix from span data.

**To analyze a specific operation** (e.g., after modifying a handle_event):
```bash
python3 .claude/skills/jaeger-perf-analysis/scripts/analyze_traces.py \
  --operation "MyAppWeb.SomeLive.handle_event#some_event" \
  --lookback 1h
```

**To analyze an API endpoint:**
```bash
python3 .claude/skills/jaeger-perf-analysis/scripts/analyze_traces.py \
  --operation "PUT /api/v1/resources" \
  --lookback 1h
```

Note: API operations use "METHOD /path" format. Use the operations list from Step 1 to get the exact operation name.

**To get a broad overview** (e.g., to find the slowest things across the app):
```bash
python3 .claude/skills/jaeger-perf-analysis/scripts/analyze_traces.py \
  --min-duration 10ms \
  --lookback 1h
```

**To compare before/after** (e.g., verifying a change didn't slow things down):
```bash
# Before your change, capture a baseline:
python3 .claude/skills/jaeger-perf-analysis/scripts/analyze_traces.py \
  --operation "MyAppWeb.SomeLive.handle_event#target_event" \
  --lookback 30m --output /tmp/baseline.json

# After your change, have the user trigger the event again, then:
python3 .claude/skills/jaeger-perf-analysis/scripts/analyze_traces.py \
  --operation "MyAppWeb.SomeLive.handle_event#target_event" \
  --lookback 10m --output /tmp/after.json

# Compare:
python3 .claude/skills/jaeger-perf-analysis/scripts/analyze_traces.py \
  --compare /tmp/baseline.json /tmp/after.json
```

**If repo prefix auto-detection fails** (rare), you can specify it explicitly:
```bash
python3 .claude/skills/jaeger-perf-analysis/scripts/analyze_traces.py \
  --repo-prefix myapp.repo \
  --operation "..." --lookback 1h
```

### Step 3: Interpret the results

The script outputs a structured report. Here's how to read it and what to look for.

#### Key Metrics

- **Duration**: Total wall-clock time of the trace root span. For `handle_event`, this is how long the user waits before seeing a response.
- **Span count**: Total number of child spans. High span counts (100+) in a render trace signal that the template is triggering lots of Ash action setup during rendering.
- **DB query count and total DB time**: How many SQL queries fired and their cumulative time. Watch for high counts relative to what the operation should need.

#### Common Anti-Patterns to Look For

**1. Span explosion in renders (100+ spans)**

If a `SomeLive.render` trace has hundreds of spans, it usually means the template is calling functions that build Ash changesets for every row in a table — e.g., computing which action buttons to show per row. Each changeset triggers change/validation spans.

Signs: Many repeated `changeset:resource:action`, `change:*`, `validate:*` spans — often proportional to the number of rows displayed.

**2. N+1 queries**

The same `<repo>.query:some_table` appearing N times sequentially within a single action, where N correlates with a list of items. Look for the same SELECT on the same table repeating.

Example: `domain:resource.read` called N times individually when processing a list, loading one related record each time instead of batch-loading them.

**3. Duplicate data loading**

The same data being loaded multiple times across the trace — e.g., reading the same user record in both a plug pipeline and the LiveView mount, or re-loading data after a write that could use the return value.

Signs: Same `domain:resource.read` operation appearing in multiple places within one trace.

**4. Sequential queries that could be parallel or batched**

Multiple independent data loads happening one after another. The right fix depends on context:

- **In LiveView `mount`/`handle_params`**: Use `assign_async/3` to load independent data concurrently. Each key gets its own `AsyncResult` and the template can show loading states per-section. This is the idiomatic Phoenix approach — prefer it over `Task.async`.
- **In LiveView `handle_event`**: `assign_async/3` also works here for reads that update the UI. For fire-and-forget work, consider `start_async/3`.
- **In API actions / Ash actions**: Be careful — if the sequential reads happen **inside a database transaction**, you **cannot** parallelize them with `Task.async` because each task runs in its own process and won't share the transaction. Parallelization is only safe for reads that happen outside a transaction boundary. Within a transaction, prefer batching (e.g., loading all IDs in one query) over parallelizing.

Signs: Independent `domain:resource.read` spans executing sequentially with no data dependency.

**5. Post-write re-queries**

After an UPDATE + COMMIT, the trace shows immediate SELECT queries to reload the same data that was just written. The action's return value often already contains this data.

Signs: A `<repo>.query` UPDATE followed by SELECT on the same table right after commit.

**6. Auth pipeline duplication (API-specific)**

Every API request typically runs authentication (token validation, user loading). If the same user data is then re-loaded inside the action (e.g., for `created_by_id` resolution), that's a duplicate read.

Signs: The same user/actor read operation appearing both in the early part of the trace (auth) and later inside the action.

### Step 4: Report findings

When reporting to the user, structure your findings like this:

1. **Summary**: What operation was analyzed, how many traces, average/max duration
2. **Findings**: Specific issues found, ordered by impact (time saved × frequency)
3. **Evidence**: For each finding, reference the specific span pattern from the trace — operation names, counts, and timings
4. **Suggestion**: What could be changed, with enough context to act on

If this is a **post-change verification**, compare the new metrics against the baseline and call out:
- Duration change (faster/slower/same)
- Span count change (fewer/more/same)
- DB query count change
- Any new query patterns that weren't in the baseline
- For API endpoints: HTTP status codes (check for error traces with rollbacks)
