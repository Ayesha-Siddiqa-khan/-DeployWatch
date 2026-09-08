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
<title>DeployWatch — Cluster Schematic</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600;700&family=IBM+Plex+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
*{margin:0;padding:0;box-sizing:border-box}

:root{
  --paper:#EEF2F5;
  --paper-warm:#E8ECF0;
  --ink:#1B3A5C;
  --ink-light:#3D6B8E;
  --ink-ghost:#7A94AD;
  --grid:#D4DDE6;
  --grid-fine:#E2E8EF;
  --rule:#B8C6D4;
  --rule-light:#CCD6E0;
  --red-pen:#B5452A;
  --red-pen-bg:rgba(181,69,42,.06);
  --green-ink:#2D6B4A;
  --green-ink-bg:rgba(45,107,74,.06);
  --amber-ink:#A06B1A;
  --amber-ink-bg:rgba(160,107,26,.06);
  --blue-ink:#2B5C8A;
  --surface:#F4F7F9;
  --font-sans:'IBM Plex Sans',-apple-system,system-ui,sans-serif;
  --font-mono:'IBM Plex Mono','SF Mono','Fira Code',monospace;
}

html{font-size:14px}
body{
  font-family:var(--font-sans);color:var(--ink);
  background-color:var(--paper);background-image:
    linear-gradient(var(--grid-fine) 1px,transparent 1px),
    linear-gradient(90deg,var(--grid-fine) 1px,transparent 1px),
    linear-gradient(var(--grid) 1px,transparent 1px),
    linear-gradient(90deg,var(--grid) 1px,transparent 1px);
  background-size:
    10px 10px,10px 10px,
    50px 50px,50px 50px;
  min-height:100vh;-webkit-font-smoothing:antialiased;
}

/* ── title block (blueprint convention) ── */
.title-block{
  position:sticky;top:0;z-index:100;
  background:var(--paper);border-bottom:2px solid var(--ink);
  padding:12px 32px;
  display:flex;align-items:flex-end;justify-content:space-between;
  gap:24px;
}
.title-block::after{content:'';position:absolute;bottom:-3px;left:0;right:0;height:1px;background:var(--ink)}
.tb-left{display:flex;flex-direction:column;gap:2px}
.tb-title{font-family:var(--font-mono);font-weight:700;font-size:16px;color:var(--ink);letter-spacing:-.02em}
.tb-sub{font-size:11px;color:var(--ink-light);font-weight:500}
.tb-right{display:flex;gap:24px;align-items:flex-end}
.tb-field{display:flex;flex-direction:column;gap:1px}
.tb-field-label{font-size:8px;font-weight:600;text-transform:uppercase;letter-spacing:.1em;color:var(--ink-ghost)}
.tb-field-value{font-family:var(--font-mono);font-size:11px;font-weight:500;color:var(--ink)}
.tb-live{display:flex;align-items:center;gap:6px}
.tb-live-dot{width:6px;height:6px;border-radius:50%;background:var(--green-ink)}
.tb-live-dot.live{animation:blink 2s ease-in-out infinite}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.3}}

/* ── layout ── */
.main{position:relative;z-index:1;max-width:1440px;margin:0 auto;padding:20px 32px 60px}

/* ── dimension callouts (stats) ── */
.dims{
  display:grid;grid-template-columns:repeat(5,1fr);gap:0;
  margin-bottom:24px;
  border:1.5px solid var(--ink);
}
.dim{
  padding:14px 16px;border-right:1px solid var(--rule);
  display:flex;flex-direction:column;gap:2px;
}
.dim:last-child{border-right:none}
.dim-label{font-size:9px;font-weight:600;text-transform:uppercase;letter-spacing:.08em;color:var(--ink-ghost)}
.dim-value{font-family:var(--font-mono);font-size:26px;font-weight:700;line-height:1;color:var(--ink)}
.dim-value.v-green{color:var(--green-ink)}
.dim-value.v-red{color:var(--red-pen)}
.dim-value.v-blue{color:var(--blue-ink)}
.dim-value.v-amber{color:var(--amber-ink)}

/* ── sections ── */
.section{margin-bottom:24px}
.section-head{
  display:flex;align-items:baseline;gap:8px;
  padding-bottom:6px;border-bottom:1.5px solid var(--ink);
  margin-bottom:0;
}
.section-head h2{
  font-size:13px;font-weight:600;color:var(--ink);letter-spacing:-.01em;
}
.section-head .line{flex:1;border-bottom:1px dotted var(--rule)}
.section-head .cnt{
  font-family:var(--font-mono);font-size:11px;font-weight:600;color:var(--ink-light);
}

/* ── tables (ruled schedules) ── */
.tbl{overflow-x:auto}
table{width:100%;border-collapse:collapse}
thead{position:sticky;top:0;z-index:2}
th{
  text-align:left;padding:6px 10px;
  font-size:9px;font-weight:600;text-transform:uppercase;letter-spacing:.08em;
  color:var(--ink-ghost);
  background:var(--paper-warm);
  border-bottom:1.5px solid var(--ink);
}
th.r,td.r{text-align:right;font-variant-numeric:tabular-nums}
td{
  padding:5px 10px;font-size:12px;
  border-bottom:1px solid var(--rule-light);
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
}
tr:hover td{background:var(--surface)}
/* row states via left cross-mark */
tr.r-ok td:first-child{box-shadow:inset 3px 0 0 var(--green-ink)}
tr.r-warn td:first-child{box-shadow:inset 3px 0 0 var(--amber-ink)}
tr.r-err td:first-child{box-shadow:inset 3px 0 0 var(--red-pen)}
/* status cross-marks */
.cross{display:inline-flex;align-items:center;gap:4px;font-family:var(--font-mono);font-size:11px;font-weight:500}
.cross::before{content:'';width:8px;height:8px;flex-shrink:0}
.cross.running::before{content:'\\2713';color:var(--green-ink);font-weight:700;font-size:10px}
.cross.pending::before{content:'\\25CB';color:var(--amber-ink);font-size:12px;line-height:1}
.cross.failed::before,.cross.error::before{content:'\\2717';color:var(--red-pen);font-weight:700;font-size:11px}
.cross.succeeded::before{content:'\\2713';color:var(--blue-ink);font-weight:700;font-size:10px}
.cross.ok::before{content:'\\2713';color:var(--green-ink);font-weight:700;font-size:10px}
.cross.no::before{content:'\\2717';color:var(--red-pen);font-weight:700;font-size:11px}

.mono{font-family:var(--font-mono);font-size:11px;color:var(--ink-light)}
.name-cell{font-family:var(--font-mono);font-weight:600;font-size:12px;color:var(--ink);max-width:280px;overflow:hidden;text-overflow:ellipsis}
.img-cell{font-family:var(--font-mono);font-size:11px;color:var(--ink-ghost);max-width:260px;overflow:hidden;text-overflow:ellipsis}

/* ── events ── */
.evt-wrap{border:1.5px solid var(--ink);max-height:380px;overflow-y:auto;background:var(--paper)}
.ev{
  display:grid;grid-template-columns:56px 100px 1fr 40px;gap:8px;
  padding:5px 10px;border-bottom:1px solid var(--rule-light);
  font-size:11px;align-items:baseline;
}
.ev:last-child{border-bottom:none}
.ev:hover{background:var(--surface)}
.ev-tp{font-family:var(--font-mono);font-weight:700;font-size:10px}
.ev-tp.Warning{color:var(--amber-ink)}
.ev-tp.Normal{color:var(--green-ink)}
.ev-tp.Error{color:var(--red-pen)}
.ev-rs{font-family:var(--font-mono);font-weight:600;color:var(--blue-ink);font-size:10px}
.ev-msg{color:var(--ink-light);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ev-ag{font-family:var(--font-mono);color:var(--ink-ghost);text-align:right;font-size:10px}

/* ── logs modal ── */
.modal-bg{
  display:none;position:fixed;inset:0;background:rgba(238,242,245,.92);
  z-index:200;align-items:center;justify-content:center;
  backdrop-filter:blur(2px);
}
.modal-bg.open{display:flex}
.modal{
  background:var(--paper);border:2px solid var(--ink);width:920px;max-height:80vh;
  display:flex;flex-direction:column;
}
.modal-hd{
  padding:10px 16px;border-bottom:1.5px solid var(--ink);
  display:flex;justify-content:space-between;align-items:center;
}
.modal-hd h3{font-family:var(--font-mono);font-size:13px;font-weight:600}
.modal-x{
  background:none;border:1px solid var(--rule);color:var(--ink-light);
  cursor:pointer;font-size:16px;padding:2px 8px;line-height:1;
  transition:color .15s,border-color .15s;
}
.modal-x:hover{color:var(--ink);border-color:var(--ink)}
.modal pre{
  padding:16px;overflow:auto;flex:1;font-size:12px;line-height:1.7;
  color:var(--ink-light);font-family:var(--font-mono);
  white-space:pre-wrap;word-break:break-all;
}

/* ── empty states ── */
.empty{
  padding:28px;text-align:center;color:var(--ink-ghost);
  font-family:var(--font-mono);font-size:12px;font-style:italic;
}

/* ── focus ── */
:focus-visible{outline:2px solid var(--blue-ink);outline-offset:2px}

/* ── row entry ── */
@keyframes draw-in{from{opacity:0;transform:translateX(-6px)}to{opacity:1;transform:translateX(0)}}
tr.new td{animation:draw-in .2s ease-out}

/* ── cross-mark annotation for failures ── */
.annotate{position:relative}
.annotate::after{
  content:'\\2020';position:absolute;right:4px;top:50%;transform:translateY(-50%);
  color:var(--red-pen);font-size:10px;font-weight:700;opacity:.6;
}

/* ── responsive ── */
@media(max-width:1000px){
  .dims{grid-template-columns:repeat(3,1fr)}
  .dim:nth-child(3){border-right:none}
  .dim:nth-child(4),.dim:nth-child(5){border-top:1px solid var(--rule)}
  .ev{grid-template-columns:46px 80px 1fr 36px}
}
@media(max-width:600px){
  .dims{grid-template-columns:repeat(2,1fr)}
  .dim:nth-child(2){border-right:none}
  .tb-right{display:none}
  .main{padding:12px 16px}
  .title-block{padding:10px 16px}
}
</style>
</head>
<body>

<div class="title-block">
  <div class="tb-left">
    <div class="tb-title">DeployWatch</div>
    <div class="tb-sub">Kubernetes Cluster Schematic</div>
  </div>
  <div class="tb-right">
    <div class="tb-field">
      <span class="tb-field-label">Namespace</span>
      <span class="tb-field-value" id="ns">--</span>
    </div>
    <div class="tb-field">
      <span class="tb-field-label">Revision</span>
      <span class="tb-field-value" id="rev">--</span>
    </div>
    <div class="tb-field">
      <span class="tb-field-label">Last Updated</span>
      <span class="tb-field-value" id="last-update">--:--:--</span>
    </div>
    <div class="tb-field">
      <span class="tb-field-label">Status</span>
      <span class="tb-field-value tb-live"><span class="tb-live-dot live"></span> Live</span>
    </div>
  </div>
</div>

<div class="main">

  <div class="dims">
    <div class="dim"><span class="dim-label">Running</span><span class="dim-value v-green" id="s-running">0</span></div>
    <div class="dim"><span class="dim-label">Failed</span><span class="dim-value v-red" id="s-failed">0</span></div>
    <div class="dim"><span class="dim-label">Total Pods</span><span class="dim-value v-blue" id="s-total">0</span></div>
    <div class="dim"><span class="dim-label">Deployments</span><span class="dim-value" id="s-deps">0</span></div>
    <div class="dim"><span class="dim-label">Services</span><span class="dim-value" id="s-svcs">0</span></div>
  </div>

  <div class="section">
    <div class="section-head">
      <h2>Pods</h2><span class="line"></span><span class="cnt" id="pod-count">0</span>
    </div>
    <div class="tbl"><table>
      <thead><tr>
        <th style="width:28%">Name</th>
        <th style="width:9%">Status</th>
        <th style="width:7%">Ready</th>
        <th class="r" style="width:8%">Restarts</th>
        <th style="width:14%">Node</th>
        <th style="width:12%">IP</th>
        <th style="width:16%">Image</th>
        <th style="width:6%">Age</th>
      </tr></thead>
      <tbody id="pods-body"></tbody>
    </table></div>
  </div>

  <div class="section">
    <div class="section-head">
      <h2>Deployments</h2><span class="line"></span><span class="cnt" id="dep-count">0</span>
    </div>
    <div class="tbl"><table>
      <thead><tr>
        <th style="width:22%">Name</th>
        <th style="width:10%">Ready</th>
        <th class="r" style="width:8%">Desired</th>
        <th class="r" style="width:8%">Updated</th>
        <th class="r" style="width:9%">Available</th>
        <th style="width:10%">Strategy</th>
        <th style="width:20%">Image</th>
        <th style="width:7%">Age</th>
      </tr></thead>
      <tbody id="deps-body"></tbody>
    </table></div>
  </div>

  <div class="section">
    <div class="section-head">
      <h2>Services</h2><span class="line"></span><span class="cnt" id="svc-count">0</span>
    </div>
    <div class="tbl"><table>
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

  <div class="section">
    <div class="section-head">
      <h2>Events</h2><span class="line"></span><span class="cnt" id="evt-count">0</span>
    </div>
    <div class="evt-wrap" id="events-body"></div>
  </div>

</div>

<div class="modal-bg" id="logs-modal">
  <div class="modal">
    <div class="modal-hd">
      <h3 id="logs-title">pod logs</h3>
      <button class="modal-x" onclick="closeLogs()" aria-label="Close">&times;</button>
    </div>
    <pre id="logs-content">loading...</pre>
  </div>
</div>

<script>
const D={
  el:id=>document.getElementById(id),
  esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML},
  sc(s){return s==='Running'?'running':s==='Pending'?'pending':s==='Failed'||s==='Error'?'failed':s==='Succeeded'?'succeeded':'pending'},
  rc(p){
    if(p.status==='Failed'||p.status==='Error')return 'r-err';
    if(p.status==='Pending'||p.restarts>0)return 'r-warn';
    return 'r-ok';
  },
  dc(d){return d.ready===d.desired?'r-ok':d.ready>0?'r-warn':'r-err'},
  rev:0,
};

async function poll(){
  try{
    const r=await fetch('/api/overview');
    if(!r.ok)return;
    const d=await r.json();
    D.rev++;
    const t=new Date();
    D.el('ns').textContent=d.namespace;
    D.el('rev').textContent='r'+D.rev;
    D.el('last-update').textContent=t.toLocaleTimeString('en-GB');
    D.el('s-running').textContent=d.summary.running_pods;
    D.el('s-failed').textContent=d.summary.failed_pods;
    D.el('s-total').textContent=d.summary.total_pods;
    D.el('s-deps').textContent=d.summary.total_deployments;
    D.el('s-svcs').textContent=d.summary.total_services;

    let ph='';D.el('pod-count').textContent=d.pods.length;
    d.pods.forEach(p=>{
      ph+=`<tr class="${D.rc(p)}">
        <td class="name-cell">${D.esc(p.name)}</td>
        <td><span class="cross ${D.sc(p.status)}">${p.status}</span></td>
        <td><span class="cross ${p.ready?'ok':'no'}">${p.ready?'yes':'no'}</span></td>
        <td class="r mono">${p.restarts}</td>
        <td class="mono">${D.esc(p.node)}</td>
        <td class="mono">${D.esc(p.ip)}</td>
        <td class="img-cell" title="${D.esc(p.image)}">${D.esc(p.image)}</td>
        <td class="mono">${p.age}</td>
      </tr>`;
    });
    D.el('pods-body').innerHTML=ph||'<tr><td colspan="8" class="empty">no pods running in this namespace</td></tr>';

    let dh='';D.el('dep-count').textContent=d.deployments.length;
    d.deployments.forEach(dep=>{
      dh+=`<tr class="${D.dc(dep)}">
        <td class="name-cell">${D.esc(dep.name)}</td>
        <td><span class="cross ${dep.ready===dep.desired?'running':'pending'}">${dep.ready}/${dep.desired}</span></td>
        <td class="r mono">${dep.desired}</td>
        <td class="r mono">${dep.updated}</td>
        <td class="r mono">${dep.available}</td>
        <td class="mono">${D.esc(dep.strategy)}</td>
        <td class="img-cell" title="${D.esc(dep.image)}">${D.esc(dep.image)}</td>
        <td class="mono">${dep.age}</td>
      </tr>`;
    });
    D.el('deps-body').innerHTML=dh||'<tr><td colspan="8" class="empty">no deployments recorded</td></tr>';

    let sh='';D.el('svc-count').textContent=d.services.length;
    d.services.forEach(s=>{
      sh+=`<tr class="r-ok">
        <td class="name-cell">${D.esc(s.name)}</td>
        <td><span class="cross ${s.type==='LoadBalancer'?'running':'pending'}">${s.type}</span></td>
        <td class="mono">${D.esc(s.cluster_ip)}</td>
        <td class="mono" style="color:var(--blue-ink)">${D.esc(s.external_ip)}</td>
        <td class="mono">${D.esc(s.ports)}</td>
        <td class="mono">${s.age}</td>
      </tr>`;
    });
    D.el('svcs-body').innerHTML=sh||'<tr><td colspan="6" class="empty">no services configured</td></tr>';

    let eh='';D.el('evt-count').textContent=d.events.length;
    d.events.forEach(e=>{
      eh+=`<div class="ev">
        <span class="ev-tp ${e.type}">${e.type}</span>
        <span class="ev-rs">${D.esc(e.reason)}</span>
        <span class="ev-msg" title="${D.esc(e.message)}">${D.esc(e.message)}</span>
        <span class="ev-ag">${e.age}</span>
      </div>`;
    });
    D.el('events-body').innerHTML=eh||'<div class="empty">no events recorded</div>';
  }catch(e){console.error(e)}
}

async function showLogs(name){
  D.el('logs-modal').classList.add('open');
  D.el('logs-title').textContent=name;
  D.el('logs-content').textContent='loading...';
  try{
    const r=await fetch('/api/pods/'+encodeURIComponent(name)+'/logs');
    const d=await r.json();
    D.el('logs-content').textContent=d.logs||'no logs available';
  }catch(e){D.el('logs-content').textContent='failed to load logs'}
}
function closeLogs(){D.el('logs-modal').classList.remove('open')}
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeLogs()});
D.el('logs-modal').addEventListener('click',e=>{if(e.target===e.currentTarget)closeLogs()});

poll();setInterval(poll,10000);
</script>
</body>
</html>"""
