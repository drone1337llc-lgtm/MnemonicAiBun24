# Dockerfile — MnemonicAi inference container
# Build:  docker build -t mnemonicai:latest .
# Run:    docker run --gpus all -p 8400:8400 -v $(pwd)/mnemonicai_data:/app/mnemonicai_data mnemonicai:latest
#
# Requires NVIDIA Container Toolkit on the host for --gpus.
FROM nvidia/cuda:12.6.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Install system dependencies + Python 3.12
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev python3-pip \
    git curl ca-certificates \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.12 /usr/bin/python

WORKDIR /app

# Install Python dependencies first (cache-friendly layer)
COPY requirements.txt requirements-gpu.txt ./
RUN python -m pip install --upgrade pip setuptools wheel "setuptools<70" \
    && python -m pip install -r requirements.txt \
    && python -m pip install -r requirements-gpu.txt \
    && CMAKE_ARGS="-DGGML_CUDA=on" python -m pip install --no-cache-dir \
       --force-reinstall "llama-cpp-python[cuda]"

# Copy app code
COPY . .

# Make scripts executable
RUN chmod +x mn_*.sh app/adapter_ui.py

# Health check
HEALTHCHECK --interval=30s --timeout=15s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost:8400/health || exit 1

# Run the inference server
EXPOSE 8400 8401
CMD ["./mn_run.sh", "background"]
