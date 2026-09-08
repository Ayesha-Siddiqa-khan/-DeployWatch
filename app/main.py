import time
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from kubernetes import client, config

k8s_client: Optional[client.CoreV1Api] = None
k8s_apps: Optional[client.AppsV1Api] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global k8s_client, k8s_apps
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()
    k8s_client = client.CoreV1Api()
    k8s_apps = client.AppsV1Api()
    yield


app = FastAPI(title="DeployWatch", lifespan=lifespan)


def ns() -> str:
    return os.getenv("WATCH_NAMESPACE", "deploywatch")


def fmt_age(ts: Optional[datetime]) -> str:
    if not ts:
        return "unknown"
    now = datetime.now(timezone.utc)
    delta = now - (ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc))
    secs = int(delta.total_seconds())
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


@app.get("/", response_class=HTMLResponse)
async def dashboard():
    return DASHBOARD_HTML


@app.get("/api/overview")
async def overview():
    namespace = ns()
    pods = k8s_client.list_namespaced_pod(namespace)
    svcs = k8s_client.list_namespaced_service(namespace)
    deps = k8s_apps.list_namespaced_deployment(namespace)
    events = k8s_client.list_namespaced_event(namespace, limit=20)

    pod_list = []
    for p in pods.items:
        cs = p.status.container_statuses or [None]
        restarts = sum(c.restart_count for c in cs if c)
        ready = all(
            c.ready for c in (p.status.container_statuses or []) if c
        )
        pod_list.append({
            "name": p.metadata.name,
            "status": p.status.phase,
            "ready": ready,
            "restarts": restarts,
            "node": p.spec.node_name or "pending",
            "ip": p.status.pod_ip or "-",
            "age": fmt_age(p.metadata.creation_timestamp),
            "image": (
                p.spec.containers[0].image
                if p.spec.containers
                else "-"
            ),
        })

    svc_list = []
    for s in svcs.items:
        ports = ", ".join(
            f"{sp.port}->{sp.node_port or sp.target_port}"
            for sp in (s.spec.ports or [])
        )
        ep = "-"
        if s.status.load_balancer and s.status.load_balancer.ingress:
            ep = s.status.load_balancer.ingress[0].hostname or "-"
        svc_list.append({
            "name": s.metadata.name,
            "type": s.spec.type,
            "cluster_ip": s.spec.cluster_ip,
            "external_ip": ep,
            "ports": ports,
            "age": fmt_age(s.metadata.creation_timestamp),
        })

    dep_list = []
    for d in deps.items:
        spec = d.spec or {}
        status = d.status or {}
        desired = spec.replicas or 0
        ready = status.ready_replicas or 0
        updated = status.updated_replicas or 0
        available = status.available_replicas or 0
        dep_list.append({
            "name": d.metadata.name,
            "desired": desired,
            "ready": ready,
            "updated": updated,
            "available": available,
            "strategy": spec.strategy.type if spec.strategy else "-",
            "age": fmt_age(d.metadata.creation_timestamp),
            "image": (
                spec.template.spec.containers[0].image
                if spec.template and spec.template.spec.containers
                else "-"
            ),
        })

    event_list = []
    for e in events.items:
        event_list.append({
            "type": e.type,
            "reason": e.reason,
            "message": e.message[:120],
            "age": fmt_age(e.event_time or e.metadata.creation_timestamp),
            "count": e.count or 1,
        })

    return {
        "namespace": namespace,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "total_pods": len(pod_list),
            "running_pods": sum(
                1 for p in pod_list if p["status"] == "Running"
            ),
            "failed_pods": sum(
                1 for p in pod_list if p["status"] in ("Failed", "Error")
            ),
            "total_services": len(svc_list),
            "total_deployments": len(dep_list),
        },
        "pods": pod_list,
        "services": svc_list,
        "deployments": dep_list,
        "events": event_list,
    }


@app.get("/api/pods/{pod_name}/logs")
async def pod_logs(pod_name: str):
    namespace = ns()
    try:
        logs = k8s_client.read_namespaced_pod_log(
            pod_name, namespace, tail_lines=100
        )
        return {"pod": pod_name, "logs": logs}
    except Exception as e:
        return {"pod": pod_name, "logs": f"Error: {e}"}


@app.get("/api/pods/{pod_name}/describe")
async def pod_describe(pod_name: str):
    namespace = ns()
    try:
        pod = k8s_client.read_namespaced_pod(pod_name, namespace)
        return {
            "name": pod.metadata.name,
            "namespace": namespace,
            "status": pod.status.phase,
            "node": pod.spec.node_name,
            "ip": pod.status.pod_ip,
            "restarts": sum(
                c.restart_count
                for c in (pod.status.container_statuses or [])
                if c
            ),
            "containers": [
                {
                    "name": c.name,
                    "image": c.image,
                    "ready": c.ready,
                    "restarts": c.restart_count,
                }
                for c in (pod.spec.containers or [])
            ],
            "conditions": [
                {
                    "type": c.type,
                    "status": c.status,
                    "reason": c.reason or "-",
                }
                for c in (pod.status.conditions or [])
            ],
        }
    except Exception as e:
        return {"error": str(e)}


DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DeployWatch</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
*{margin:0;padding:0;box-sizing:border-box}

:root{
  --void:#0a0c10;
  --panel:#12151c;
  --raised:#1a1e28;
  --edge:#252a38;
  --edge-focus:#3d4560;
  --ink:#c8cde0;
  --ink-muted:#6b7394;
  --ink-ghost:#3d4260;
  --led-green:#00e68a;
  --led-red:#ff3d5a;
  --led-amber:#ffaa2c;
  --led-blue:#4d8dff;
  --led-teal:#2dd4bf;
  --font-sans:'Inter',-apple-system,system-ui,sans-serif;
  --font-mono:'JetBrains Mono','SF Mono','Fira Code',monospace;
}

html{font-size:14px}
body{font-family:var(--font-sans);background:var(--void);color:var(--ink);min-height:100vh;-webkit-font-smoothing:antialiased}

/* ── grid lines (decorative, behind content) ── */
body::before{content:'';position:fixed;inset:0;background:
  repeating-linear-gradient(90deg,var(--edge) 0 1px,transparent 1px 120px),
  repeating-linear-gradient(0deg,var(--edge) 0 1px,transparent 1px 120px);
  opacity:.15;pointer-events:none;z-index:0}

/* ── topbar ── */
.topbar{
  position:sticky;top:0;z-index:100;
  background:var(--panel);border-bottom:1px solid var(--edge);
  padding:0 24px;height:48px;
  display:flex;align-items:center;justify-content:space-between;
  font-size:12px;
}
.topbar-left{display:flex;align-items:center;gap:12px}
.logo{font-family:var(--font-mono);font-weight:700;font-size:14px;letter-spacing:-.02em;color:var(--ink)}
.logo .watch{color:var(--led-teal)}
.topbar-right{display:flex;align-items:center;gap:20px;color:var(--ink-muted);font-family:var(--font-mono);font-size:11px}
.live-dot{width:6px;height:6px;border-radius:50%;background:var(--led-green);display:inline-block;box-shadow:0 0 6px var(--led-green)}
.topbar-right .ns{color:var(--ink-ghost)}

/* ── layout ── */
.main{position:relative;z-index:1;max-width:1440px;margin:0 auto;padding:20px 24px 40px}

/* ── stat readouts ── */
.readouts{
  display:grid;grid-template-columns:repeat(5,1fr);gap:1px;
  background:var(--edge);border:1px solid var(--edge);margin-bottom:20px;
}
.readout{background:var(--panel);padding:16px 20px;display:flex;flex-direction:column;gap:4px}
.readout-label{font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.08em;color:var(--ink-ghost)}
.readout-value{font-family:var(--font-mono);font-size:28px;font-weight:700;line-height:1;letter-spacing:-.03em}
.readout-value.green{color:var(--led-green)}
.readout-value.red{color:var(--led-red)}
.readout-value.blue{color:var(--led-blue)}
.readout-value.teal{color:var(--led-teal)}
.readout-value.amber{color:var(--led-amber)}
.readout-sub{font-family:var(--font-mono);font-size:10px;color:var(--ink-ghost);margin-top:2px}

/* ── sections ── */
.section{margin-bottom:20px}
.section-title{
  font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;
  color:var(--ink-ghost);margin-bottom:8px;
  display:flex;align-items:center;gap:8px;
}
.section-title::after{content:'';flex:1;height:1px;background:var(--edge)}
.section-title .count{
  font-family:var(--font-mono);font-weight:700;font-size:12px;
  color:var(--ink-muted);background:var(--raised);padding:1px 6px;border-radius:3px;
}

/* ── tables ── */
.table-wrap{border:1px solid var(--edge);background:var(--panel);overflow-x:auto}
table{width:100%;border-collapse:collapse;table-layout:fixed}
thead{position:sticky;top:0;z-index:2}
th{
  text-align:left;padding:8px 12px;font-size:10px;font-weight:600;
  text-transform:uppercase;letter-spacing:.06em;color:var(--ink-ghost);
  background:var(--panel);border-bottom:1px solid var(--edge);
  white-space:nowrap;
}
th.num,td.num{text-align:right}
td{
  padding:7px 12px;font-size:12px;border-bottom:1px solid rgba(37,42,56,.5);
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
  transition:background .15s;
}
tr:hover td{background:var(--raised)}
tr.row-ok td{border-left:2px solid var(--led-green)}
tr.row-warn td{border-left:2px solid var(--led-amber)}
tr.row-err td{border-left:2px solid var(--led-red)}
.mono{font-family:var(--font-mono);font-size:11px;color:var(--ink-muted)}
.name{font-family:var(--font-mono);font-weight:600;font-size:12px;color:var(--ink);max-width:280px;overflow:hidden;text-overflow:ellipsis}
.image{font-family:var(--font-mono);font-size:11px;color:var(--ink-ghost);max-width:260px;overflow:hidden;text-overflow:ellipsis}

/* ── status chips ── */
.chip{
  display:inline-flex;align-items:center;gap:5px;
  padding:2px 8px;border-radius:3px;font-size:10px;font-weight:600;
  font-family:var(--font-mono);text-transform:uppercase;letter-spacing:.04em;
}
.chip::before{content:'';width:5px;height:5px;border-radius:50%;background:currentColor;flex-shrink:0}
.chip.running{color:var(--led-green);background:rgba(0,230,138,.08)}
.chip.pending{color:var(--led-amber);background:rgba(255,170,44,.08)}
.chip.failed,.chip.error{color:var(--led-red);background:rgba(255,61,90,.08)}
.chip.succeeded{color:var(--led-blue);background:rgba(77,141,255,.08)}
.chip.ok{color:var(--led-green);background:rgba(0,230,138,.08)}
.chip.no{color:var(--led-red);background:rgba(255,61,90,.08)}

/* ── events ── */
.events-wrap{border:1px solid var(--edge);background:var(--panel);max-height:360px;overflow-y:auto}
.ev{
  display:grid;grid-template-columns:60px 100px 1fr 40px;gap:8px;
  padding:6px 12px;border-bottom:1px solid rgba(37,42,56,.4);
  font-size:11px;align-items:baseline;
}
.ev:last-child{border-bottom:none}
.ev:hover{background:var(--raised)}
.ev-type{font-family:var(--font-mono);font-weight:700;font-size:10px}
.ev-type.Warning{color:var(--led-amber)}
.ev-type.Normal{color:var(--led-green)}
.ev-type.Error{color:var(--led-red)}
.ev-reason{font-family:var(--font-mono);font-weight:600;color:var(--led-teal);font-size:10px}
.ev-msg{color:var(--ink-muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ev-age{font-family:var(--font-mono);color:var(--ink-ghost);text-align:right}

/* ── logs modal ── */
.modal-overlay{
  display:none;position:fixed;inset:0;background:rgba(10,12,16,.85);
  z-index:200;align-items:center;justify-content:center;
  backdrop-filter:blur(4px);
}
.modal-overlay.open{display:flex}
.modal{
  background:var(--panel);border:1px solid var(--edge);width:920px;max-height:80vh;
  display:flex;flex-direction:column;
}
.modal-head{
  padding:12px 16px;border-bottom:1px solid var(--edge);
  display:flex;justify-content:space-between;align-items:center;
}
.modal-head h3{font-family:var(--font-mono);font-size:13px;font-weight:600}
.modal-close{
  background:none;border:1px solid var(--edge);color:var(--ink-muted);
  cursor:pointer;font-size:16px;padding:2px 8px;line-height:1;
  transition:color .15s,border-color .15s;
}
.modal-close:hover{color:var(--ink);border-color:var(--ink-muted)}
.modal pre{
  padding:16px;overflow:auto;flex:1;font-size:12px;line-height:1.7;
  color:var(--ink-muted);font-family:var(--font-mono);
  white-space:pre-wrap;word-break:break-all;
}

/* ── empty states ── */
.empty{
  padding:32px;text-align:center;color:var(--ink-ghost);
  font-family:var(--font-mono);font-size:12px;
}
.empty::before{content:'--';display:block;font-size:20px;margin-bottom:8px;color:var(--edge-focus)}

/* ── focus states ── */
:focus-visible{outline:1px solid var(--led-blue);outline-offset:2px}

/* ── transitions ── */
@keyframes row-enter{from{opacity:0;transform:translateY(-4px)}to{opacity:1;transform:translateY(0)}}
tr.new-row td{animation:row-enter .2s ease-out}

/* ── responsive ── */
@media(max-width:1000px){
  .readouts{grid-template-columns:repeat(3,1fr)}
  .ev{grid-template-columns:50px 80px 1fr 36px}
}
@media(max-width:600px){
  .readouts{grid-template-columns:repeat(2,1fr)}
  .topbar-right{display:none}
  .main{padding:12px}
}
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-left">
    <div class="logo">deploy<span class="watch">watch</span></div>
  </div>
  <div class="topbar-right">
    <span class="ns" id="ns">--</span>
    <span><span class="live-dot"></span> LIVE</span>
    <span id="last-update">--:--:--</span>
  </div>
</div>

<div class="main">
  <!-- readouts -->
  <div class="readouts">
    <div class="readout"><span class="readout-label">Running</span><span class="readout-value green" id="s-running">0</span></div>
    <div class="readout"><span class="readout-label">Failed</span><span class="readout-value red" id="s-failed">0</span></div>
    <div class="readout"><span class="readout-label">Total Pods</span><span class="readout-value blue" id="s-total">0</span></div>
    <div class="readout"><span class="readout-label">Deployments</span><span class="readout-value teal" id="s-deps">0</span></div>
    <div class="readout"><span class="readout-label">Services</span><span class="readout-value" id="s-svcs" style="color:var(--ink-muted)">0</span></div>
  </div>

  <!-- pods -->
  <div class="section">
    <div class="section-title">Pods <span class="count" id="pod-count">0</span></div>
    <div class="table-wrap"><table>
      <thead><tr>
        <th style="width:28%">Name</th>
        <th style="width:9%">Status</th>
        <th style="width:7%">Ready</th>
        <th class="num" style="width:8%">Restarts</th>
        <th style="width:14%">Node</th>
        <th style="width:12%">IP</th>
        <th style="width:16%">Image</th>
        <th style="width:6%">Age</th>
      </tr></thead>
      <tbody id="pods-body"></tbody>
    </table></div>
  </div>

  <!-- deployments -->
  <div class="section">
    <div class="section-title">Deployments <span class="count" id="dep-count">0</span></div>
    <div class="table-wrap"><table>
      <thead><tr>
        <th style="width:22%">Name</th>
        <th style="width:10%">Ready</th>
        <th class="num" style="width:8%">Desired</th>
        <th class="num" style="width:8%">Updated</th>
        <th class="num" style="width:9%">Available</th>
        <th style="width:10%">Strategy</th>
        <th style="width:20%">Image</th>
        <th style="width:7%">Age</th>
      </tr></thead>
      <tbody id="deps-body"></tbody>
    </table></div>
  </div>

  <!-- services -->
  <div class="section">
    <div class="section-title">Services <span class="count" id="svc-count">0</span></div>
    <div class="table-wrap"><table>
      <thead><tr>
        <th style="width:20%">Name</th>
        <th style="width:12%">Type</th>
        <th style="width:15%">Cluster IP</th>
        <th style="width:25%">External IP</th>
        <th style="width:16%">Ports</th>
        <th style="width:7%">Age</th>
      </tr></thead>
      <tbody id="svcs-body"></tbody>
    </table></div>
  </div>

  <!-- events -->
  <div class="section">
    <div class="section-title">Events <span class="count" id="evt-count">0</span></div>
    <div class="events-wrap" id="events-body"></div>
  </div>
</div>

<!-- logs modal -->
<div class="modal-overlay" id="logs-modal">
  <div class="modal">
    <div class="modal-head">
      <h3 id="logs-title">pod logs</h3>
      <button class="modal-close" onclick="closeLogs()" aria-label="Close">&times;</button>
    </div>
    <pre id="logs-content">loading...</pre>
  </div>
</div>

<script>
const P={
  el(id){return document.getElementById(id)},
  esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML},
  statusClass(s){return s==='Running'?'running':s==='Pending'?'pending':s==='Failed'||s==='Error'?'failed':s==='Succeeded'?'succeeded':'pending'},
  rowClass(p){
    if(p.status==='Failed'||p.status==='Error')return 'row-err';
    if(p.status==='Pending'||p.restarts>0)return 'row-warn';
    return 'row-ok';
  },
  depRowClass(d){return d.ready===d.desired?'row-ok':d.ready>0?'row-warn':'row-err'},
};

async function fetchOverview(){
  try{
    const r=await fetch('/api/overview');
    if(!r.ok)return;
    const d=await r.json();
    const now=new Date();
    P.el('ns').textContent=d.namespace;
    P.el('last-update').textContent=now.toLocaleTimeString('en-GB');
    P.el('s-running').textContent=d.summary.running_pods;
    P.el('s-failed').textContent=d.summary.failed_pods;
    P.el('s-total').textContent=d.summary.total_pods;
    P.el('s-deps').textContent=d.summary.total_deployments;
    P.el('s-svcs').textContent=d.summary.total_services;

    // pods
    let ph='';P.el('pod-count').textContent=d.pods.length;
    d.pods.forEach(p=>{
      ph+=`<tr class="${P.rowClass(p)}">
        <td class="name">${P.esc(p.name)}</td>
        <td><span class="chip ${P.statusClass(p.status)}">${p.status}</span></td>
        <td><span class="chip ${p.ready?'ok':'no'}">${p.ready?'yes':'no'}</span></td>
        <td class="num mono">${p.restarts}</td>
        <td class="mono">${P.esc(p.node)}</td>
        <td class="mono">${P.esc(p.ip)}</td>
        <td class="image" title="${P.esc(p.image)}">${P.esc(p.image)}</td>
        <td class="mono">${p.age}</td>
      </tr>`;
    });
    P.el('pods-body').innerHTML=ph||'<tr><td colspan="8" class="empty">no pods running in this namespace</td></tr>';

    // deployments
    let dh='';P.el('dep-count').textContent=d.deployments.length;
    d.deployments.forEach(dep=>{
      dh+=`<tr class="${P.depRowClass(dep)}">
        <td class="name">${P.esc(dep.name)}</td>
        <td><span class="chip ${dep.ready===dep.desired?'running':'pending'}">${dep.ready}/${dep.desired}</span></td>
        <td class="num mono">${dep.desired}</td>
        <td class="num mono">${dep.updated}</td>
        <td class="num mono">${dep.available}</td>
        <td class="mono">${P.esc(dep.strategy)}</td>
        <td class="image" title="${P.esc(dep.image)}">${P.esc(dep.image)}</td>
        <td class="mono">${dep.age}</td>
      </tr>`;
    });
    P.el('deps-body').innerHTML=dh||'<tr><td colspan="8" class="empty">no deployments found</td></tr>';

    // services
    let sh='';P.el('svc-count').textContent=d.services.length;
    d.services.forEach(s=>{
      sh+=`<tr class="row-ok">
        <td class="name">${P.esc(s.name)}</td>
        <td><span class="chip ${s.type==='LoadBalancer'?'running':'pending'}">${s.type}</span></td>
        <td class="mono">${P.esc(s.cluster_ip)}</td>
        <td class="mono" style="color:var(--led-teal)">${P.esc(s.external_ip)}</td>
        <td class="mono">${P.esc(s.ports)}</td>
        <td class="mono">${s.age}</td>
      </tr>`;
    });
    P.el('svcs-body').innerHTML=sh||'<tr><td colspan="6" class="empty">no services configured</td></tr>';

    // events
    let eh='';P.el('evt-count').textContent=d.events.length;
    d.events.forEach(e=>{
      eh+=`<div class="ev">
        <span class="ev-type ${e.type}">${e.type}</span>
        <span class="ev-reason">${P.esc(e.reason)}</span>
        <span class="ev-msg" title="${P.esc(e.message)}">${P.esc(e.message)}</span>
        <span class="ev-age">${e.age}</span>
      </div>`;
    });
    P.el('events-body').innerHTML=eh||'<div class="empty">no recent events</div>';
  }catch(e){console.error(e)}
}

async function showLogs(name){
  P.el('logs-modal').classList.add('open');
  P.el('logs-title').textContent=name;
  P.el('logs-content').textContent='loading...';
  try{
    const r=await fetch('/api/pods/'+encodeURIComponent(name)+'/logs');
    const d=await r.json();
    P.el('logs-content').textContent=d.logs||'no logs available';
  }catch(e){P.el('logs-content').textContent='failed to load logs'}
}
function closeLogs(){P.el('logs-modal').classList.remove('open')}
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeLogs()});
P.el('logs-modal').addEventListener('click',e=>{if(e.target===e.currentTarget)closeLogs()});

fetchOverview();
setInterval(fetchOverview,10000);
</script>
</body>
</html>"""
