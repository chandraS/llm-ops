"""
loadtest-api — runs the vLLM spike load test as a background task and reports
status, so the console UI can start/stop/poll it instead of someone SSHing in
and running scripts/demo_load_test.py by hand.

Mirrors the three modes in scripts/demo_load_test.py (queue / kv / combined).
"""

import asyncio
import os
import time
from datetime import datetime, timezone
from typing import Optional

import aiohttp
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, EmailStr, Field

VLLM_URL = os.environ.get(
    "VLLM_URL", "http://qwen25-7b.llm-serving.svc.cluster.local:8000/v1/chat/completions"
)
MODEL_NAME = os.environ.get("MODEL_NAME", "qwen25-7b")
LOADTEST_TOKEN = os.environ.get("LOADTEST_TOKEN", "")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
GITHUB_REPO = os.environ.get("GITHUB_REPO", "chandraS/llm-ops")

MODE_INTERVAL = {"queue": 0.05, "kv": 0.3, "combined": 0.2}

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

COMBINED_PROMPTS = LONG_PROMPTS * 7 + SHORT_PROMPTS * 3

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://chat.akamai-poc.online"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

# In-memory log of access requests (GitHub Issues are the persistent record)
access_requests: list[dict] = []

state = {
    "status": "idle",  # idle | running
    "mode": None,
    "concurrency": None,
    "duration": None,
    "started_at": None,
    "sent": 0,
    "completed": 0,
    "failed": 0,
    "total_tokens": 0,
}

_stop_event = None  # type: Optional["asyncio.Event"]


class StartRequest(BaseModel):
    mode: str = Field(pattern="^(queue|kv|combined)$")
    concurrency: int = Field(ge=1, le=180)
    duration: int = Field(ge=30, le=600)


class AccessRequest(BaseModel):
    email: EmailStr
    description: str = Field(min_length=10, max_length=1000)


def _require_token(token: Optional[str]) -> None:
    if not LOADTEST_TOKEN:
        raise HTTPException(500, "Server misconfigured: LOADTEST_TOKEN not set")
    if token != LOADTEST_TOKEN:
        raise HTTPException(401, "Invalid or missing load test token")


def _pick_request(mode: str, rid: int):
    if mode == "queue":
        prompt = SHORT_PROMPTS[rid % len(SHORT_PROMPTS)]
        return prompt, 150, False
    if mode == "kv":
        prompt = LONG_PROMPTS[rid % len(LONG_PROMPTS)]
        return prompt, 800, True
    prompt = COMBINED_PROMPTS[rid % len(COMBINED_PROMPTS)]
    use_system = prompt in LONG_PROMPTS
    return prompt, (600 if use_system else 150), use_system


async def _send_one(session, sem, prompt, max_tokens, use_system, stop_event) -> None:
    async with sem:
        if stop_event.is_set():
            return
        messages = []
        if use_system:
            messages.append({"role": "system", "content": SYSTEM_PROMPT})
        messages.append({"role": "user", "content": prompt})
        payload = {
            "model": MODEL_NAME,
            "messages": messages,
            "max_tokens": max_tokens,
            "stream": False,
        }
        try:
            async with session.post(
                VLLM_URL, json=payload, timeout=aiohttp.ClientTimeout(total=180)
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    state["completed"] += 1
                    state["total_tokens"] += data.get("usage", {}).get("total_tokens", 0)
                else:
                    state["failed"] += 1
        except (asyncio.TimeoutError, aiohttp.ClientError):
            state["failed"] += 1


async def _run_load_test(mode: str, concurrency: int, duration: int, stop_event) -> None:
    sem = asyncio.Semaphore(concurrency)
    connector = aiohttp.TCPConnector(limit=concurrency + 5)
    interval = MODE_INTERVAL[mode]

    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = set()
        end_time = time.time() + duration
        rid = 0

        while time.time() < end_time and not stop_event.is_set():
            prompt, max_tokens, use_system = _pick_request(mode, rid)
            t = asyncio.create_task(
                _send_one(session, sem, prompt, max_tokens, use_system, stop_event)
            )
            tasks.add(t)
            t.add_done_callback(tasks.discard)
            state["sent"] += 1
            rid += 1
            await asyncio.sleep(interval)

        if tasks:
            if stop_event.is_set():
                for t in tasks:
                    t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    state["status"] = "idle"


@app.post("/api/access-request")
async def request_access(req: AccessRequest):
    if not GITHUB_TOKEN:
        raise HTTPException(500, "Server misconfigured: GITHUB_TOKEN not set")

    submitted_at = datetime.now(timezone.utc).isoformat()
    issue_body = (
        f"**Email:** {req.email}\n\n"
        f"**How they found the repo:**\n{req.description}\n\n"
        f"---\n_Submitted at {submitted_at}_"
    )

    async with aiohttp.ClientSession() as session:
        resp = await session.post(
            f"https://api.github.com/repos/{GITHUB_REPO}/issues",
            json={"title": f"Access request: {req.email}", "body": issue_body},
            headers={
                "Authorization": f"Bearer {GITHUB_TOKEN}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            timeout=aiohttp.ClientTimeout(total=10),
        )
        if resp.status not in (200, 201):
            raise HTTPException(502, "Failed to create GitHub issue")
        issue = await resp.json()

    access_requests.append({
        "email": req.email,
        "submitted_at": submitted_at,
        "issue_url": issue.get("html_url"),
    })

    return {"ok": True, "message": f"Request submitted. We'll reach out to {req.email}."}


@app.get("/api/access-requests")
async def list_access_requests(x_load_test_token: Optional[str] = Header(None)):
    _require_token(x_load_test_token)
    return {"requests": access_requests}


@app.get("/api/loadtest/health")
async def health():
    return {"ok": True}


@app.get("/api/loadtest/status")
async def status():
    resp = dict(state)
    if state["started_at"]:
        resp["elapsed"] = round(time.time() - state["started_at"], 1)
    return resp


@app.post("/api/loadtest/start")
async def start(req: StartRequest, x_load_test_token: Optional[str] = Header(None)):
    _require_token(x_load_test_token)

    if state["status"] == "running":
        raise HTTPException(409, "A load test is already running")

    state.update(
        {
            "status": "running",
            "mode": req.mode,
            "concurrency": req.concurrency,
            "duration": req.duration,
            "started_at": time.time(),
            "sent": 0,
            "completed": 0,
            "failed": 0,
            "total_tokens": 0,
        }
    )

    global _stop_event
    _stop_event = asyncio.Event()
    asyncio.create_task(_run_load_test(req.mode, req.concurrency, req.duration, _stop_event))

    return {"ok": True, "status": state}


@app.post("/api/loadtest/stop")
async def stop(x_load_test_token: Optional[str] = Header(None)):
    _require_token(x_load_test_token)

    if state["status"] != "running" or _stop_event is None:
        raise HTTPException(409, "No load test is running")

    _stop_event.set()
    return {"ok": True}
