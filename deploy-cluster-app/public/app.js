/* =========================================================
   app.js — Nutanix Cluster Deployment Manager
   ========================================================= */

/* ── Tab switching ────────────────────────────────────────── */
document.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('.tab-btn-main').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelectorAll('.tab-btn-main').forEach(b => b.classList.remove('active'));
            document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
            btn.classList.add('active');
            const target = document.getElementById(btn.dataset.tabTarget);
            if (target) target.classList.add('active');
        });
    });
});

let currentFormat    = 'json';
let ws               = null;
let loadedConfigFile = null;  // filename of the currently-loaded config (no date-stamp copy)

/* =========================================================
   Log colorizer — pattern-based, works without ANSI codes.
   Matches text content and assigns VS Code-style colors.
   ========================================================= */
function colorizeOutput(raw) {
    // Strip any ANSI escape codes that may come through (clean slate)
    const text = raw.replace(/\x1b\[[0-9;]*[mGKHFJA-Za-z]/g, '');

    const lines = text.split(/\r?\n/);
    return lines.map(line => {
        const t = line.trimEnd();
        if (!t) return '';

        // Escape HTML
        const h = t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

        // ── PASS / FAIL / WARN check lines ──────────────────────────────────
        if (/^\s+[✓✔]/.test(t))  return `<span class="cl-pass">${h}</span>`;
        if (/^\s+[✗✘✕]/.test(t)) return `<span class="cl-fail">${h}</span>`;
        if (/^\s+[⚠⚡!]/.test(t)) return `<span class="cl-warn">${h}</span>`;

        // ── Suggested action items ───────────────────────────────────────────
        if (/^\s+\[\d+\]\s+[✗✘]/.test(t)) return `<span class="cl-fail">${h}</span>`;
        if (/^\s+\[\d+\]\s+[⚠]/.test(t))  return `<span class="cl-warn">${h}</span>`;
        if (/^\s+Action\s*:/.test(t))       return `<span class="cl-action">${h}</span>`;
        if (/^\s+Problem\s*:/.test(t))      return `<span class="cl-problem">${h}</span>`;

        // ── Summary border lines (═══) ───────────────────────────────────────
        if (/^[═\s]{6,}$/.test(t.trim()) || /^═{6}/.test(t.trim())) {
            if (/ Fail:\s*[1-9]/.test(t))                                     return `<span class="cl-fail">${h}</span>`;
            if (/ Warn:\s*[1-9]/.test(t) && !/ Fail:\s*[1-9]/.test(t))       return `<span class="cl-warn">${h}</span>`;
            return `<span class="cl-pass">${h}</span>`;
        }

        // ── PRE-FLIGHT / pipeline summary line ───────────────────────────────
        if (/PRE-FLIGHT SUMMARY/.test(t)) {
            if (/ Fail:\s*[1-9]/.test(t))                                     return `<span class="cl-fail cl-bold">${h}</span>`;
            if (/ Warn:\s*[1-9]/.test(t) && !/ Fail:\s*[1-9]/.test(t))       return `<span class="cl-warn cl-bold">${h}</span>`;
            return `<span class="cl-pass cl-bold">${h}</span>`;
        }

        // ── Banner lines (header of each run) ────────────────────────────────
        if (/^[═]{10,}/.test(t.trim())) return `<span class="cl-banner">${h}</span>`;
        if (/PRE-FLIGHT CHECKS|DryRun Mode/.test(t)) return `<span class="cl-banner cl-bold">${h}</span>`;

        // ── Section dividers  ── … ──────────────────────────────────────────
        if (/^\s+──/.test(t)) return `<span class="cl-section">${h}</span>`;

        // ── Pipeline step headers  STEP N/15 ─────────────────────────────────
        if (/\bSTEP\s+\d+\/\d+\b/.test(t)) return `<span class="cl-step cl-bold">${h}</span>`;

        // ── Step result lines ────────────────────────────────────────────────
        if (/\bSUCCEEDED\b/.test(t))                        return `<span class="cl-pass">${h}</span>`;
        if (/\bFAILED\b/.test(t) || /\bERROR\b/i.test(t))  return `<span class="cl-fail">${h}</span>`;
        if (/\bSKIPPED\b/.test(t))                          return `<span class="cl-skip">${h}</span>`;

        // ── Config / Cluster info header lines ───────────────────────────────
        if (/^\s+(Config|Cluster)\s*:/.test(t)) return `<span class="cl-meta">${h}</span>`;

        // ── Countdown / delay lines ──────────────────────────────────────────
        if (/Waiting|Retrying|Delay|seconds?|countdown/i.test(t)) return `<span class="cl-delay">${h}</span>`;

        // Default — plain terminal text
        return `<span class="cl-default">${h}</span>`;
    }).join('\n');
}

// 15 steps matching Start-Pipeline.ps1 exactly
let deploymentSteps = [
    { id: 'step1',  title: 'Phoenix Boot',                    status: 'pending' },
    { id: 'step2',  title: 'Phoenix Boot Check',              status: 'pending' },
    { id: 'step3',  title: 'Node Discovery Check',            status: 'pending' },
    { id: 'step4',  title: 'Image & Deploy Cluster',          status: 'pending' },
    { id: 'step5',  title: 'Accept EULA',                     status: 'pending' },
    { id: 'step6',  title: 'Register to Witness VM',          status: 'pending' },
    { id: 'step7',  title: 'Register to Prism Central',       status: 'pending' },
    { id: 'step8',  title: 'Create Production VLANs',         status: 'pending' },
    { id: 'step9',  title: 'Create Storage Container',        status: 'pending' },
    { id: 'step10', title: 'Create Backup Policies',          status: 'pending' },
    { id: 'step11', title: 'Create Protection Policy',        status: 'pending' },
    { id: 'step12', title: 'Create Recovery Plan',            status: 'pending' },
    { id: 'step13', title: 'Set AHV Bond Mode',               status: 'pending' },
    { id: 'step14', title: 'Change Passwords & Export CSV',   status: 'pending' },
    { id: 'step15', title: 'Import Secrets to CyberArk',      status: 'pending' },
    { id: 'step16', title: 'Add DNS Records',                  status: 'pending' }
];

/* =========================================================
   Theme Toggle
   ========================================================= */
function toggleTheme() {
    const root = document.documentElement;
    const btn  = document.getElementById('themeToggleBtn');
    if (root.dataset.theme === 'light') {
        delete root.dataset.theme;          // back to dark
        if (btn) btn.textContent = '🌙 Dark';
    } else {
        root.dataset.theme = 'light';
        if (btn) btn.textContent = '☀ Light';
    }
}

/* =========================================================
   Password Visibility Toggle
   ========================================================= */
function togglePasswordField(fieldId, buttonElement) {
    const input = document.getElementById(fieldId);
    const icon  = buttonElement.querySelector('span');
    if (input.type === 'password') {
        input.type = 'text';
        icon.textContent = '🙈';
    } else {
        input.type = 'password';
        icon.textContent = '👁️';
    }
}

/* =========================================================
   Dynamic VLAN Row Rendering
   ========================================================= */

function buildVlanTile(n, values) {
    const vals = values || {};
    const div = document.createElement('div');
    div.className = 'form-row-grid';
    div.innerHTML = `
        <div class="form-group">
            <label>Subnet Name <span class="required-mark">*</span></label>
            <input type="text" name="production_vlans.${n}.subnet_name" value="${escHtml(vals.subnet_name || '')}" placeholder="e.g. vLAN-201">
        </div>
        <div class="form-group">
            <label>VLAN ID <span class="required-mark">*</span></label>
            <input type="number" name="production_vlans.${n}.vlan_id" value="${escHtml(String(vals.vlan_id !== undefined ? vals.vlan_id : ''))}" placeholder="e.g. 201">
        </div>
        <div class="form-group">
            <label>Gateway <span class="required-mark">*</span></label>
            <input type="text" name="production_vlans.${n}.gateway" value="${escHtml(vals.gateway || '')}" placeholder="e.g. 10.0.201.1">
        </div>
        <div class="form-group">
            <label>Prefix Length <span class="required-mark">*</span></label>
            <input type="number" name="production_vlans.${n}.prefix_length" value="${escHtml(String(vals.prefix_length !== undefined ? vals.prefix_length : ''))}" placeholder="e.g. 24">
        </div>
        <div class="form-group">
            <label>IP Pool Start <span class="required-mark">*</span></label>
            <input type="text" name="production_vlans.${n}.ip_pool_start" value="${escHtml(vals.ip_pool_start || '')}" placeholder="e.g. 10.0.201.10">
        </div>
        <div class="form-group">
            <label>IP Pool End <span class="required-mark">*</span></label>
            <input type="text" name="production_vlans.${n}.ip_pool_end" value="${escHtml(vals.ip_pool_end || '')}" placeholder="e.g. 10.0.201.50">
        </div>
    `;
    return div;
}

function readCurrentVlanValues() {
    const values = [];
    const container = document.getElementById('vlanRowsContainer');
    if (!container) return values;
    container.querySelectorAll('.vlan-tile').forEach((tile, idx) => {
        values[idx] = {
            subnet_name:   (tile.querySelector(`[name="production_vlans.${idx}.subnet_name"]`)   || {}).value || '',
            vlan_id:       (tile.querySelector(`[name="production_vlans.${idx}.vlan_id"]`)        || {}).value || '',
            gateway:       (tile.querySelector(`[name="production_vlans.${idx}.gateway"]`)        || {}).value || '',
            prefix_length: (tile.querySelector(`[name="production_vlans.${idx}.prefix_length"]`)  || {}).value || '',
            ip_pool_start: (tile.querySelector(`[name="production_vlans.${idx}.ip_pool_start"]`)  || {}).value || '',
            ip_pool_end:   (tile.querySelector(`[name="production_vlans.${idx}.ip_pool_end"]`)    || {}).value || ''
        };
    });
    return values;
}

function renderVlanRows(count, forcedValues) {
    const container = document.getElementById('vlanRowsContainer');
    if (!container) return;
    const existing = forcedValues || readCurrentVlanValues();
    container.innerHTML = '';
    for (let n = 0; n < count; n++) {
        container.appendChild(buildVlanTile(n, existing[n] || {}));
    }
}

function removeVlanTile(n) {
    const existing = readCurrentVlanValues();
    existing.splice(n, 1);
    renderVlanRows(existing.length, existing);
}

/* =========================================================
   Dynamic Node Tile Rendering
   =========================================================*/

/** Default values for pre-filled tiles */
// NODE_DEFAULTS: empty — node tiles start blank until a config is loaded
const NODE_DEFAULTS = [];

/**
 * Build a single node tile <section> element for node index n (0-based).
 * Optionally pre-fill from provided values object.
 */
function buildNodeTile(n, values) {
    const vals = values || {};
    const label = `Node ${n + 1}`;

    const section = document.createElement('section');
    section.className = 'config-section node-tile';

    section.innerHTML = `
        <h2>Node ${n + 1} Configuration</h2>
        <div class="form-group">
            <label for="node${n}Hostname">Hostname <span class="required-mark">*</span></label>
            <input type="text" id="node${n}Hostname"
                   name="network.nodes.${n}.hostname"
                   value="${escHtml(vals.hostname || '')}"
                   placeholder="e.g. HOST0${n + 1}" required>
        </div>
        <div class="form-group">
            <label for="node${n}Serial">Serial Number <span class="required-mark">*</span></label>
            <input type="text" id="node${n}Serial"
                   name="network.nodes.${n}.serial"
                   value="${escHtml(vals.serial || '')}"
                   placeholder="e.g. CZ2D1Z0FXX" required>
        </div>
        <div class="form-group">
            <label for="node${n}Model">Model</label>
            <input type="text" id="node${n}Model"
                   name="network.nodes.${n}.model"
                   value="${escHtml(vals.model || '')}"
                   placeholder="e.g. HPE DL385 G11">
        </div>
        <div class="form-group">
            <label for="node${n}IloIp">iLO IP <span class="required-mark">*</span></label>
            <input type="text" id="node${n}IloIp"
                   name="network.nodes.${n}.iLO_ip"
                   value="${escHtml(vals.iLO_ip || '')}"
                   placeholder="e.g. 10.0.1.${100 + n}" required>
        </div>
        <div class="form-group">
            <label for="node${n}IloUsername">iLO Username <span class="required-mark">*</span></label>
            <input type="text" id="node${n}IloUsername"
                   name="network.nodes.${n}.iLO_username"
                   value="${escHtml(vals.iLO_username || 'administrator')}"
                   placeholder="administrator" required>
        </div>
        <div class="form-group">
            <label for="node${n}IloPassword">iLO Password <span class="required-mark">*</span></label>
            <div class="password-wrapper">
                <input type="password" id="node${n}IloPassword"
                       name="network.nodes.${n}.iLO_password"
                       value="${escHtml(vals.iLO_password || '')}"
                       placeholder="iLO password" required>
                <button type="button" class="password-toggle"
                        onclick="togglePasswordField('node${n}IloPassword', this)"
                        aria-label="Toggle password visibility"><span>👁️</span></button>
            </div>
        </div>
        <div class="form-group">
            <label for="node${n}HypervisorIp">Hypervisor IP <span class="required-mark">*</span></label>
            <input type="text" id="node${n}HypervisorIp"
                   name="network.nodes.${n}.hypervisor_ip"
                   value="${escHtml(vals.hypervisor_ip || '')}"
                   placeholder="e.g. 10.0.100.${131 + n * 2}" required>
        </div>
        <div class="form-group">
            <label for="node${n}CvmIp">CVM IP <span class="required-mark">*</span></label>
            <input type="text" id="node${n}CvmIp"
                   name="network.nodes.${n}.cvm_ip"
                   value="${escHtml(vals.cvm_ip || '')}"
                   placeholder="e.g. 10.0.100.${132 + n * 2}" required>
        </div>
    `;

    return section;
}

/** Escape HTML special chars for use in attribute values */
function escHtml(str) {
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/"/g, '&quot;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}

/**
 * Read current node field values from DOM into an array of objects
 * (so we can preserve user input when reshuffling tiles).
 */
function readCurrentNodeValues() {
    const values = [];
    const container = document.getElementById('nodeTilesContainer');
    if (!container) return values;

    container.querySelectorAll('.node-tile').forEach((tile, idx) => {
        values[idx] = {
            hostname:      (tile.querySelector(`[name="network.nodes.${idx}.hostname"]`)     || {}).value || '',
            serial:        (tile.querySelector(`[name="network.nodes.${idx}.serial"]`)        || {}).value || '',
            model:         (tile.querySelector(`[name="network.nodes.${idx}.model"]`)         || {}).value || '',
            iLO_ip:        (tile.querySelector(`[name="network.nodes.${idx}.iLO_ip"]`)        || {}).value || '',
            iLO_username:  (tile.querySelector(`[name="network.nodes.${idx}.iLO_username"]`)  || {}).value || '',
            iLO_password:  (tile.querySelector(`[name="network.nodes.${idx}.iLO_password"]`)  || {}).value || '',
            hypervisor_ip: (tile.querySelector(`[name="network.nodes.${idx}.hypervisor_ip"]`) || {}).value || '',
            cvm_ip:        (tile.querySelector(`[name="network.nodes.${idx}.cvm_ip"]`)        || {}).value || ''
        };
    });

    return values;
}

/**
 * Re-render the node tiles container for the given count.
 * Preserves existing user input. Falls back to NODE_DEFAULTS (empty) for new tiles.
 * @param {number} count
 * @param {Array}  [forcedValues] — if provided, use these values (used by populateForm)
 */
function renderNodeTiles(count, forcedValues) {
    const container = document.getElementById('nodeTilesContainer');
    if (!container) return;

    // Capture current values before clearing (unless caller provided forced values)
    const existing = forcedValues || readCurrentNodeValues();

    container.innerHTML = '';

    for (let n = 0; n < count; n++) {
        let vals = existing[n];
        if (!vals || (!vals.hostname && !vals.serial)) {
            vals = NODE_DEFAULTS[n] || {};
        }
        container.appendChild(buildNodeTile(n, vals));
    }

    // Sync the dropdown if it doesn't already show the right value
    const select = document.getElementById('nodeCount');
    if (select && parseInt(select.value) !== count) {
        select.value = String(count);
    }
}

/* =========================================================
   Authentication helpers
   ========================================================= */
async function logout() {
    try {
        await fetch('/api/logout', { method: 'POST' });
    } catch (_) {}
    window.location.href = '/login.html';
}

/* =========================================================
   WebSocket
   ========================================================= */
function initWebSocket() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(`${protocol}//${window.location.host}`);

    ws.onopen    = () => console.log('WebSocket connected');
    ws.onmessage = (e) => handleWebSocketMessage(JSON.parse(e.data));
    ws.onclose   = () => setTimeout(initWebSocket, 3000);
    ws.onerror   = (e) => console.error('WebSocket error:', e);
}

function handleWebSocketMessage(data) {
    switch (data.type) {
        case 'deployment_started':   handleDeploymentStarted(data);       break;
        case 'deployment_state':     handleDeploymentState(data);         break;
        case 'step_update':          updateStepStatus(data.step, data.status); break;
        case 'log':                  appendLog(data.message, data.level);  break;
        case 'deployment_completed': handleDeploymentCompleted(data);      break;
        case 'deployment_error':     handleDeploymentError(data);          break;
        case 'deployment_aborted':   handleDeploymentAborted(data);        break;
    }
}

/* =========================================================
   Deployment Steps UI
   ========================================================= */
function handleDeploymentStarted(data) {
    document.getElementById('deployConfigName').textContent    = data.filename;
    document.getElementById('deployOverallStatus').textContent = 'In Progress…';
    document.getElementById('deployOverallStatus').style.color = '#f59e0b';
    // Make sure the deployment section is visible
    document.getElementById('deploymentSection').style.display = 'block';
    document.getElementById('abortBtn').style.display = '';
}

// Restores full deployment UI when a client reconnects mid-deployment,
// or shows the last completed/failed run when re-logging in after it finished.
function handleDeploymentState(data) {
    const section = document.getElementById('deploymentSection');
    section.style.display = 'block';

    const status = data.status || 'running';  // legacy: no status field = running

    document.getElementById('deployConfigName').textContent = data.filename || '';

    // Show Abort button only while running
    document.getElementById('abortBtn').style.display = (status === 'running') ? '' : 'none';

    // ── Overall status label ─────────────────────────────────────────────────
    const statusEl = document.getElementById('deployOverallStatus');
    if (status === 'running') {
        statusEl.textContent = data.isDryRun ? 'Dry Run — In Progress…' : 'In Progress…';
        statusEl.style.color = '#f59e0b';
    } else if (status === 'completed') {
        statusEl.textContent = '✅ Completed Successfully';
        statusEl.style.color = '#10b981';
    } else if (status === 'failed') {
        statusEl.textContent = '❌ Failed';
        statusEl.style.color = '#ef4444';
    } else if (status === 'aborted') {
        statusEl.textContent = '⛔ Force Aborted';
        statusEl.style.color = '#ef4444';
    }

    // ── Historical-view banner (shown when viewing a finished run) ───────────
    const existingBanner = document.getElementById('deployHistoryBanner');
    if (existingBanner) existingBanner.remove();
    if (status !== 'running') {
        const banner = document.createElement('div');
        banner.id = 'deployHistoryBanner';
        banner.style.cssText = 'background:rgba(255,255,255,0.06);border:1px solid rgba(255,255,255,0.15);border-radius:6px;padding:10px 14px;margin-bottom:12px;font-size:0.82rem;opacity:0.85;';
        const endStr  = data.endTime   ? ` — finished ${new Date(data.endTime).toLocaleString()}`   : '';
        const durStr  = data.duration  ? ` (${Math.floor(data.duration / 60)}m ${data.duration % 60}s)` : '';
        const cluStr  = data.clusterName ? `<strong>${data.clusterName}</strong>` : data.filename || '';
        const stateLabel = status === 'aborted' ? '⛔ force-aborted' : (status === 'completed' ? '✅ completed' : '❌ failed');
        banner.innerHTML = `📋 Showing last deployment: ${cluStr} (${stateLabel})${endStr}${durStr}. Start a new deployment to clear this view.`;
        const logSection = document.querySelector('#deploymentSection .deployment-log');
        if (logSection) logSection.before(banner);
        else section.prepend(banner);
    }

    // ── Step tiles ───────────────────────────────────────────────────────────
    const stepsGrid = document.getElementById('deploymentSteps');
    if (stepsGrid) stepsGrid.style.display = data.isDryRun ? 'none' : '';

    if (!data.isDryRun) {
        Object.keys(stepOpenState).forEach(k => delete stepOpenState[k]);
        deploymentSteps.forEach(s => {
            s.status = (data.stepStatuses && data.stepStatuses[s.id]) || 'pending';
        });
        renderDeploymentSteps();
    }

    // ── Replay log ───────────────────────────────────────────────────────────
    const log = document.getElementById('deploymentLog');
    log.innerHTML = '';
    (data.logBuffer || []).forEach(entry => appendLog(entry.message, entry.level));
}

function updateStepStatus(stepId, status) {
    const step = deploymentSteps.find(s => s.id === stepId);
    if (step) { step.status = status; renderDeploymentSteps(); }
}

// Tracks which step tiles the user has manually toggled open/closed.
// key = step id, value = true (open) | false (closed) | undefined (auto)
const stepOpenState = {};

function toggleStep(stepId) {
    const box = document.getElementById(`step-box-${stepId}`);
    if (!box) return;
    const isOpen = box.classList.toggle('step-open');
    stepOpenState[stepId] = isOpen;
}

function renderDeploymentSteps() {
    const container = document.getElementById('deploymentSteps');

    const statusCfg = {
        pending:   { icon: '',   label: 'Pending',   cls: 'step-pending'   },
        running:   { icon: '⏳', label: 'In Progress', cls: 'step-running'   },
        completed: { icon: '✅', label: 'Completed',  cls: 'step-completed' },
        failed:    { icon: '❌', label: 'Failed',     cls: 'step-failed'    },
        skipped:   { icon: '⏭', label: 'Skipped',    cls: 'step-skipped'   },
    };

    deploymentSteps.forEach((step, index) => {
        let box = document.getElementById(`step-box-${step.id}`);
        if (!box) {
            box = document.createElement('div');
            box.id = `step-box-${step.id}`;
            container.appendChild(box);
        }

        const cfg = statusCfg[step.status] || statusCfg.pending;
        box.className = `step-tile ${cfg.cls}`;
        box.innerHTML = `
            <div class="step-tile-num">STEP ${index + 1}</div>
            <div class="step-tile-name">${step.title}</div>
            <div class="step-tile-status">${cfg.icon ? cfg.icon + ' ' : ''}${cfg.label}</div>
        `;
    });
}

function setStepDetail(stepId, html) {
    const step = deploymentSteps.find(s => s.id === stepId);
    if (step) { step.detail = html; renderDeploymentSteps(); }
}

function appendLog(message, level = 'info') {
    const log = document.getElementById('deploymentLog');
    const pre = document.createElement('pre');
    pre.style.cssText = 'margin:0;white-space:pre-wrap;word-break:break-all;';

    if (level === 'raw') {
        pre.innerHTML = colorizeOutput(message);
    } else {
        const colorMap = { error: '#f87171', warning: '#fde68a', success: '#4ade80', info: '#94a3b8' };
        const ts    = new Date().toLocaleTimeString();
        const color = colorMap[level] || colorMap.info;
        const safe  = message.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        pre.innerHTML = `<span style="color:${color}">[${ts}] ${safe}</span>`;
    }
    log.appendChild(pre);
    log.scrollTop = log.scrollHeight;
}

function handleDeploymentCompleted(data) {
    document.getElementById('abortBtn').style.display = 'none';
    const el = document.getElementById('deployOverallStatus');
    if (data.success) {
        el.textContent = '✅ Deployment Completed Successfully';
        el.style.color = '#10b981';
        appendLog('Deployment completed successfully!', 'success');
    } else {
        el.textContent = '❌ Deployment Failed';
        el.style.color = '#ef4444';
        appendLog(`Deployment failed with exit code: ${data.exitCode}`, 'error');
    }
}

function handleDeploymentError(data) {
    document.getElementById('abortBtn').style.display = 'none';
    const el = document.getElementById('deployOverallStatus');
    el.textContent = '❌ Deployment Error';
    el.style.color = '#ef4444';
    appendLog(`Error: ${data.error}`, 'error');
}

function handleDeploymentAborted(data) {
    document.getElementById('abortBtn').style.display = 'none';
    const el = document.getElementById('deployOverallStatus');
    el.textContent = '⛔ Deployment Force Aborted';
    el.style.color = '#ef4444';
    appendLog('⛔ Deployment Force Aborted', 'error');
}

/* =========================================================
   Required-fields validation
   ========================================================= */

/**
 * Checks all mandatory form sections.
 * Returns { errors[], firstEl, allEls[] }.
 * allEls contains every blank required element so they can all be highlighted.
 */
function validateRequiredSections() {
    const errors  = [];
    const allEls  = [];
    const tabIds  = new Set(); // tab panel IDs that contain at least one error
    let   firstEl = null;

    function chk(id, label, section) {
        const el = document.getElementById(id);
        if (!el) return;
        if (!el.value.trim()) {
            errors.push(`${label} (${section})`);
            allEls.push(el);
            if (!firstEl) firstEl = el;
            const panel = el.closest('.tab-panel');
            if (panel) tabIds.add(panel.id);
        }
    }

    // 1. Basic Configuration
    chk('clusterName',       'Cluster Name',          'Basic Configuration');
    chk('storageContainer',  'Storage Container Name', 'Basic Configuration');
    chk('timezone',          'Timezone',               'Basic Configuration');

    // 2. Management Network
    chk('mgmtSubnetName',  'Subnet Name',   'Management Network');
    chk('mgmtGateway',     'Gateway',        'Management Network');
    chk('mgmtPrefixLength','Prefix Length',  'Management Network');
    chk('clusterVip',      'Cluster VIP',       'Management Network');
    chk('dataServiceIp',  'Data Service IP',   'Management Network');
    chk('ipPoolStart',    'IP Pool Start',     'Management Network');
    chk('ipPoolEnd',      'IP Pool End',       'Management Network');

    // 3. Node Details — all required inputs inside node tiles
    document.querySelectorAll('#nodeTilesContainer input[required]').forEach(el => {
        if (!el.value.trim()) {
            const lbl  = el.closest('.form-group')?.querySelector('label')?.textContent.trim() || el.name;
            const tile = el.closest('.node-tile')?.querySelector('h2')?.textContent.trim()      || 'Node Details';
            errors.push(`${lbl} (${tile})`);
            allEls.push(el);
            if (!firstEl) firstEl = el;
            const panel = el.closest('.tab-panel');
            if (panel) tabIds.add(panel.id);
        }
    });

    // 4. DNS — at least DNS Server 1
    chk('dnsServer1', 'DNS Server 1', 'DNS');

    // 5. NTP — at least NTP Server 1
    chk('ntpServer1', 'NTP Server 1', 'NTP');

    // 6. AOS & AHV Selection
    chk('aosVersion',       'AOS Version',       'AOS & AHV Selection');
    chk('aosPackageUrl',    'AOS Package URL',    'AOS & AHV Selection');
    chk('hypervisorIsoUrl', 'Hypervisor ISO URL', 'AOS & AHV Selection');
    chk('phoenixIsoUrl',    'Phoenix ISO URL',    'AOS & AHV Selection');

    // 7. Production Network — at least one VLAN row with a subnet name
    const vlanInputs = Array.from(document.querySelectorAll('[name^="production_vlans."][name$=".subnet_name"]'));
    const hasVlan    = vlanInputs.some(el => el.value.trim());
    if (!hasVlan) {
        errors.push('At least one VLAN entry with a Subnet Name is required (Production Network)');
        if (vlanInputs[0]) {
            allEls.push(vlanInputs[0]);
            if (!firstEl) firstEl = vlanInputs[0];
            const panel = vlanInputs[0].closest('.tab-panel');
            if (panel) tabIds.add(panel.id);
        }
    }

    // 8. Hub Production Network
    chk('hubSubnetName',   'Subnet Name',   'Hub Production Network');
    chk('hubVlanId',       'VLAN ID',       'Hub Production Network');
    chk('hubGateway',      'Gateway',       'Hub Production Network');
    chk('hubPrefixLength', 'Prefix Length', 'Hub Production Network');
    chk('hubIpPoolStart',  'IP Pool Start', 'Hub Production Network');
    chk('hubIpPoolEnd',    'IP Pool End',   'Hub Production Network');

    // 9. Prism Central
    chk('pcIp',       'Prism Central IP',      'Prism Central');
    chk('pcUrl',      'Prism Central URL',      'Prism Central');
    chk('pcUsername', 'Prism Central Username', 'Prism Central');
    chk('pcPassword', 'Prism Central Password', 'Prism Central');

    // 10. EULA Details — marked required in the UI but were missing from validation
    chk('eulaUsername',    'Full Name',    'EULA Details');
    chk('eulaJobTitle',    'Job Title',    'EULA Details');
    chk('eulaCompanyName', 'Company Name', 'EULA Details');

    return { errors, firstEl, allEls, tabIds };
}

/* =========================================================
   Deployment Trigger
   ========================================================= */
document.getElementById('startDeploymentBtn').addEventListener('click', () => startDeployment(false));
document.getElementById('dryRunBtn').addEventListener('click',          () => startDeployment(true));
document.getElementById('abortBtn').addEventListener('click',           () => abortDeployment());
const addVlanBtn = document.getElementById('addVlanBtn');
if (addVlanBtn) {
    addVlanBtn.addEventListener('click', () => {
        const existing = readCurrentVlanValues();
        renderVlanRows(existing.length + 1, existing);
    });
}

async function abortDeployment() {
    if (!confirm('Are you sure you want to FORCE ABORT the running deployment?\n\nThis will kill the PowerShell process immediately. Any step currently running will be interrupted.')) return;
    try {
        const res = await fetch('/api/abort', { method: 'POST' });
        const result = await res.json();
        if (!res.ok) {
            appendLog(`Abort failed: ${result.error}`, 'error');
        }
        // UI update is handled by the deployment_aborted broadcast from server
    } catch (err) {
        appendLog(`Abort request failed: ${err.message}`, 'error');
    }
}

async function startDeployment(isDryRun = false) {
    // Clear any previous red highlights and tab error markers
    document.querySelectorAll('.field-error').forEach(el => el.classList.remove('field-error'));
    document.querySelectorAll('.tab-btn-main.tab-error').forEach(btn => btn.classList.remove('tab-error'));

    const { errors, firstEl, allEls, tabIds } = validateRequiredSections();
    if (errors.length > 0) {
        // Mark tabs that contain errors
        tabIds.forEach(tabId => {
            const btn = document.querySelector(`.tab-btn-main[data-tab-target="${tabId}"]`);
            if (btn) btn.classList.add('tab-error');
        });

        // Highlight every blank required field red
        allEls.forEach(el => {
            el.classList.add('field-error');
            // Remove red highlight (and recheck tab error state) as soon as the user types
            el.addEventListener('input', function clear() {
                el.classList.remove('field-error');
                el.removeEventListener('input', clear);
                // Re-evaluate tab-error state for the tab this field belongs to
                const panel = el.closest('.tab-panel');
                if (panel) {
                    const stillHasErrors = panel.querySelectorAll('.field-error').length > 0;
                    const btn = document.querySelector(`.tab-btn-main[data-tab-target="${panel.id}"]`);
                    if (btn && !stillHasErrors) btn.classList.remove('tab-error');
                }
                // Update banner count
                const remaining = document.querySelectorAll('.field-error').length;
                const banner = document.getElementById('validationBanner');
                if (banner) {
                    if (remaining === 0) {
                        banner.style.display = 'none';
                    } else {
                        banner.querySelector('.vb-count').textContent =
                            `${remaining} required field${remaining > 1 ? 's are' : ' is'} still empty — highlighted in red above.`;
                    }
                }
            });
        });

        // Show inline banner — no alert popup
        const banner = document.getElementById('validationBanner');
        if (banner) {
            banner.querySelector('.vb-count').textContent =
                `${errors.length} required field${errors.length > 1 ? 's are' : ' is'} empty — highlighted in red. Fill them in to continue.`;
            banner.style.display = '';
        }

        if (firstEl) {
            firstEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
            firstEl.focus();
        }
        return; // STOP — do not proceed
    }

    // All required fields filled — hide banner if it was showing
    const banner = document.getElementById('validationBanner');
    if (banner) banner.style.display = 'none';

    const clusterName = document.getElementById('clusterName').value.trim();

    const startAt   = parseInt(document.getElementById('startAtStepSelect')?.value || '1');
    const action    = isDryRun ? 'dry run' : 'deployment';
    const stepLabel = startAt > 1 ? ` from Step ${startAt}` : '';

    const skipSteps    = Array.from(document.querySelectorAll('.skip-step-cb:checked')).map(cb => parseInt(cb.value));
    const skipPreCheck = document.getElementById('skipPreCheckCb')?.checked || false;
    const skipLabel    = skipSteps.length > 0 ? `\n\nSkipping step(s): ${skipSteps.join(', ')}` : '';
    const preCheckNote = skipPreCheck ? '\n\n⚠ Pre-flight checks will be SKIPPED.' : '';

    let requestBody;
    let displayName;

    if (loadedConfigFile) {
        // Use the loaded config file directly — no date-stamped copy
        displayName = loadedConfigFile;
        if (!confirm(`Start ${action}${stepLabel} for cluster "${clusterName}"?\n\nUsing config: ${loadedConfigFile}${skipLabel}${preCheckNote}\n\nContinue?`)) return;
        requestBody = { configPath: loadedConfigFile, isDryRun, startAtStep: startAt, skipSteps, skipPreCheck };
    } else {
        // No loaded file — save from current form under the cluster name
        displayName = `${clusterName}.json`;
        if (!confirm(`Start ${action}${stepLabel} for cluster "${clusterName}"?\n\nConfig "${displayName}" will be saved.${skipLabel}${preCheckNote}\n\nContinue?`)) return;
        const config = buildConfigObject(new FormData(document.getElementById('configForm')));
        requestBody  = { config, filename: displayName, isDryRun, startAtStep: startAt, skipSteps, skipPreCheck };
    }

    try {
        const section = document.getElementById('deploymentSection');
        section.style.display = 'block';
        document.getElementById('deployConfigName').textContent    = displayName;
        document.getElementById('deployOverallStatus').textContent = isDryRun ? 'Dry Run — Validating…' : 'Initializing…';
        document.getElementById('deployOverallStatus').style.color = '#667eea';

        // Remove any historical-view banner from a previous run
        const oldBanner = document.getElementById('deployHistoryBanner');
        if (oldBanner) oldBanner.remove();

        // Hide step tiles for dry run — steps don't execute, only log output matters
        const stepsGrid = document.getElementById('deploymentSteps');
        if (stepsGrid) stepsGrid.style.display = isDryRun ? 'none' : '';

        deploymentSteps.forEach(s => { s.status = 'pending'; s.detail = null; });
        Object.keys(stepOpenState).forEach(k => delete stepOpenState[k]);
        if (!isDryRun) renderDeploymentSteps();
        document.getElementById('deploymentLog').innerHTML = '';
        appendLog(isDryRun ? 'Starting dry run validation…' : `Starting deployment from Step ${startAt}…`, 'info');
        document.getElementById('abortBtn').style.display = '';
        section.scrollIntoView({ behavior: 'smooth' });

        const response = await fetch('/api/deploy', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestBody)
        });

        const result = await response.json();
        if (response.ok) {
            appendLog(`Pipeline started — config: ${displayName}`, 'success');
            appendLog(isDryRun ? 'Dry run validation started…' : `Deployment started from Step ${startAt}…`, 'info');
        } else {
            appendLog(`Error: ${result.error}`, 'error');
            alert(`Failed to start ${action}: ${result.error}`);
        }
    } catch (err) {
        appendLog(`Error: ${err.message}`, 'error');
        alert(`Failed to start ${action}: ${err.message}`);
    }
}

/* =========================================================
   Terminal
   ========================================================= */

// ── Skip-steps dropdown helpers ───────────────────────────────────────────
function toggleSkipDd(id) {
    const dd = document.getElementById(id);
    const isOpen = dd.classList.contains('open');
    // Close all open dropdowns first
    document.querySelectorAll('.skip-dd.open').forEach(el => el.classList.remove('open'));
    if (!isOpen) dd.classList.add('open');
}

function updateSkipDdLabel(cbClass, labelId) {
    const checked = Array.from(document.querySelectorAll(`.${cbClass}:checked`));
    const labelEl = document.getElementById(labelId);
    const btn     = labelEl ? labelEl.closest('.skip-dd-btn') : null;
    if (checked.length === 0) {
        labelEl.textContent = 'None selected';
        if (btn) btn.classList.remove('active');
    } else {
        labelEl.textContent = `Skipping: ${checked.map(cb => cb.value).join(', ')}`;
        if (btn) btn.classList.add('active');
    }
}

function clearSkipDd(cbClass, labelId) {
    document.querySelectorAll(`.${cbClass}`).forEach(cb => cb.checked = false);
    updateSkipDdLabel(cbClass, labelId);
}

// Attach change listeners for live label update
document.querySelectorAll('.skip-step-cb').forEach(cb =>
    cb.addEventListener('change', () => updateSkipDdLabel('skip-step-cb', 'skipDdLabel')));
document.querySelectorAll('.resume-skip-step-cb').forEach(cb =>
    cb.addEventListener('change', () => updateSkipDdLabel('resume-skip-step-cb', 'resumeSkipDdLabel')));

// Close dropdown when clicking outside
document.addEventListener('click', (e) => {
    if (!e.target.closest('.skip-dd')) {
        document.querySelectorAll('.skip-dd.open').forEach(el => el.classList.remove('open'));
    }
});

async function runTerminalCommand() {
    const input   = document.getElementById('terminalInput');
    const command = (input.value || '').trim();
    if (!command) return;

    const output = document.getElementById('terminalOutput');
    const cmdEl  = document.createElement('div');
    cmdEl.className   = 'term-cmd';
    cmdEl.textContent = `PS Nutanix-ZTI> ${command}`;
    output.appendChild(cmdEl);
    input.value    = '';
    input.disabled = true;

    const spinEl = document.createElement('div');
    spinEl.className   = 'term-spin';
    spinEl.textContent = 'Running…';
    output.appendChild(spinEl);
    output.scrollTop = output.scrollHeight;

    try {
        const res    = await fetch('/api/terminal/run', {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ command })
        });
        const result = await res.json();
        spinEl.remove();

        const outEl = document.createElement('pre');
        outEl.className = 'term-out';
        const combined = (result.output || '') + (result.error ? '\nSTDERR:\n' + result.error : '');
        outEl.innerHTML = colorizeOutput(combined);
        output.appendChild(outEl);
    } catch (err) {
        spinEl.remove();
        const errEl = document.createElement('pre');
        errEl.className   = 'term-err';
        errEl.textContent = `Error: ${err.message}`;
        output.appendChild(errEl);
    } finally {
        input.disabled = false;
        input.focus();
        output.scrollTop = output.scrollHeight;
    }
}

document.addEventListener('DOMContentLoaded', () => {
    const input = document.getElementById('terminalInput');
    if (input) {
        input.addEventListener('keydown', e => { if (e.key === 'Enter') runTerminalCommand(); });
    }
});
window.addEventListener('load', async () => {
    // Auth check
    try {
        const res = await fetch('/api/current-user');
        if (!res.ok) { window.location.href = '/login.html'; return; }

        const user = await res.json();
        const el   = document.getElementById('currentUser');
        if (el) el.textContent = user.username;

        if (user.role === 'admin') {
            const btn = document.getElementById('adminBtn');
            if (btn) btn.style.display = 'inline-flex';
        }
    } catch (_) {
        window.location.href = '/login.html';
        return;
    }

    // Render default 2-node tiles
    renderNodeTiles(2);

    // Render default 1 VLAN row
    renderVlanRows(1);

    // Wire up node count dropdown
    document.getElementById('nodeCount').addEventListener('change', function () {
        renderNodeTiles(parseInt(this.value));
    });

    await loadConfigList();
    initWebSocket();

    // Populate the resume-panel config selector with the same list
    const resumeSel = document.getElementById('resumeConfigSelect');
    if (resumeSel) {
        const res  = await fetch('/api/configs');
        const data = await res.json();
        resumeSel.innerHTML = '<option value="">— Select config —</option>';
        (data.files || []).forEach(f => {
            const opt = document.createElement('option');
            opt.value = opt.textContent = f.name;
            resumeSel.appendChild(opt);
        });
    }
});

async function loadConfigList() {
    try {
        const res  = await fetch('/api/configs');
        const data = await res.json();
        const sel  = document.getElementById('configSelect');
        sel.innerHTML = '<option value="">— Select a saved configuration —</option>';
        (data.files || []).forEach(f => {
            const opt = document.createElement('option');
            opt.value = opt.textContent = f.name;
            sel.appendChild(opt);
        });
    } catch (e) {
        console.error('Error loading config list:', e);
    }
}

document.getElementById('loadConfigBtn').addEventListener('click', async () => {
    const filename = document.getElementById('configSelect').value;
    if (!filename) { alert('Please select a configuration file.'); return; }

    try {
        const res    = await fetch(`/api/config/${filename}`);
        const config = await res.json();
        if (res.ok) {
            populateForm(config);
            loadedConfigFile = filename;  // remember for deployment (no date-stamp)
            // Pre-select in the resume panel too
            const resumeSel = document.getElementById('resumeConfigSelect');
            if (resumeSel) resumeSel.value = filename;
            alert(`Configuration "${filename}" loaded successfully.`);
        } else {
            alert(`Error loading configuration: ${config.error}`);
        }
    } catch (e) {
        alert('Error loading configuration: ' + e.message);
    }
});

/* =========================================================
   Save Configuration
   ========================================================= */
document.getElementById('saveConfigBtn').addEventListener('click', async () => {
    const clusterName = document.getElementById('clusterName').value.trim();
    if (!clusterName) { alert('Please enter a Cluster Name before saving.'); return; }

    const filename = prompt('Filename (without .json):', clusterName);
    if (!filename) return;

    const config = buildConfigObject(new FormData(document.getElementById('configForm')));

    try {
        const body = JSON.stringify(config, null, 2);
        const res  = await fetch(`/api/config/${filename}.json`, {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body
        });

        const ct = res.headers.get('content-type') || '';
        if (!ct.includes('application/json')) {
            throw new Error('Server returned a non-JSON response. Check the server console for details.');
        }

        const result = await res.json();
        if (res.ok) {
            alert(`Configuration saved as ${filename}.json`);
            await loadConfigList();
        } else {
            alert(`Error saving configuration: ${result.error}`);
        }
    } catch (e) {
        console.error('Save error:', e);
        alert('Error saving configuration: ' + e.message);
    }
});

/* =========================================================
   buildConfigObject — form → nested JSON
   ========================================================= */
function buildConfigObject(formData) {
    const config = {
        "_comment": "Nutanix ZTI Deployment Configuration",
        "_note": "IPMI netmask and gateway are auto-detected from Foundation Central. You can override by specifying them here.",
        "_output_level_options": "minimal (only headers), normal (headers + important messages), verbose (all details)"
    };

    for (let [key, value] of formData.entries()) {
        const keys   = key.split('.');
        let current  = config;

        for (let i = 0; i < keys.length; i++) {
            const k          = keys[i];
            const isLast     = i === keys.length - 1;
            const nextKey    = !isLast ? keys[i + 1] : null;
            const nextIsNum  = nextKey !== null && !isNaN(parseInt(nextKey));

            if (isLast) {
                const el = document.querySelector(`[name="${key}"]`);
                if (el && el.type === 'checkbox') {
                    current[k] = el.checked;
                } else if (value !== '') {
                    current[k] = (el && el.type === 'number' && !isNaN(value)) ? Number(value) : value;
                }
            } else if (nextIsNum) {
                if (!current[k]) current[k] = [];
                const idx           = parseInt(nextKey);
                const remaining     = keys.slice(i + 2);

                if (remaining.length === 0) {
                    // Simple array (dns_servers.0)
                    const el = document.querySelector(`[name="${key}"]`);
                    if (el && el.type === 'checkbox') {
                        current[k][idx] = el.checked;
                    } else if (value !== '') {
                        current[k][idx] = (el && el.type === 'number' && !isNaN(value)) ? Number(value) : value;
                    }
                    break;
                } else {
                    // Nested object array (nodes.0.hostname)
                    if (!current[k][idx]) current[k][idx] = {};
                    current = current[k][idx];
                    i++;  // skip the numeric key in next iteration
                }
            } else {
                if (!current[k]) current[k] = {};
                current = current[k];
            }
        }
    }

    // Derive hostnames from nodes
    if (config.network && Array.isArray(config.network.nodes)) {
        config.network.hostnames = config.network.nodes.map(n => n.hostname).filter(Boolean);
    }

    // Derive legacy ip_prefix / gateway_last_octet / subnet_mask from the new
    // gateway + prefix_length fields so Image-And-Deploy-Cluster.ps1 stays compatible.
    if (config.network && config.network.gateway) {
        const gwParts = config.network.gateway.split('.');
        if (gwParts.length === 4) {
            config.network.ip_prefix         = gwParts.slice(0, 3).join('.');
            config.network.gateway_last_octet = gwParts[3];
        }
    }
    if (config.network && config.network.prefix_length) {
        const pl = parseInt(config.network.prefix_length);
        if (!isNaN(pl)) {
            // Convert prefix length to dotted-decimal subnet mask
            const mask = pl === 0 ? '0.0.0.0' : (0xFFFFFFFF << (32 - pl)) >>> 0;
            config.network.subnet_mask = [
                (mask >>> 24) & 0xFF,
                (mask >>> 16) & 0xFF,
                (mask >>>  8) & 0xFF,
                 mask         & 0xFF
            ].join('.');
        }
    }

    // Remove empty DNS / NTP entries
    ['dns_servers', 'ntp_servers'].forEach(arr => {
        if (Array.isArray(config[arr])) {
            config[arr] = config[arr].filter(v => v !== '' && v !== undefined);
        }
    });

    return config;
}

/* =========================================================
   Form Reset / Load from File
   ========================================================= */
document.getElementById('configForm').addEventListener('submit', (e) => {
    e.preventDefault();
    generateConfiguration();
});

document.getElementById('resetBtn').addEventListener('click', () => {
    document.getElementById('configForm').reset();
    renderNodeTiles(2);
    renderVlanRows(1);
    document.getElementById('nodeCount').value = '2';
    document.getElementById('output').style.display = 'none';
});

document.getElementById('loadBtn').addEventListener('click', () => {
    const input    = document.createElement('input');
    input.type     = 'file';
    input.accept   = '.json,.yaml,.yml';
    input.onchange = handleFileLoad;
    input.click();
});

/* =========================================================
   Copy / Download
   ========================================================= */
document.getElementById('copyBtn').addEventListener('click', () => {
    navigator.clipboard.writeText(document.getElementById('configOutput').textContent)
        .then(() => alert('Configuration copied to clipboard!'));
});

document.getElementById('downloadBtn').addEventListener('click', () => {
    const output    = document.getElementById('configOutput').textContent;
    const extension = currentFormat === 'env' ? '.env' : `.${currentFormat}`;
    const url       = URL.createObjectURL(new Blob([output], { type: 'text/plain' }));
    const a         = Object.assign(document.createElement('a'), { href: url, download: `cluster-config${extension}` });
    a.click();
    URL.revokeObjectURL(url);
});

/* =========================================================
   Output Tabs
   ========================================================= */
document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', function () {
        document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
        this.classList.add('active');
        currentFormat = this.dataset.tab;
        generateConfiguration();
    });
});

function generateConfiguration() {
    const config = buildConfigObject(new FormData(document.getElementById('configForm')));
    let output;
    if (currentFormat === 'yaml')       output = toYAML(config);
    else if (currentFormat === 'json')  output = JSON.stringify(config, null, 2);
    else                                output = toEnv(config);

    document.getElementById('configOutput').textContent = output;
    document.getElementById('output').style.display     = 'block';
    document.getElementById('output').scrollIntoView({ behavior: 'smooth' });
}

/* =========================================================
   Format Converters
   ========================================================= */
function toYAML(obj, indent = 0) {
    let yaml   = '';
    const pad  = '  '.repeat(indent);
    for (let key in obj) {
        const val = obj[key];
        if (val === null || val === undefined) continue;
        if (typeof val === 'object' && !Array.isArray(val)) {
            yaml += `${pad}${key}:\n${toYAML(val, indent + 1)}`;
        } else if (Array.isArray(val)) {
            yaml += `${pad}${key}:\n`;
            val.forEach(item => {
                if (typeof item === 'object') {
                    yaml += `${pad}  -\n${toYAML(item, indent + 2)}`;
                } else {
                    yaml += `${pad}  - ${item}\n`;
                }
            });
        } else {
            yaml += `${pad}${key}: ${val}\n`;
        }
    }
    return yaml;
}

function toEnv(obj, prefix = '') {
    let env = '';
    for (let key in obj) {
        const envKey = prefix ? `${prefix}_${key}` : key;
        const val    = obj[key];
        if (typeof val === 'object' && val !== null && !Array.isArray(val)) {
            env += toEnv(val, envKey.toUpperCase());
        } else {
            env += `${envKey.toUpperCase()}=${val}\n`;
        }
    }
    return env;
}

/* =========================================================
   File Load
   ========================================================= */
function handleFileLoad(event) {
    const file   = event.target.files[0];
    const reader = new FileReader();

    reader.onload = (e) => {
        try {
            let config;
            if (file.name.endsWith('.json')) {
                config = JSON.parse(e.target.result);
            } else {
                config = parseSimpleYAML(e.target.result);
            }
            populateForm(config);
        } catch (err) {
            alert('Error loading file: ' + err.message);
        }
    };
    reader.readAsText(file);
}

function parseSimpleYAML(yaml) {
    const config   = {};
    const lines    = yaml.split('\n');
    let current    = config;
    const stack    = [config];
    let lastIndent = 0;

    lines.forEach(line => {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#')) return;

        const indent = line.search(/\S/);
        const colon  = trimmed.indexOf(':');
        if (colon === -1) return;

        const key   = trimmed.slice(0, colon).trim();
        const value = trimmed.slice(colon + 1).trim();

        if (indent < lastIndent) {
            stack.pop();
            current = stack[stack.length - 1];
        }

        if (value) {
            current[key] = isNaN(value) ? value : Number(value);
        } else {
            current[key] = {};
            stack.push(current[key]);
            current = current[key];
        }
        lastIndent = indent;
    });

    return config;
}

/* =========================================================
   populateForm — fills all form fields from a config object
   Also re-renders node tiles to match the loaded node count.
   ========================================================= */
function populateForm(config, prefix = '') {
    for (let key in config) {
        if (key.startsWith('_')) continue;

        const value    = config[key];
        const fullPath = prefix ? `${prefix}.${key}` : key;

        if (Array.isArray(value)) {
            if (key === 'nodes') {
                // Resize node tiles first, then populate
                const nodeCount = value.length;
                renderNodeTiles(nodeCount, value.map(n => ({ ...n })));

                // Now populate each node's fields
                value.forEach((node, index) => {
                    populateForm(node, `${fullPath}.${index}`);
                });
            } else if (key === 'production_vlans') {
                // Resize VLAN rows first, values are set by render
                renderVlanRows(value.length, value.map(v => ({ ...v })));
            } else if (key === 'hostnames') {
                // Derived — skip
            } else {
                // Simple arrays: dns_servers, ntp_servers
                value.forEach((item, index) => {
                    const field = document.querySelector(`[name="${fullPath}.${index}"]`);
                    if (field) field.value = item;
                });
            }
        } else if (typeof value === 'object' && value !== null) {
            populateForm(value, fullPath);
        } else {
            const field = document.querySelector(`[name="${fullPath}"]`);
            if (field) {
                if (field.type === 'checkbox') {
                    field.checked = !!value;
                } else {
                    field.value = value;
                }
            }
        }
    }
}
