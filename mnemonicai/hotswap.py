"""Blue/green llama-server engine manager for zero-downtime adapter swaps.

Two localhost llama-server slots (ports 8402/8403). Exactly one is "active"
and receives all inference traffic from the hybrid backend. A swap boots the
standby slot with the new LoRA adapter GGUF, health-checks it, atomically
flips the state file, then retires the old engine after a grace period so
in-flight requests finish. Clients (OpenClaw etc.) only ever see MnemonicAi's
stable :8400 API — they never notice the swap.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.request

PORTS = (8402, 8403)
GRACE_SECONDS = 60


class EngineManager:
    def __init__(self, cfg) -> None:
        self.cfg = cfg
        self.exe = cfg.llama_server_exe
        self.state_path = os.path.join(cfg.data_dir, "engine_state.json")
        os.makedirs(cfg.data_dir, exist_ok=True)

    # ---- state ----
    def state(self) -> dict:
        try:
            with open(self.state_path, encoding="utf-8") as f:
                return json.load(f)
        except (FileNotFoundError, ValueError):
            return {"active_port": None, "pid": None,
                    "adapter_gguf": None, "adapter_version": 0}

    def _write_state(self, st: dict) -> None:
        tmp = self.state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(st, f, indent=2)
        os.replace(tmp, self.state_path)

    def active_url(self) -> str:
        st = self.state()
        return f"http://127.0.0.1:{st['active_port']}/v1" if st.get("active_port") else ""

    # ---- engine lifecycle ----
    def _spawn(self, port: int, adapter_gguf: str | None) -> subprocess.Popen:
        args = [self.exe, "-m", self.cfg.gguf_path,
                "--host", "127.0.0.1", "--port", str(port),
                "-ngl", "999", "-c", "65536", "--cache-reuse", "256",
                "--alias", self.cfg.model_name]
        if adapter_gguf:
            args += ["--lora", adapter_gguf]
        env = os.environ.copy()
        # CUDA build needs cudart/cublas; torch ships them
        try:
            import torch
            env["PATH"] = (os.path.join(os.path.dirname(torch.__file__), "lib")
                           + os.pathsep + env.get("PATH", ""))
        except ImportError:
            pass
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        log = open(os.path.join(self.cfg.data_dir, f"engine_{port}.log"), "ab")
        return subprocess.Popen(args, env=env, creationflags=flags,
                                stdout=log, stderr=log)

    def _healthy(self, port: int, timeout_s: float = 180.0) -> bool:
        deadline = time.time() + timeout_s
        url = f"http://127.0.0.1:{port}/health"
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(url, timeout=3) as r:
                    if json.loads(r.read()).get("status") == "ok":
                        return True
            except Exception:
                pass
            time.sleep(2)
        return False

    def _alive(self, pid) -> bool:
        if not pid:
            return False
        try:
            out = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
                capture_output=True, text=True, timeout=15).stdout
            return str(pid) in out
        except Exception:
            return False

    def _kill(self, pid) -> None:
        try:
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           capture_output=True, timeout=15)
        except Exception:
            pass

    # ---- public ops ----
    def ensure_running(self) -> str:
        """Make sure the active engine is alive; boot one if not."""
        st = self.state()
        if st.get("active_port") and self._alive(st.get("pid")):
            return self.active_url()
        port = st.get("active_port") or PORTS[0]
        proc = self._spawn(port, st.get("adapter_gguf"))
        if not self._healthy(port):
            raise RuntimeError(f"engine on :{port} failed health check "
                               f"(see engine_{port}.log)")
        st.update({"active_port": port, "pid": proc.pid})
        self._write_state(st)
        print(f"[hotswap] engine v{st.get('adapter_version', 0)} "
              f"serving on :{port} (pid {proc.pid})")
        return self.active_url()

    def swap_in(self, adapter_gguf: str, version: int) -> None:
        """Blue/green swap: boot standby with adapter, flip, retire old."""
        st = self.state()
        old_port, old_pid = st.get("active_port"), st.get("pid")
        new_port = PORTS[1] if old_port == PORTS[0] else PORTS[0]
        print(f"[hotswap] booting v{version} on :{new_port} "
              f"(adapter: {os.path.basename(adapter_gguf)})")
        proc = self._spawn(new_port, adapter_gguf)
        if not self._healthy(new_port):
            self._kill(proc.pid)
            raise RuntimeError(
                f"new engine v{version} failed health check on :{new_port}; "
                f"keeping v{st.get('adapter_version', 0)} live")
        self._write_state({"active_port": new_port, "pid": proc.pid,
                           "adapter_gguf": adapter_gguf,
                           "adapter_version": version})
        print(f"[hotswap] flipped to v{version} on :{new_port}; retiring "
              f":{old_port} in {GRACE_SECONDS}s")
        if old_pid:
            import threading
            threading.Timer(GRACE_SECONDS, self._kill, args=(old_pid,)).start()
