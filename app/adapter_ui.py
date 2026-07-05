#!/usr/bin/env bash
# adapter_ui.py — FastAPI web dashboard for adapter version management.
from contextlib import asynccontextmanager
from pathlib import Path
import json, os, time
from fastapi import FastAPI, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel

MN_REPO = os.environ.get("MN_REPO", str(Path(__file__).resolve().parent.parent))
ADAPTER_DIR = Path(MN_REPO) / "mnemonicai_data" / "adapter"
REGISTRY = ADAPTER_DIR / ".registry.json"

app = FastAPI(title="MnemonicAi Adapter Manager")

def load_registry():
    if REGISTRY.exists():
        return json.loads(REGISTRY.read_text())
    return {"versions": [], "active": None, "previous": None}

def save_registry(r):
    ADAPTER_DIR.mkdir(parents=True, exist_ok=True)
    REGISTRY.write_text(json.dumps(r, indent=2))

@app.get("/", response_class=HTMLResponse)
def index():
    r = load_registry()
    rows = ""
    for v in r.get("versions", []):
        active = "✅ ACTIVE" if v["name"] == r.get("active") else ""
        rows += f"""
        <tr>
          <td>{v['name']}</td>
          <td>{active}</td>
          <td>{v.get('train_loss','—')}</td>
          <td>{v.get('eval_loss','—')}</td>
          <td>{v.get('examples','—')}</td>
          <td>{v.get('timestamp','—')}</td>
          <td>
            <form method="post" action="/admin/adapters/activate" style="display:inline">
              <input type="hidden" name="version" value="{v['name']}">
              <button type="submit">Activate</button>
            </form>
          </td>
        </tr>
        """
    return f"""
    <!doctype html>
    <html>
    <head>
      <title>MnemonicAi Adapter Manager</title>
      <style>
        body {{ font-family: system-ui, sans-serif; max-width: 960px; margin: 2rem auto; }}
        table {{ width: 100%; border-collapse: collapse; margin-top: 1rem; }}
        th, td {{ border: 1px solid #ccc; padding: 0.5rem; text-align: left; }}
        th {{ background: #f0f0f0; }}
        button {{ cursor: pointer; }}
        .actions {{ margin-top: 1rem; }}
      </style>
    </head>
    <body>
      <h1>🧠 MnemonicAi Adapter Manager</h1>
      <p>Active: <strong>{r.get('active') or 'none'}</strong> |
         Previous: <strong>{r.get('previous') or 'none'}</strong></p>
      <div class="actions">
        <form method="post" action="/admin/adapters/rollback" style="display:inline">
          <button type="submit">↩ Rollback to Previous</button>
        </form>
        <form method="post" action="/admin/adapters/gc" style="display:inline">
          <button type="submit">🗑 Garbage Collect Old</button>
        </form>
      </div>
      <table>
        <tr><th>Version</th><th>Status</th><th>Train Loss</th><th>Eval Loss</th><th>Examples</th><th>Timestamp</th><th>Action</th></tr>
        {rows}
      </table>
    </body>
    </html>
    """

@app.post("/admin/adapters/activate")
def activate(version: str = Form(...)):
    r = load_registry()
    names = {v["name"] for v in r["versions"]}
    if version not in names:
        raise HTTPException(status_code=404, detail="version not found")
    if not (ADAPTER_DIR / version).is_dir():
        raise HTTPException(status_code=400, detail="adapter weights missing")
    r["previous"] = r.get("active")
    r["active"] = version
    save_registry(r)
    # If you integrate with the main app, trigger a hot-swap here.
    return RedirectResponse(url="/", status_code=303)

@app.post("/admin/adapters/rollback")
def rollback():
    r = load_registry()
    prev = r.get("previous")
    if not prev:
        raise HTTPException(status_code=400, detail="no previous version")
    r["active"], r["previous"] = prev, r.get("active")
    save_registry(r)
    return RedirectResponse(url="/", status_code=303)

@app.post("/admin/adapters/gc")
def gc(keep: int = Form(5)):
    r = load_registry()
    names = [v["name"] for v in r["versions"]]
    active = r.get("active")
    def sort_key(n):
        try: return int(n.replace("v", "").split(".")[0])
        except: return 0
    to_keep = set(sorted(names, key=sort_key)[-keep:])
    to_keep.add(active)
    for n in names:
        if n not in to_keep:
            p = ADAPTER_DIR / n
            if p.is_dir():
                import shutil
                shutil.rmtree(p)
    r["versions"] = [v for v in r["versions"] if v["name"] in to_keep]
    save_registry(r)
    return RedirectResponse(url="/", status_code=303)

@app.get("/admin/adapters/json")
def json_status():
    return load_registry()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8401)
