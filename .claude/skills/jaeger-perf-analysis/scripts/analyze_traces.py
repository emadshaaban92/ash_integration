#!/usr/bin/env python3
"""
Jaeger trace analyzer for Phoenix LiveView + Ash Framework apps and API endpoints.

Queries the Jaeger HTTP API and produces structured performance reports.
Designed to be used by AI agents for post-change verification and performance profiling.

Usage:
    # Auto-discover available services
    python3 analyze_traces.py --discover-services

    # Broad overview of slow traces (auto-detects service if only one exists)
    python3 analyze_traces.py --min-duration 10ms --lookback 1h

    # Specific LiveView operation analysis
    python3 analyze_traces.py --service MyApp --operation "MyAppWeb.SomeLive.handle_event#event" --lookback 1h

    # Specific API endpoint analysis
    python3 analyze_traces.py --service MyApp --operation "PUT /api/v1/resources" --lookback 1h

    # Override Jaeger URL (default: http://jaeger:16686)
    python3 analyze_traces.py --jaeger-url http://localhost:16686 --operation "..." --lookback 1h

    # Override repo prefix (default: auto-detected from spans)
    python3 analyze_traces.py --service MyApp --repo-prefix myapp.repo --operation "..." --lookback 1h

    # Save results for later comparison
    python3 analyze_traces.py --service MyApp --operation "..." --lookback 30m --output baseline.json

    # Compare two saved results
    python3 analyze_traces.py --compare baseline.json after.json
"""

import argparse
import json
import sys
import urllib.parse
import urllib.request
from collections import Counter, defaultdict

DEFAULT_JAEGER_URL = "http://jaeger:16686"
JAEGER_BASE = DEFAULT_JAEGER_URL


def fetch_json(url):
    """Fetch JSON from a URL."""
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"Error fetching {url}: {e}", file=sys.stderr)
        sys.exit(1)


def discover_services():
    """Discover available services from Jaeger."""
    data = fetch_json(f"{JAEGER_BASE}/api/services")
    return data.get("data", [])


def auto_detect_repo_prefix(spans):
    """Auto-detect the Ecto repo prefix from span operation names.

    Looks for spans matching the pattern '<something>.repo.query' and returns
    the most common prefix. Falls back to None if no repo spans are found.
    """
    repo_ops = Counter()
    for s in spans:
        op = s["operationName"]
        # Match pattern: something.repo.query or something.repo.query:table
        if ".repo.query" in op:
            prefix = op.split(":")[0]  # e.g., "myapp.repo.query"
            repo_ops[prefix] += 1

    if repo_ops:
        most_common = repo_ops.most_common(1)[0][0]
        # Return the prefix without ".query" — e.g., "myapp.repo"
        return most_common.replace(".query", "")
    return None


def parse_duration(s):
    """Parse a duration string like '10ms', '1s', '500us' into microseconds."""
    s = s.strip().lower()
    if s.endswith("ms"):
        return int(float(s[:-2]) * 1000)
    elif s.endswith("us"):
        return int(float(s[:-2]))
    elif s.endswith("s"):
        return int(float(s[:-1]) * 1_000_000)
    else:
        return int(s)


def fetch_traces(service, operation=None, lookback="1h", min_duration=None, limit=200):
    """Fetch traces from the Jaeger API."""
    params = {
        "service": service,
        "limit": str(limit),
        "lookback": lookback,
    }
    if operation:
        params["operation"] = operation
    if min_duration:
        params["minDuration"] = min_duration

    url = f"{JAEGER_BASE}/api/traces?{urllib.parse.urlencode(params)}"
    data = fetch_json(url)
    return data.get("data", [])


def analyze_trace(trace, repo_prefix=None):
    """Analyze a single trace and return a structured summary."""
    spans = trace["spans"]
    if not spans:
        return None

    # Auto-detect repo prefix from this trace's spans if not provided
    if not repo_prefix:
        repo_prefix = auto_detect_repo_prefix(spans)
    repo_query_prefix = f"{repo_prefix}.query" if repo_prefix else None

    # Find root span (no parent references)
    roots = [s for s in spans if not s.get("references")]
    if not roots:
        roots = [max(spans, key=lambda s: s["duration"])]
    root = roots[0]

    # Sort spans by start time
    sorted_spans = sorted(spans, key=lambda s: s["startTime"])
    root_start = sorted_spans[0]["startTime"]

    # Extract HTTP tags from root span (relevant for API traces)
    # Supports both old (http.method) and new (http.request.method) OTEL semantic conventions
    root_tags = {t["key"]: t["value"] for t in root.get("tags", [])}
    http_info = {}
    http_method = root_tags.get("http.request.method", root_tags.get("http.method"))
    if http_method:
        http_info["method"] = http_method
        http_info["route"] = root_tags.get("http.route", root_tags.get("http.target", root_tags.get("url.path", "")))
        http_info["status_code"] = root_tags.get("http.response.status_code", root_tags.get("http.status_code", None))
        if root_tags.get("phoenix.plug"):
            http_info["controller"] = root_tags["phoenix.plug"]
        if root_tags.get("phoenix.action"):
            http_info["action"] = root_tags["phoenix.action"]

    # Classify trace type — uses "/api/" as default heuristic, works with any route prefix
    root_op = root["operationName"]
    route = http_info.get("route", root_op)
    if http_method in ("PUT", "POST", "PATCH", "DELETE") and "/api/" in route:
        trace_type = "api_write"
    elif http_method == "GET" and "/api/" in route:
        trace_type = "api_read"
    elif any(kw in root_op for kw in ["handle_event", "handle_params", ".mount", ".render"]):
        trace_type = "liveview"
    elif root_op.startswith("GET ") or root_op.startswith("GET\t") or http_method == "GET":
        trace_type = "page_load"
    else:
        trace_type = "other"

    # Detect failed requests (rollback instead of commit)
    has_rollback = False
    for s in spans:
        tags = {t["key"]: t["value"] for t in s.get("tags", [])}
        stmt = tags.get("db.statement", "").strip().lower()
        if stmt == "rollback":
            has_rollback = True
            break

    # Count operations and durations
    op_counts = Counter()
    op_durations = Counter()
    db_queries = []
    ash_actions = []

    for s in spans:
        op = s["operationName"]
        dur = s["duration"]
        op_counts[op] += 1
        op_durations[op] += dur

        tags = {t["key"]: t["value"] for t in s.get("tags", [])}

        if "db.statement" in tags:
            db_queries.append({
                "operation": op,
                "statement": tags["db.statement"][:120],
                "duration_us": dur,
                "source": tags.get("source", ""),
            })
        elif ":" in op and (not repo_prefix or not op.startswith(repo_prefix)):
            ash_actions.append({
                "operation": op,
                "duration_us": dur,
            })

    # Build waterfall (spans with timing offsets)
    waterfall = []
    for s in sorted_spans:
        tags = {t["key"]: t["value"] for t in s.get("tags", [])}
        stmt = tags.get("db.statement", "")
        if stmt and len(stmt) > 80:
            stmt = stmt[:80] + "..."
        waterfall.append({
            "offset_ms": round((s["startTime"] - root_start) / 1000, 1),
            "duration_ms": round(s["duration"] / 1000, 1),
            "operation": s["operationName"],
            "db_statement": stmt,
        })

    # Detect patterns
    patterns = detect_patterns(spans, root_start, trace_type, repo_prefix=repo_prefix)

    result = {
        "trace_id": trace["traceID"],
        "root_operation": root["operationName"],
        "trace_type": trace_type,
        "total_duration_ms": round(root["duration"] / 1000, 1),
        "span_count": len(spans),
        "db_query_count": len(db_queries),
        "db_total_ms": round(sum(q["duration_us"] for q in db_queries) / 1000, 1),
        "operation_summary": [
            {
                "operation": op,
                "count": op_counts[op],
                "total_ms": round(op_durations[op] / 1000, 1),
                "avg_ms": round(op_durations[op] / op_counts[op] / 1000, 2),
            }
            for op, _ in op_durations.most_common(25)
        ],
        "patterns": patterns,
        "waterfall": waterfall,
    }

    if repo_prefix:
        result["repo_prefix"] = repo_prefix
    if http_info:
        result["http"] = http_info
    if has_rollback:
        result["failed"] = True
        result["patterns"].append({
            "type": "failed_request",
            "severity": "info",
            "description": "Request ended with rollback — indicates validation failure or constraint violation",
        })

    return result


def detect_patterns(spans, root_start, trace_type="other", repo_prefix=None):
    """Detect common anti-patterns in a trace."""
    patterns = []

    # Group DB queries by table/source
    table_queries = defaultdict(list)
    for s in spans:
        tags = {t["key"]: t["value"] for t in s.get("tags", [])}
        if "db.statement" in tags:
            source = tags.get("source", "unknown")
            table_queries[source].append({
                "statement": tags["db.statement"][:200],
                "duration_us": s["duration"],
                "start_time": s["startTime"],
            })

    # N+1 detection: same table queried many times with similar statements
    for table, queries in table_queries.items():
        if table in ("", "unknown"):
            continue
        if len(queries) >= 3:
            # Check if statements look similar (same prefix)
            stmts = [q["statement"][:60] for q in queries]
            most_common_prefix = Counter(stmts).most_common(1)
            if most_common_prefix and most_common_prefix[0][1] >= 3:
                patterns.append({
                    "type": "n_plus_1",
                    "severity": "high" if len(queries) >= 5 else "medium",
                    "description": f"Table '{table}' queried {len(queries)} times with similar statements",
                    "query_count": len(queries),
                    "total_duration_ms": round(sum(q["duration_us"] for q in queries) / 1000, 1),
                    "sample_statement": most_common_prefix[0][0],
                })

    # Span explosion in renders (Ash-generic: changeset/change/validate prefixes)
    changeset_spans = [s for s in spans if s["operationName"].startswith("changeset:")]
    change_spans = [s for s in spans if s["operationName"].startswith("change:") or s["operationName"].startswith("change condition:")]
    validate_spans = [s for s in spans if s["operationName"].startswith("validate:")]
    total_action_setup = len(changeset_spans) + len(change_spans) + len(validate_spans)
    if total_action_setup > 50:
        action_types = Counter(s["operationName"] for s in changeset_spans)
        patterns.append({
            "type": "render_span_explosion",
            "severity": "high" if total_action_setup > 200 else "medium",
            "description": f"{total_action_setup} changeset/change/validation spans — likely computing row-level action availability during render",
            "changeset_count": len(changeset_spans),
            "change_count": len(change_spans),
            "validate_count": len(validate_spans),
            "action_types": dict(action_types.most_common(10)),
        })

    # Duplicate data loading: same read action appearing multiple times
    read_actions = defaultdict(int)
    for s in spans:
        op = s["operationName"]
        if ".read" in op or ".by_id" in op or ".get" in op:
            read_actions[op] += 1
    duplicates = {op: count for op, count in read_actions.items() if count >= 2}
    if duplicates:
        patterns.append({
            "type": "duplicate_reads",
            "severity": "medium",
            "description": "Same read action called multiple times within one trace",
            "duplicates": duplicates,
        })

    # Sequential independent queries (heuristic: multiple domain:resource.read in a row)
    sorted_spans = sorted(spans, key=lambda s: s["startTime"])
    sequential_reads = []
    for i, s in enumerate(sorted_spans):
        op = s["operationName"]
        if any(x in op for x in [".read", ".index"]) and ":" in op:
            sequential_reads.append((op, s["startTime"], s["duration"]))

    if len(sequential_reads) >= 3:
        # Check if they're sequential (non-overlapping)
        sequential_count = 0
        for i in range(1, len(sequential_reads)):
            prev_end = sequential_reads[i - 1][1] + sequential_reads[i - 1][2]
            curr_start = sequential_reads[i][1]
            if curr_start >= prev_end:
                sequential_count += 1
        if sequential_count >= 2:
            total_ms = round(sum(r[2] for r in sequential_reads) / 1000, 1)
            patterns.append({
                "type": "sequential_reads",
                "severity": "low",
                "description": f"{len(sequential_reads)} read actions executed sequentially — in LiveView, consider assign_async/3; in actions, prefer batching (parallelization may break transaction boundaries)",
                "total_ms": total_ms,
                "actions": [r[0] for r in sequential_reads],
            })

    # Post-write re-query detection: UPDATE/INSERT followed by SELECT on same table
    if repo_prefix:
        repo_query_op = f"{repo_prefix}.query"
        db_spans_ordered = [
            (s, {t["key"]: t["value"] for t in s.get("tags", [])})
            for s in sorted_spans
            if s["operationName"].startswith(repo_query_op)
        ]
        for i in range(len(db_spans_ordered) - 1):
            _s1, tags1 = db_spans_ordered[i]
            _s2, tags2 = db_spans_ordered[i + 1]
            stmt1 = tags1.get("db.statement", "").strip().upper()
            stmt2 = tags2.get("db.statement", "").strip().upper()
            source1 = tags1.get("source", "")
            source2 = tags2.get("source", "")
            if (stmt1.startswith("UPDATE") or stmt1.startswith("INSERT")) and stmt2.startswith("SELECT"):
                if source1 and source1 == source2:
                    patterns.append({
                        "type": "post_write_requery",
                        "severity": "low",
                        "description": f"SELECT on '{source1}' immediately after write — the action's return value may already contain this data",
                        "table": source1,
                    })

    # API-specific: detect duplicate resource loading (auth phase vs. action phase)
    if trace_type in ("api_write", "api_read"):
        all_reads = []
        for s in sorted_spans:
            op = s["operationName"]
            if ".read" in op and ":" in op:
                all_reads.append({
                    "op": op,
                    "start": s["startTime"],
                    "duration": s["duration"],
                })

        if len(all_reads) >= 2:
            # Split into first-third (likely auth) and rest (likely action)
            trace_duration = max(s["startTime"] + s["duration"] for s in spans) - root_start
            auth_boundary = root_start + trace_duration // 3

            auth_reads = Counter()
            action_reads = Counter()
            for r in all_reads:
                if r["start"] < auth_boundary:
                    auth_reads[r["op"]] += 1
                else:
                    action_reads[r["op"]] += 1

            overlapping = set(auth_reads.keys()) & set(action_reads.keys())
            if overlapping:
                patterns.append({
                    "type": "auth_reload_duplication",
                    "severity": "medium",
                    "description": f"Same resource(s) loaded during auth and again inside the action: {', '.join(overlapping)}. Consider passing the actor through instead of re-loading.",
                    "auth_reads": dict(auth_reads),
                    "action_reads": dict(action_reads),
                    "overlapping_operations": list(overlapping),
                })

    return patterns


def print_overview(traces, service):
    """Print a broad overview of all traces grouped by operation."""
    stats = defaultdict(list)
    for t in traces:
        spans = t["spans"]
        longest = max(spans, key=lambda s: s["duration"])
        op = longest["operationName"]
        stats[op].append({
            "dur": longest["duration"] / 1000,
            "spans": len(spans),
            "tid": t["traceID"],
        })

    print(f"\n{'=' * 100}")
    print(f"  TRACE OVERVIEW — {service} — {len(traces)} traces")
    print(f"{'=' * 100}\n")

    rows = []
    for op, items in stats.items():
        avg = sum(i["dur"] for i in items) / len(items)
        mx = max(i["dur"] for i in items)
        avg_spans = sum(i["spans"] for i in items) / len(items)
        rows.append((op, len(items), avg, mx, avg_spans))
    rows.sort(key=lambda r: -r[3])

    print(f"  {'Operation':<65s} {'Count':>5s} {'Avg':>9s} {'Max':>9s} {'Spans':>7s}")
    print(f"  {'-' * 96}")
    for op, count, avg, mx, avg_spans in rows:
        marker = ""
        if any(kw in op for kw in ["handle_event", "handle_params", ".mount", ".render"]):
            marker = " [LV]"
        elif any(op.startswith(m + " /api/") for m in ("GET", "POST", "PUT", "PATCH", "DELETE")):
            marker = " [API]"
        elif any(op.startswith(m + " ") for m in ("GET", "POST", "PUT", "PATCH", "DELETE")):
            marker = " [HTTP]"
        print(f"  {op[:65]:<65s} {count:5d} {avg:8.1f}ms {mx:8.1f}ms {avg_spans:6.1f}{marker}")

    print(f"\n  ([LV] = LiveView operation, [API] = API endpoint, [HTTP] = HTTP request)\n")


def print_operation_analysis(traces, operation, repo_prefix=None):
    """Print detailed analysis for a specific operation."""
    analyses = []
    for t in traces:
        a = analyze_trace(t, repo_prefix=repo_prefix)
        if a:
            analyses.append(a)

    if not analyses:
        print(f"No traces found for operation: {operation}")
        return

    analyses.sort(key=lambda a: -a["total_duration_ms"])

    # Aggregate stats
    durations = [a["total_duration_ms"] for a in analyses]
    span_counts = [a["span_count"] for a in analyses]
    db_counts = [a["db_query_count"] for a in analyses]
    db_times = [a["db_total_ms"] for a in analyses]

    avg_dur = sum(durations) / len(durations)
    max_dur = max(durations)
    min_dur = min(durations)

    # Report auto-detected repo prefix
    detected_prefix = next((a.get("repo_prefix") for a in analyses if a.get("repo_prefix")), None)

    print(f"\n{'=' * 100}")
    print(f"  OPERATION ANALYSIS: {operation}")
    print(f"{'=' * 100}\n")

    if detected_prefix:
        print(f"  Repo prefix:      {detected_prefix} (auto-detected)")

    # Show trace type and HTTP info if available
    trace_types = Counter(a.get("trace_type", "unknown") for a in analyses)
    failed_count = sum(1 for a in analyses if a.get("failed"))
    if trace_types:
        types_str = ", ".join(f"{t}={c}" for t, c in trace_types.most_common())
        print(f"  Trace type:       {types_str}")
    if failed_count > 0:
        print(f"  Failed requests:  {failed_count}/{len(analyses)} (ended in rollback)")
    http_info = next((a["http"] for a in analyses if "http" in a), None)
    if http_info:
        status = http_info.get("status_code", "N/A")
        print(f"  HTTP:             {http_info.get('method', '?')} {http_info.get('route', '?')} (status: {status})")

    # Separate successful and failed for stats
    successful = [a for a in analyses if not a.get("failed")]

    print(f"\n  Traces analyzed:  {len(analyses)}" + (f" ({len(successful)} successful, {failed_count} failed)" if failed_count else ""))
    print(f"  Duration:         avg={avg_dur:.1f}ms  min={min_dur:.1f}ms  max={max_dur:.1f}ms")
    print(f"  Span count:       avg={sum(span_counts)/len(span_counts):.0f}  max={max(span_counts)}")
    print(f"  DB queries:       avg={sum(db_counts)/len(db_counts):.0f}  max={max(db_counts)}")
    print(f"  DB time:          avg={sum(db_times)/len(db_times):.1f}ms  max={max(db_times):.1f}ms")

    # Patterns across all traces
    all_patterns = defaultdict(list)
    for a in analyses:
        for p in a["patterns"]:
            all_patterns[p["type"]].append(p)

    if all_patterns:
        print(f"\n  DETECTED PATTERNS:")
        print(f"  {'-' * 60}")
        for ptype, instances in all_patterns.items():
            count = len(instances)
            freq = count / len(analyses) * 100
            sample = instances[0]
            severity = sample["severity"].upper()
            print(f"\n  [{severity}] {sample['description']}")
            print(f"    Frequency: {count}/{len(analyses)} traces ({freq:.0f}%)")
            for key, val in sample.items():
                if key not in ("type", "severity", "description"):
                    print(f"    {key}: {val}")

    # Detailed waterfall for the slowest trace
    slowest = analyses[0]
    print(f"\n  WATERFALL (slowest trace: {slowest['trace_id'][:16]}... — {slowest['total_duration_ms']}ms)")
    print(f"  {'-' * 96}")
    for step in slowest["waterfall"]:
        db = f"  {step['db_statement']}" if step["db_statement"] else ""
        print(f"  {step['offset_ms']:8.1f}ms +{step['duration_ms']:7.1f}ms  {step['operation'][:55]:<55s}{db}")

    print()


def print_comparison(baseline_data, after_data):
    """Compare two analysis results."""
    print(f"\n{'=' * 100}")
    print(f"  BEFORE / AFTER COMPARISON")
    print(f"{'=' * 100}\n")

    b = baseline_data
    a = after_data

    def stats(analyses):
        durs = [x["total_duration_ms"] for x in analyses]
        spans = [x["span_count"] for x in analyses]
        dbs = [x["db_query_count"] for x in analyses]
        return {
            "count": len(analyses),
            "avg_dur": sum(durs) / len(durs) if durs else 0,
            "max_dur": max(durs) if durs else 0,
            "avg_spans": sum(spans) / len(spans) if spans else 0,
            "avg_db": sum(dbs) / len(dbs) if dbs else 0,
        }

    bs = stats(b)
    as_ = stats(a)

    def delta(before, after, lower_is_better=True):
        if before == 0:
            return "N/A"
        pct = (after - before) / before * 100
        if abs(pct) < 0.1:
            return "no change"
        direction = "faster" if (pct < 0 and lower_is_better) else "slower" if (pct > 0 and lower_is_better) else "better" if pct < 0 else "worse"
        return f"{pct:+.1f}% ({direction})"

    print(f"  {'Metric':<25s} {'Before':>12s} {'After':>12s} {'Change':>20s}")
    print(f"  {'-' * 72}")
    print(f"  {'Traces':<25s} {bs['count']:>12d} {as_['count']:>12d}")
    print(f"  {'Avg duration':<25s} {bs['avg_dur']:>11.1f}ms {as_['avg_dur']:>11.1f}ms {delta(bs['avg_dur'], as_['avg_dur']):>20s}")
    print(f"  {'Max duration':<25s} {bs['max_dur']:>11.1f}ms {as_['max_dur']:>11.1f}ms {delta(bs['max_dur'], as_['max_dur']):>20s}")
    print(f"  {'Avg span count':<25s} {bs['avg_spans']:>12.0f} {as_['avg_spans']:>12.0f} {delta(bs['avg_spans'], as_['avg_spans']):>20s}")
    print(f"  {'Avg DB queries':<25s} {bs['avg_db']:>12.0f} {as_['avg_db']:>12.0f} {delta(bs['avg_db'], as_['avg_db']):>20s}")

    # Pattern comparison
    def collect_patterns(analyses):
        patterns = defaultdict(int)
        for a in analyses:
            for p in a.get("patterns", []):
                patterns[p["type"]] += 1
        return dict(patterns)

    bp = collect_patterns(b)
    ap = collect_patterns(a)
    all_types = set(list(bp.keys()) + list(ap.keys()))

    if all_types:
        print(f"\n  {'Pattern':<30s} {'Before':>10s} {'After':>10s}")
        print(f"  {'-' * 52}")
        for pt in sorted(all_types):
            bc = bp.get(pt, 0)
            ac = ap.get(pt, 0)
            indicator = " FIXED!" if ac == 0 and bc > 0 else " NEW!" if bc == 0 and ac > 0 else ""
            print(f"  {pt:<30s} {bc:>10d} {ac:>10d}{indicator}")

    print()


def main():
    parser = argparse.ArgumentParser(description="Analyze Jaeger traces for Phoenix LiveView + Ash Framework performance")
    parser.add_argument("--service", help="Jaeger service name (auto-detected if only one service exists)")
    parser.add_argument("--operation", help="Specific operation to analyze")
    parser.add_argument("--lookback", default="1h", help="How far back to search (e.g., '1h', '30m', '24h')")
    parser.add_argument("--min-duration", help="Minimum trace duration (e.g., '10ms', '100ms')")
    parser.add_argument("--limit", type=int, default=200, help="Maximum number of traces to fetch")
    parser.add_argument("--repo-prefix", help="Ecto repo span prefix (e.g., 'myapp.repo'). Auto-detected from spans if omitted.")
    parser.add_argument("--output", help="Save analysis results to JSON file for later comparison")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"), help="Compare two saved JSON results")
    parser.add_argument("--json", action="store_true", help="Output raw JSON instead of formatted text")
    parser.add_argument("--jaeger-url", default=DEFAULT_JAEGER_URL, help=f"Jaeger base URL (default: {DEFAULT_JAEGER_URL})")
    parser.add_argument("--discover-services", action="store_true", help="List available Jaeger services and exit")

    args = parser.parse_args()

    global JAEGER_BASE
    JAEGER_BASE = args.jaeger_url.rstrip("/")

    # Service discovery mode
    if args.discover_services:
        services = discover_services()
        if services:
            print("Available Jaeger services:")
            for s in sorted(services):
                print(f"  - {s}")
        else:
            print("No services found in Jaeger.")
        return

    # Comparison mode
    if args.compare:
        with open(args.compare[0]) as f:
            baseline = json.load(f)
        with open(args.compare[1]) as f:
            after = json.load(f)
        print_comparison(baseline, after)
        return

    # Auto-detect service if not specified
    if not args.service:
        services = discover_services()
        non_jaeger = [s for s in services if s not in ("jaeger-query", "jaeger-all-in-one", "jaeger")]
        if len(non_jaeger) == 1:
            args.service = non_jaeger[0]
            print(f"Auto-detected service: {args.service}", file=sys.stderr)
        elif non_jaeger:
            print(f"Multiple services found: {', '.join(non_jaeger)}", file=sys.stderr)
            print("Please specify --service", file=sys.stderr)
            sys.exit(1)
        else:
            print("No services found. Use --discover-services to check, or specify --service.", file=sys.stderr)
            sys.exit(1)

    # Fetch traces
    min_dur = None
    if args.min_duration:
        min_dur = args.min_duration

    traces = fetch_traces(
        service=args.service,
        operation=args.operation,
        lookback=args.lookback,
        min_duration=min_dur,
        limit=args.limit,
    )

    if not traces:
        print(f"No traces found for service={args.service}" +
              (f", operation={args.operation}" if args.operation else "") +
              (f", minDuration={min_dur}" if min_dur else ""))
        return

    # Analyze
    if args.operation:
        # Detailed analysis for a specific operation
        analyses = [analyze_trace(t, repo_prefix=args.repo_prefix) for t in traces]
        analyses = [a for a in analyses if a]

        if args.output:
            with open(args.output, "w") as f:
                json.dump(analyses, f, indent=2)
            print(f"Saved {len(analyses)} trace analyses to {args.output}")

        if args.json:
            print(json.dumps(analyses, indent=2))
        else:
            print_operation_analysis(traces, args.operation, repo_prefix=args.repo_prefix)
    else:
        # Broad overview
        if args.json:
            analyses = [analyze_trace(t, repo_prefix=args.repo_prefix) for t in traces]
            analyses = [a for a in analyses if a]
            print(json.dumps(analyses, indent=2))
        else:
            print_overview(traces, args.service)

            # Also show detailed analysis for the slowest LiveView + API traces
            interesting_traces = []
            for t in traces:
                longest = max(t["spans"], key=lambda s: s["duration"])
                op = longest["operationName"]
                is_lv = any(kw in op for kw in ["handle_event", "handle_params", ".mount", ".render"])
                is_api = any(op.startswith(m + " /api/") for m in ("GET", "POST", "PUT", "PATCH", "DELETE"))
                if is_lv or is_api:
                    label = "[LV]" if is_lv else "[API]"
                    interesting_traces.append((op, longest["duration"] / 1000, t, label))

            if interesting_traces:
                interesting_traces.sort(key=lambda x: -x[1])
                print(f"  TOP TRACES — Pattern Analysis (LiveView + API)")
                print(f"  {'=' * 70}\n")
                seen_ops = set()
                shown = 0
                for op, dur, t, label in interesting_traces:
                    if op in seen_ops or shown >= 5:
                        continue
                    seen_ops.add(op)
                    shown += 1
                    a = analyze_trace(t, repo_prefix=args.repo_prefix)
                    if a and a["patterns"]:
                        failed_marker = " [FAILED]" if a.get("failed") else ""
                        print(f"  {label} {op} ({dur:.1f}ms, {len(t['spans'])} spans){failed_marker}:")
                        for p in a["patterns"]:
                            print(f"    [{p['severity'].upper()}] {p['description']}")
                        print()


if __name__ == "__main__":
    main()
