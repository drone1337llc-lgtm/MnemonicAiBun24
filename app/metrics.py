"""
app/metrics.py — Prometheus instrumentation for MnemonicAi.
Import from start.py:  from app.metrics import setup_metrics, update_adapter_metrics
"""
import os
import json
from pathlib import Path
from prometheus_client import (
    Counter, Histogram, Gauge, CONTENT_TYPE_LATEST
)
from prometheus_fastapi_instrumentator import Instrumentator
from fastapi import FastAPI

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
    ["result"]
)

TRAINING_LOSS = Gauge("mnemonicai_training_loss", "Last training loss")
EVAL_LOSS = Gauge("mnemonicai_eval_loss", "Last evaluation loss")
ACTIVE_ADAPTER = Gauge("mnemonicai_active_adapter_version", "Active adapter version number")
ADAPTER_COUNT = Gauge("mnemonicai_adapter_count", "Total registered adapter versions")
GPU_MEMORY_USED = Gauge("mnemonicai_gpu_memory_used_bytes", "GPU memory used", ["gpu_index"])
GPU_MEMORY_TOTAL = Gauge("mnemonicai_gpu_memory_total_bytes", "GPU total memory", ["gpu_index"])
GPU_UTILIZATION = Gauge("mnemonicai_gpu_utilization_percent", "GPU utilization %", ["gpu_index"])
HEALTH_STATUS = Gauge("mnemonicai_health_status", "1=healthy, 0=unhealthy")


def update_adapter_metrics(adapter_dir: str):
    registry_path = Path(adapter_dir) / ".registry.json"
    if not registry_path.exists():
        ADAPTER_COUNT.set(0)
        return
    try:
        data = json.loads(registry_path.read_text())
        ADAPTER_COUNT.set(len(data.get("versions", [])))
        active = data.get("active")
        if active and active.startswith("v"):
            ACTIVE_ADAPTER.set(int(active[1:].split(".")[0]))
    except Exception:
        pass


def setup_metrics(app: FastAPI):
    Instrumentator(
        should_group_status_codes=True,
        should_ignore_untemplated=True,
        should_instrument_requests_inprogress=True,
        excluded_handlers=["/metrics", "/admin/adapters"],
        inprogress_name="mnemonicai_inprogress",
        inprogress_labels=True,
    ).instrument(app).expose(
        app, endpoint="/metrics", include_in_schema=False, should_gzip=True
    )

    @app.get("/health", include_in_schema=False)
    async def health():
        HEALTH_STATUS.set(1)
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
