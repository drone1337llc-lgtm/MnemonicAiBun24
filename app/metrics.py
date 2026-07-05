"""
app/metrics.py — Prometheus instrumentation for MnemonicAi.
Import this module from start.py and call setup_metrics(app) to expose /metrics
on port 8402 (separate from the main API on 8400).
"""
import os
import json
from pathlib import Path
from prometheus_client import (
    Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST, REGISTRY
)
from prometheus_fastapi_instrumentator import Instrumentator
from fastapi import FastAPI, Response

# ---------- custom MnemonicAi metrics ----------
INFERENCE_REQUESTS = Counter(
    "mnemonicai_inference_requests_total",
    "Total inference requests",
    ["endpoint", "status"]
)

INFERENCE_LATENCY = Histogram(
    "mnemonicai_inference_latency_seconds",
    "Inference latency in seconds",
    ["endpoint"],
    buckets=(0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0)
)

TRAINING_EVENTS = Counter(
    "mnemonicai_training_events_total",
    "Total training (QLoRA bake) events",
    ["result"]  # success | failure | rollback
)

TRAINING_LOSS = Gauge(
    "mnemonicai_training_loss",
    "Last training loss reported"
)

EVAL_LOSS = Gauge(
    "mnemonicai_eval_loss",
    "Last evaluation loss reported"
)

ACTIVE_ADAPTER = Gauge(
    "mnemonicai_active_adapter_version",
    "Active adapter version number"
)

ADAPTER_COUNT = Gauge(
    "mnemonicai_adapter_count",
    "Total number of registered adapter versions"
)

GPU_MEMORY_USED = Gauge(
    "mnemonicai_gpu_memory_used_bytes",
    "GPU memory used in bytes",
    ["gpu_index"]
)

GPU_MEMORY_TOTAL = Gauge(
    "mnemonicai_gpu_memory_total_bytes",
    "GPU total memory in bytes",
    ["gpu_index"]
)

GPU_UTILIZATION = Gauge(
    "mnemonicai_gpu_utilization_percent",
    "GPU utilization percentage",
    ["gpu_index"]
)

HEALTH_STATUS = Gauge(
    "mnemonicai_health_status",
    "Overall health (1=healthy, 0=unhealthy)"
)


def update_adapter_metrics(adapter_dir: str):
    """Call this after training or adapter activation to update gauges."""
    registry_path = Path(adapter_dir) / ".registry.json"
    if not registry_path.exists():
        ADAPTER_COUNT.set(0)
        return
    try:
        data = json.loads(registry_path.read_text())
        versions = data.get("versions", [])
        ADAPTER_COUNT.set(len(versions))
        active = data.get("active")
        if active and active.startswith("v"):
            try:
                ACTIVE_ADAPTER.set(int(active[1:].split(".")[0]))
            except (ValueError, IndexError):
                pass
    except Exception:
        pass


def setup_metrics(app: FastAPI):
    """
    Instrument the FastAPI app with Prometheus metrics.
    Exposes /metrics on the same app (port 8402 if you run a separate server,
    or on the main app if you prefer a single port).
    """
    # Auto-instrument HTTP metrics
    Instrumentator(
        should_group_status_codes=True,
        should_ignore_untemplated=True,
        should_instrument_requests_inprogress=True,
        excluded_handlers=["/metrics", "/admin/adapters"],
        inprogress_name="mnemonicai_inprogress",
        inprogress_labels=True,
    ).instrument(app).expose(
        app,
        endpoint="/metrics",
        include_in_schema=False,
        should_gzip=True,
    )

    @app.get("/health", include_in_schema=False)
    async def health():
        """Health endpoint also updates the health gauge."""
        HEALTH_STATUS.set(1)
        # Try to update GPU metrics on health check
        try:
            import torch
            if torch.cuda.is_available():
                for i in range(torch.cuda.device_count()):
                    used, total = torch.cuda.mem_get_info(i)
                    GPU_MEMORY_USED.labels(gpu_index=str(i)).set(used)
                    GPU_MEMORY_TOTAL.labels(gpu_index=str(i)).set(total)
        except Exception:
            pass
        return {"status": "healthy"}
