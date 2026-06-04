#!/usr/bin/env python3

import asyncio
import aiohttp
import time
import argparse
import sys
from datetime import datetime

ENDPOINT = "https://llm-ops.akamai-poc.online/v1/chat/completions"
MODEL = "qwen25-7b"

# ── Prompt banks ────────────────────────────────────────────────────────────

# Long system prompt — consumes KV cache blocks on every request
SYSTEM_PROMPT = (
    "You are an expert Kubernetes and cloud infrastructure engineer with 15 years "
    "of experience at hyperscalers. You have deep knowledge of GPU computing, LLM "
    "inference infrastructure, distributed systems, autoscaling, observability, and "
    "production reliability engineering. Always provide detailed, technically precise "
    "answers with specific examples, configuration snippets, and architectural "
    "considerations. Consider performance, reliability, cost, and operational "
    "complexity in every response. Never give a short answer when a detailed one "
    "is more useful."
)

# Long-context prompts — designed to fill KV cache
LONG_PROMPTS = [
    "Write a comprehensive technical guide on how vLLM implements PagedAttention, "
    "including the memory management algorithm, block table structure, KV cache "
    "allocation strategy, and how it compares to traditional attention mechanisms. "
    "Include specific memory calculations for a 7B parameter model on a 20GB GPU.",

    "Design a complete production-grade LLM inference platform on Kubernetes covering "
    "model serving, autoscaling, observability, multi-tenancy, cost optimization, "
    "disaster recovery, and security. Include specific Helm chart configurations, "
    "KEDA ScaledObject specs, Prometheus alert rules, and network policies.",

    "Explain in exhaustive detail how KEDA integrates with Kubernetes HPA, including "
    "the full reconciliation loop, ScaledObject lifecycle, metric evaluation pipeline, "
    "cooldown mechanics, and how it handles edge cases like metric unavailability, "
    "rapid load spikes, and scale-to-zero transitions.",

    "Write a detailed comparison of vLLM, TGI, Triton Inference Server, TensorRT-LLM, "
    "and Ray Serve for production LLM serving, covering throughput benchmarks, "
    "memory efficiency, batching strategies, hardware compatibility, operational "
    "complexity, and recommended use cases for each.",

    "Describe the complete architecture of a multi-region LLM serving platform on "
    "Akamai Connected Cloud, including GTM-based traffic routing, LKE cluster "
    "federation, cross-region observability, model weight distribution strategy, "
    "failover mechanisms, and cost optimization across regions.",
]

# Short prompts — designed to spike queue depth via volume
SHORT_PROMPTS = [
    "What is KV cache in LLM inference?",
    "How does KEDA autoscaling work?",
    "Explain GPU memory bandwidth.",
    "What is PagedAttention?",
    "How does vLLM handle batching?",
    "What is tensor parallelism?",
    "Explain prefill vs decode phases.",
    "What is the TTFT metric?",
    "How does Prometheus scrape metrics?",
    "What is a ServiceMonitor in Kubernetes?",
]

# ── Stats ────────────────────────────────────────────────────────────────────

stats = {
    "sent": 0,
    "completed": 0,
    "failed": 0,
    "total_tokens": 0,
    "start_time": None,
}

# ── Request sender ───────────────────────────────────────────────────────────

async def send_request(
    session: aiohttp.ClientSession,
    prompt: str,
    request_id: int,
    max_tokens: int = 500,
    use_system: bool = True,
) -> None:
    messages = []
    if use_system:
        messages.append({"role": "system", "content": SYSTEM_PROMPT})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": MODEL,
        "messages": messages,
        "max_tokens": max_tokens,
        "stream": False,  # non-streaming for load test — faster turnaround
    }

    start = time.time()
    try:
        async with session.post(
            ENDPOINT,
            json=payload,
            timeout=aiohttp.ClientTimeout(total=180)
        ) as resp:
            if resp.status == 200:
                data = await resp.json()
                tokens = data.get("usage", {}).get("total_tokens", 0)
                latency = time.time() - start
                stats["completed"] += 1
                stats["total_tokens"] += tokens
                print(
                    f"[{datetime.now().strftime('%H:%M:%S')}] "
                    f" #{request_id:04d} "
                    f"{tokens:4d} tok "
                    f"{latency:5.1f}s "
                    f"| {prompt[:45]}..."
                )
            else:
                body = await resp.text()
                stats["failed"] += 1
                print(
                    f"[{datetime.now().strftime('%H:%M:%S')}] "
                    f" #{request_id:04d} HTTP {resp.status} — {body[:80]}"
                )
    except asyncio.TimeoutError:
        stats["failed"] += 1
        print(f"[{datetime.now().strftime('%H:%M:%S')}] ⏱  #{request_id:04d} timeout")
    except Exception as e:
        stats["failed"] += 1
        print(f"[{datetime.now().strftime('%H:%M:%S')}] ❌ #{request_id:04d} {e}")

# ── Stats printer ────────────────────────────────────────────────────────────

async def print_stats_loop(duration: int) -> None:
    while True:
        await asyncio.sleep(20)
        elapsed = time.time() - stats["start_time"]
        if elapsed > duration + 10:
            break
        rps = stats["completed"] / elapsed if elapsed > 0 else 0
        tps = stats["total_tokens"] / elapsed if elapsed > 0 else 0
        inflight = stats["sent"] - stats["completed"] - stats["failed"]
        print(
            f"\n [{datetime.now().strftime('%H:%M:%S')}] "
            f"sent={stats['sent']} "
            f"done={stats['completed']} "
            f"failed={stats['failed']} "
            f"inflight={inflight} "
            f"RPS={rps:.2f} "
            f"tok/s={tps:.0f}\n"
        )

# ── Mode runners ─────────────────────────────────────────────────────────────

async def run_kv_cache_mode(duration: int, concurrency: int) -> None:
    """
    KV Cache spike mode — long prompts + long outputs.
    Goal: push kv_cache_usage_perc > 70% to trigger KEDA second trigger.
    """
    print(f"\n KV CACHE MODE — long context, {concurrency} concurrent, {duration}s")
    print("   Watch: KV Cache Usage % panel → should cross 70% threshold\n")

    sem = asyncio.Semaphore(concurrency)
    connector = aiohttp.TCPConnector(limit=concurrency + 5)

    async with aiohttp.ClientSession(connector=connector) as session:
        stats_task = asyncio.create_task(print_stats_loop(duration))
        tasks = set()
        end_time = time.time() + duration
        rid = 0

        async def bounded(prompt, id):
            async with sem:
                await send_request(session, prompt, id, max_tokens=800, use_system=True)

        while time.time() < end_time:
            prompt = LONG_PROMPTS[rid % len(LONG_PROMPTS)]
            t = asyncio.create_task(bounded(prompt, rid))
            tasks.add(t)
            t.add_done_callback(tasks.discard)
            stats["sent"] += 1
            rid += 1
            await asyncio.sleep(0.3)

        if tasks:
            print(f"\n Draining {len(tasks)} in-flight requests...")
            await asyncio.gather(*tasks, return_exceptions=True)
        stats_task.cancel()


async def run_queue_depth_mode(duration: int, concurrency: int) -> None:
    """
    Queue depth spike mode — many short requests fired rapidly.
    Goal: push num_requests_waiting > 2 to trigger KEDA primary trigger.
    """
    print(f"\n QUEUE DEPTH MODE — short prompts, {concurrency} concurrent, {duration}s")
    print("   Watch: Requests Waiting panel → should cross threshold of 2\n")

    sem = asyncio.Semaphore(concurrency)
    connector = aiohttp.TCPConnector(limit=concurrency + 5)

    async with aiohttp.ClientSession(connector=connector) as session:
        stats_task = asyncio.create_task(print_stats_loop(duration))
        tasks = set()
        end_time = time.time() + duration
        rid = 0

        async def bounded(prompt, id):
            async with sem:
                await send_request(session, prompt, id, max_tokens=150, use_system=False)

        while time.time() < end_time:
            prompt = SHORT_PROMPTS[rid % len(SHORT_PROMPTS)]
            t = asyncio.create_task(bounded(prompt, rid))
            tasks.add(t)
            t.add_done_callback(tasks.discard)
            stats["sent"] += 1
            rid += 1
            await asyncio.sleep(0.05)  # fire fast — 20 req/s

        if tasks:
            print(f"\n Draining {len(tasks)} in-flight requests...")
            await asyncio.gather(*tasks, return_exceptions=True)
        stats_task.cancel()


async def run_combined_mode(duration: int, concurrency: int) -> None:
    """
    Combined mode — mix of long and short requests simultaneously.
    Goal: spike both triggers at the same time for maximum Grafana drama.
    """
    print(f"\n COMBINED MODE — mixed workload, {concurrency} concurrent, {duration}s")
    print("   Watch: ALL panels — KV cache + queue depth + GPU util + replicas\n")

    # 70% long context, 30% short
    all_prompts = LONG_PROMPTS * 7 + SHORT_PROMPTS * 3
    max_tokens_map = {p: 600 for p in LONG_PROMPTS}
    for p in SHORT_PROMPTS:
        max_tokens_map[p] = 150

    sem = asyncio.Semaphore(concurrency)
    connector = aiohttp.TCPConnector(limit=concurrency + 5)

    async with aiohttp.ClientSession(connector=connector) as session:
        stats_task = asyncio.create_task(print_stats_loop(duration))
        tasks = set()
        end_time = time.time() + duration
        rid = 0

        async def bounded(prompt, id):
            async with sem:
                use_sys = prompt in LONG_PROMPTS
                mt = max_tokens_map.get(prompt, 300)
                await send_request(session, prompt, id, max_tokens=mt, use_system=use_sys)

        while time.time() < end_time:
            prompt = all_prompts[rid % len(all_prompts)]
            t = asyncio.create_task(bounded(prompt, rid))
            tasks.add(t)
            t.add_done_callback(tasks.discard)
            stats["sent"] += 1
            rid += 1
            await asyncio.sleep(0.2)

        if tasks:
            print(f"\n Draining {len(tasks)} in-flight requests...")
            await asyncio.gather(*tasks, return_exceptions=True)
        stats_task.cancel()

# ── Main ─────────────────────────────────────────────────────────────────────

def print_summary(elapsed: float) -> None:
    rps = stats["completed"] / elapsed if elapsed > 0 else 0
    tps = stats["total_tokens"] / elapsed if elapsed > 0 else 0
    success_rate = (stats["completed"] / stats["sent"] * 100) if stats["sent"] > 0 else 0
    print(f"""
╔══════════════════════════════════════════════════════════╗
║                    Load Test Complete                    ║
╠══════════════════════════════════════════════════════════╣
║  Duration      : {f'{elapsed:.1f}s':<41} ║
║  Requests sent : {str(stats['sent']):<41} ║
║  Completed     : {str(stats['completed']):<41} ║
║  Failed        : {str(stats['failed']):<41} ║
║  Success rate  : {f'{success_rate:.1f}%':<41} ║
║  Total tokens  : {str(stats['total_tokens']):<41} ║
║  Avg RPS       : {f'{rps:.2f}':<41} ║
║  Avg tok/s     : {f'{tps:.0f}':<41} ║
╚══════════════════════════════════════════════════════════╝
    """)


async def run(mode: str, duration: int, concurrency: int) -> None:
    stats["start_time"] = time.time()

    print(f"""
╔══════════════════════════════════════════════════════════╗
║         vLLM Grafana Spike Load Test                     ║
╠══════════════════════════════════════════════════════════╣
║  Endpoint   : {ENDPOINT:<43} ║
║  Model      : {MODEL:<43} ║
║  Mode       : {mode:<43} ║
║  Duration   : {str(duration) + 's':<43} ║
║  Concurrency: {str(concurrency):<43} ║
╠══════════════════════════════════════════════════════════╣
║  Open Grafana: https://grafana-llm.akamai-poc.online     ║
║  Set refresh : 5s auto-refresh on all panels             ║
╚══════════════════════════════════════════════════════════╝
    """)

    if mode == "kv":
        await run_kv_cache_mode(duration, concurrency)
    elif mode == "queue":
        await run_queue_depth_mode(duration, concurrency)
    elif mode == "combined":
        await run_combined_mode(duration, concurrency)

    elapsed = time.time() - stats["start_time"]
    print_summary(elapsed)


def main() -> None:
    parser = argparse.ArgumentParser(description="vLLM Grafana spike load test")
    parser.add_argument(
        "--mode",
        choices=["kv", "queue", "combined"],
        default="combined",
        help="kv=KV cache spike, queue=queue depth spike, combined=both (default)"
    )
    parser.add_argument("--duration", type=int, default=180,
                        help="Test duration in seconds (default: 180)")
    parser.add_argument("--concurrency", type=int, default=10,
                        help="Max concurrent requests (default: 10)")
    args = parser.parse_args()

    try:
        import aiohttp  # noqa
    except ImportError:
        print("Missing dependency. Run: pip install aiohttp")
        sys.exit(1)

    asyncio.run(run(args.mode, args.duration, args.concurrency))


if __name__ == "__main__":
    main()
