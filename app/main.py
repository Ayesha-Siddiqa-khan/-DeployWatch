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
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#0a0a0f;--surface:#12121a;--surface2:#1a1a25;--border:#2a2a3a;--text:#e0e0e8;--muted:#666680;--accent:#6c5ce7;--accent2:#a29bfe;--green:#00b894;--red:#e74c3c;--yellow:#f39c12;--blue:#3498db;--orange:#e67e22}
body{font-family:'Inter',-apple-system,system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
a{color:var(--accent2);text-decoration:none}
.topbar{background:var(--surface);border-bottom:1px solid var(--border);padding:16px 32px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:100;backdrop-filter:blur(12px)}
.topbar h1{font-size:20px;font-weight:700;display:flex;align-items:center;gap:10px}
.topbar h1 .icon{font-size:24px}
.topbar .meta{display:flex;gap:16px;align-items:center;color:var(--muted);font-size:13px}
.topbar .dot{width:8px;height:8px;border-radius:50%;background:var(--green);display:inline-block;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.container{max-width:1400px;margin:0 auto;padding:24px 32px}
.stats{display:grid;grid-template-columns:repeat(5,1fr);gap:16px;margin-bottom:24px}
.stat{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:20px;text-align:center;transition:transform .2s}
.stat:hover{transform:translateY(-2px)}
.stat .num{font-size:32px;font-weight:800;line-height:1}
.stat .label{font-size:12px;color:var(--muted);margin-top:6px;text-transform:uppercase;letter-spacing:1px}
.stat.green .num{color:var(--green)}
.stat.red .num{color:var(--red)}
.stat.blue .num{color:var(--blue)}
.stat.accent .num{color:var(--accent2)}
.stat.yellow .num{color:var(--yellow)}
.section{margin-bottom:24px}
.section-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}
.section-head h2{font-size:16px;font-weight:600;display:flex;align-items:center;gap:8px}
.section-head .badge{background:var(--accent);color:#fff;font-size:11px;padding:2px 8px;border-radius:99px;font-weight:600}
.table-wrap{background:var(--surface);border:1px solid var(--border);border-radius:12px;overflow:hidden}
table{width:100%;border-collapse:collapse}
th{text-align:left;padding:12px 16px;font-size:11px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);background:var(--surface2);border-bottom:1px solid var(--border)}
td{padding:12px 16px;font-size:13px;border-bottom:1px solid var(--border);white-space:nowrap}
tr:last-child td{border-bottom:none}
tr:hover{background:var(--surface2)}
.status{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:6px;font-size:12px;font-weight:600}
.status.running{background:rgba(0,184,148,.15);color:var(--green)}
.status.pending{background:rgba(243,156,18,.15);color:var(--yellow)}
.status.failed,.status.error{background:rgba(231,76,60,.15);color:var(--red)}
.status.succeeded{background:rgba(0,184,148,.15);color:var(--green)}
.status::before{content:'';width:6px;height:6px;border-radius:50%;background:currentColor}
.status-dot{width:8px;height:8px;border-radius:50%;display:inline-block}
.status-dot.ok{background:var(--green)}
.status-dot.warn{background:var(--yellow)}
.status-dot.err{background:var(--red)}
.events{max-height:400px;overflow-y:auto}
.event{display:flex;gap:12px;padding:10px 16px;border-bottom:1px solid var(--border);font-size:13px;align-items:flex-start}
.event:last-child{border-bottom:none}
.event .type{font-weight:700;min-width:60px}
.event .type.Warning{color:var(--yellow)}
.event .type.Normal{color:var(--green)}
.event .reason{color:var(--accent2);min-width:120px;font-weight:600;font-size:12px}
.event .msg{color:var(--muted);flex:1;overflow:hidden;text-overflow:ellipsis}
.event .age{color:var(--muted);min-width:40px;text-align:right}
.logs-modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:200;align-items:center;justify-content:center}
.logs-modal.open{display:flex}
.logs-box{background:var(--surface);border:1px solid var(--border);border-radius:12px;width:900px;max-height:80vh;display:flex;flex-direction:column}
.logs-box .head{padding:16px 20px;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center}
.logs-box .head h3{font-size:15px}
.logs-box .close{background:none;border:none;color:var(--muted);cursor:pointer;font-size:20px;padding:4px 8px}
.logs-box .close:hover{color:var(--text)}
.logs-box pre{padding:20px;overflow:auto;flex:1;font-size:13px;line-height:1.6;color:#b8b8cc;font-family:'Fira Code',monospace;white-space:pre-wrap;word-break:break-all}
.btn{background:var(--accent);color:#fff;border:none;padding:6px 14px;border-radius:6px;font-size:12px;cursor:pointer;font-weight:600;transition:background .2s}
.btn:hover{background:var(--accent2)}
.empty{text-align:center;padding:40px;color:var(--muted)}
@media(max-width:900px){.stats{grid-template-columns:repeat(2,1fr)}.container{padding:16px}}
</style>
</head>
<body>
<div class="topbar">
  <h1><span class="icon">&#x1F680;</span> DeployWatch</h1>
  <div class="meta">
    <span>Namespace: <strong id="ns">-</strong></span>
    <span><span class="dot"></span> Live</span>
    <span id="last-update">-</span>
  </div>
</div>
<div class="container">
  <div class="stats">
    <div class="stat green"><div class="num" id="s-running">0</div><div class="label">Running Pods</div></div>
    <div class="stat red"><div class="num" id="s-failed">0</div><div class="label">Failed Pods</div></div>
    <div class="stat blue"><div class="num" id="s-total">0</div><div class="label">Total Pods</div></div>
    <div class="stat accent"><div class="num" id="s-deps">0</div><div class="label">Deployments</div></div>
    <div class="stat yellow"><div class="num" id="s-svcs">0</div><div class="label">Services</div></div>
  </div>

  <div class="section">
    <div class="section-head"><h2>&#x1F4E6; Pods <span class="badge" id="pod-count">0</span></h2></div>
    <div class="table-wrap"><table><thead><tr><th>Name</th><th>Status</th><th>Ready</th><th>Restarts</th><th>Node</th><th>IP</th><th>Image</th><th>Age</th><th></th></tr></thead><tbody id="pods-body"></tbody></table></div>
  </div>

  <div class="section">
    <div class="section-head"><h2>&#x1F3D7; Deployments <span class="badge" id="dep-count">0</span></h2></div>
    <div class="table-wrap"><table><thead><tr><th>Name</th><th>Ready</th><th>Desired</th><th>Updated</th><th>Available</th><th>Strategy</th><th>Image</th><th>Age</th></tr></thead><tbody id="deps-body"></tbody></table></div>
  </div>

  <div class="section">
    <div class="section-head"><h2>&#x1F310; Services <span class="badge" id="svc-count">0</span></h2></div>
    <div class="table-wrap"><table><thead><tr><th>Name</th><th>Type</th><th>Cluster IP</th><th>External IP</th><th>Ports</th><th>Age</th></tr></thead><tbody id="svcs-body"></tbody></table></div>
  </div>

  <div class="section">
    <div class="section-head"><h2>&#x1F4CB; Recent Events <span class="badge" id="evt-count">0</span></h2></div>
    <div class="table-wrap events" id="events-body"></div>
  </div>
</div>

<div class="logs-modal" id="logs-modal">
  <div class="logs-box">
    <div class="head"><h3 id="logs-title">Pod Logs</h3><button class="close" onclick="closeLogs()">&times;</button></div>
    <pre id="logs-content">Loading...</pre>
  </div>
</div>

<script>
function statusClass(s){return s==='Running'?'running':s==='Pending'?'pending':s==='Failed'||s==='Error'?'failed':s==='Succeeded'?'succeeded':'pending'}
async function fetchOverview(){
  try{
    const r=await fetch('/api/overview');const d=await r.json();
    document.getElementById('ns').textContent=d.namespace;
    document.getElementById('last-update').textContent=new Date().toLocaleTimeString();
    document.getElementById('s-running').textContent=d.summary.running_pods;
    document.getElementById('s-failed').textContent=d.summary.failed_pods;
    document.getElementById('s-total').textContent=d.summary.total_pods;
    document.getElementById('s-deps').textContent=d.summary.total_deployments;
    document.getElementById('s-svcs').textContent=d.summary.total_services;
    let podsHtml='';document.getElementById('pod-count').textContent=d.pods.length;
    d.pods.forEach(p=>{
      podsHtml+=`<tr>
        <td><strong>${p.name}</strong></td>
        <td><span class="status ${statusClass(p.status)}">${p.status}</span></td>
        <td>${p.ready?'<span class="status-dot ok"></span> Yes':'<span class="status-dot err"></span> No'}</td>
        <td>${p.restarts}</td>
        <td style="color:var(--muted)">${p.node}</td>
        <td style="color:var(--muted)">${p.ip}</td>
        <td style="color:var(--muted);max-width:200px;overflow:hidden;text-overflow:ellipsis">${p.image}</td>
        <td style="color:var(--muted)">${p.age}</td>
        <td><button class="btn" onclick="showLogs('${p.name}')">Logs</button></td>
      </tr>`;
    });
    document.getElementById('pods-body').innerHTML=podsHtml||'<tr><td colspan="9" class="empty">No pods found</td></tr>';
    let depsHtml='';document.getElementById('dep-count').textContent=d.deployments.length;
    d.deployments.forEach(dep=>{
      depsHtml+=`<tr>
        <td><strong>${dep.name}</strong></td>
        <td><span class="status ${dep.ready===dep.desired?'running':'pending'}">${dep.ready}/${dep.desired}</span></td>
        <td>${dep.desired}</td><td>${dep.updated}</td><td>${dep.available}</td>
        <td style="color:var(--muted)">${dep.strategy}</td>
        <td style="color:var(--muted);max-width:200px;overflow:hidden;text-overflow:ellipsis">${dep.image}</td>
        <td style="color:var(--muted)">${dep.age}</td>
      </tr>`;
    });
    document.getElementById('deps-body').innerHTML=depsHtml||'<tr><td colspan="8" class="empty">No deployments found</td></tr>';
    let svcsHtml='';document.getElementById('svc-count').textContent=d.services.length;
    d.services.forEach(s=>{
      svcsHtml+=`<tr>
        <td><strong>${s.name}</strong></td>
        <td><span class="status ${s.type==='LoadBalancer'?'running':'pending'}">${s.type}</span></td>
        <td style="color:var(--muted)">${s.cluster_ip}</td>
        <td style="color:var(--accent2)">${s.external_ip}</td>
        <td style="color:var(--muted)">${s.ports}</td>
        <td style="color:var(--muted)">${s.age}</td>
      </tr>`;
    });
    document.getElementById('svcs-body').innerHTML=svcsHtml||'<tr><td colspan="6" class="empty">No services found</td></tr>';
    let evtsHtml='';document.getElementById('evt-count').textContent=d.events.length;
    d.events.forEach(e=>{
      evtsHtml+=`<div class="event">
        <span class="type ${e.type}">${e.type}</span>
        <span class="reason">${e.reason}</span>
        <span class="msg">${e.message}</span>
        <span class="age">${e.age}</span>
      </div>`;
    });
    document.getElementById('events-body').innerHTML=evtsHtml||'<div class="empty">No events</div>';
  }catch(e){console.error('Fetch error:',e)}
}
async function showLogs(name){
  document.getElementById('logs-modal').classList.add('open');
  document.getElementById('logs-title').textContent='Logs: '+name;
  document.getElementById('logs-content').textContent='Loading...';
  const r=await fetch('/api/pods/'+name+'/logs');const d=await r.json();
  document.getElementById('logs-content').textContent=d.logs||'No logs available';
}
function closeLogs(){document.getElementById('logs-modal').classList.remove('open')}
document.getElementById('logs-modal').addEventListener('click',function(e){if(e.target===this)closeLogs()});
fetchOverview();setInterval(fetchOverview,10000);
</script>
</body>
</html>"""
