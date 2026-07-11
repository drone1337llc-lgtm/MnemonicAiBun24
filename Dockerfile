# Dockerfile — MnemonicAi inference + training image
# Target: CUDA 12.6 + Python 3.12
#
# Matches the live hybrid-backend architecture: inference runs through a
# compiled llama-server BINARY (blue/green pair, managed by hotswap.py via
# subprocess), not the llama-cpp-python bindings. An earlier version of this
# file installed llama-cpp-python[cuda] via pip+cmake, which (a) targeted an
# architecture nothing in this codebase actually uses anymore, and (b) failed
# outright on the old `-runtime-` base image, which has no nvcc/CUDA headers
# to compile against in the first place.
FROM nvidia/cuda:12.6.0-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV HF_HOME=/app/.cache/huggingface
ENV TRANSFORMERS_OFFLINE=0

# ---------- system deps ----------
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev python3-pip \
    git curl wget rsync build-essential cmake pkg-config ninja-build \
    libssl-dev libffi-dev libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# ---------- llama.cpp (llama-server binary + GGUF conversion scripts) ----------
# Same build production uses locally: CUDA-enabled llama-server for the
# blue/green inference pair, plus convert_hf_to_gguf.py / convert_lora_to_gguf.py
# for base-model and adapter conversion. Architectures: 86=Ampere (3090/A40),
# 89=Ada (4080/L40) — covers the local box and common cloud rental GPUs.
#
# `docker build` has no GPU access (that's only injected at `docker run
# --gpus all`), so the real driver library (libcuda.so.1, the CUDA DRIVER
# API — cuMemMap/cuMemCreate/etc, distinct from the CUDA RUNTIME API) isn't
# present. libggml-cuda.so itself links fine regardless (shared libraries
# tolerate undefined symbols, resolved lazily at load time), but linking the
# final llama-server EXECUTABLE against it triggers ld's stricter transitive
# check, which fails outright since libcuda.so.1 can't be found or even
# stubbed convincingly enough for that check (verified empirically — neither
# LIBRARY_PATH nor a same-named symlink to NVIDIA's stub satisfied it).
# --allow-shlib-undefined skips that check; the real driver, injected at a
# standard path by nvidia-container-toolkit, satisfies these symbols at
# actual container runtime.
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp /opt/llama.cpp \
    && cmake -B /opt/llama.cpp/build -S /opt/llama.cpp \
        -DGGML_CUDA=on -DCMAKE_CUDA_ARCHITECTURES="86;89" \
        -DLLAMA_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined" \
    && cmake --build /opt/llama.cpp/build --target llama-server llama-quantize \
        -j"$(nproc)"

# ---------- venv ----------
RUN python3.12 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --upgrade pip wheel setuptools "setuptools<70"

# ---------- PyTorch (CUDA 12.6) ----------
RUN pip install --no-cache-dir \
    --index-url https://download.pytorch.org/whl/cu126 \
    "torch==2.6.0" "torchvision==0.21.0" "torchaudio==2.6.0"

# ---------- GPU training stack ----------
RUN pip install --no-cache-dir \
    "bitsandbytes>=0.45" \
    "accelerate>=1.0" \
    "peft>=0.14" \
    "transformers>=4.45" \
    "safetensors>=0.5" \
    "sentencepiece>=0.2" \
    "datasets>=2.20"

# ---------- app deps ----------
RUN pip install --no-cache-dir \
    "fastapi>=0.115" \
    "uvicorn[standard]>=0.32" \
    "pydantic>=2.10" \
    "httpx>=0.28" \
    "sse-starlette>=2.1" \
    "python-multipart>=0.0.18" \
    "prometheus-fastapi-instrumentator>=7.0" \
    "prometheus-client>=0.21"

# ---------- app copy ----------
WORKDIR /app
COPY . /app

# ---------- editable install ----------
RUN pip install -e /app 2>/dev/null || true

# ---------- entrypoint ----------
RUN chmod +x /app/mn_*.sh 2>/dev/null || true

EXPOSE 8400 8401

HEALTHCHECK --interval=30s --timeout=15s --start-period=90s --retries=3 \
    CMD curl -fsS http://localhost:8400/health | grep -qv '"backend": *"mock"' || exit 1

CMD ["python", "start.py", "--host", "0.0.0.0", "--port", "8400", "--data-dir", "mnemonicai_data"]
