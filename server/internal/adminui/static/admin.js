// Asgard admin panel. Talks to /api/v1 with an "admin" device session that
// never receives message keys.
"use strict";
const $ = (s, el = document) => el.querySelector(s);
const api = async (method, path, body) => {
  const res = await fetch("/api/v1" + path, {
    method, headers: { "Content-Type": "application/json", Authorization: "Bearer " + token() },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 401) { signOut(); throw new Error("Session expired"); }
  if (res.status === 204) return null;
  const data = await res.json();
  if (!res.ok) throw new Error(data.error?.message || res.statusText);
  return data;
};
const token = () => { try { return sessionStorage.getItem("asgard-admin") || ""; } catch { return ""; } };
const setToken = (t) => { try { t ? sessionStorage.setItem("asgard-admin", t) : sessionStorage.removeItem("asgard-admin"); } catch {} };
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const bytes = (n) => { const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0; while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; } return `${n.toFixed(i ? 1 : 0)} ${u[i]}`; };
const date = (s) => s ? new Date(s).toLocaleString() : "—";

function dialog(text, confirm = false) {
  const d = $("#dialog");
  $("#dialog-text").textContent = text;
  const menu = $("menu", d);
  menu.innerHTML = confirm ? '<button value="cancel">Cancel</button><button value="ok" class="primary">Confirm</button>' : '<button value="ok" class="primary">OK</button>';
  d.showModal();
  return new Promise((resolve) => d.addEventListener("close", () => resolve(d.returnValue === "ok"), { once: true }));
}

function randomKey() { const b = new Uint8Array(32); crypto.getRandomValues(b); return btoa(String.fromCharCode(...b)); }

$("#login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = new FormData(e.target);
  $("#login-error").textContent = "";
  try {
    const res = await fetch("/api/v1/auth/login", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: f.get("username"), password: f.get("password"),
        // Admin sessions are excluded from message fan-out, so these keys are placeholders.
        device: { name: "Admin panel", platform: "admin", identity_key: randomKey(), signing_key: randomKey() } }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error?.message || "Sign in failed");
    if (!data.user.is_admin) throw new Error("This account is not an administrator.");
    setToken(data.token);
    start();
  } catch (err) { $("#login-error").textContent = err.message; }
});

async function signOut() {
  if (token()) { try { await fetch("/api/v1/auth/logout", { method: "POST", headers: { Authorization: "Bearer " + token() } }); } catch {} }
  setToken(null);
  $("#app").hidden = true; $("#login").hidden = false;
}
$("#logout").addEventListener("click", signOut);

$("#tabs").addEventListener("click", (e) => {
  const tab = e.target.dataset?.tab; if (!tab) return;
  document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("active", b.dataset.tab === tab));
  document.querySelectorAll(".tab").forEach((s) => (s.hidden = s.id !== tab));
  loaders[tab]?.();
});

const loaders = {
  async dashboard() {
    const s = await api("GET", "/admin/stats");
    const items = [["Users", s.users], ["Online now", s.online_users], ["Devices", s.devices], ["Conversations", s.conversations],
      ["Messages stored", s.messages], ["Active stories", s.active_stories], ["Media", bytes(s.media_bytes)], ["Database", bytes(s.database_bytes)],
      ["Push", s.push_enabled ? "On" : "Off"], ["Calls", s.calls_enabled ? "On" : "Off"], ["Bots", s.bots], ["Version", s.version]];
    $("#stats").innerHTML = items.map(([l, v]) => `<div class="card stat"><div class="value">${esc(v)}</div><div class="label">${esc(l)}</div></div>`).join("");
  },
  async users() {
    users = await api("GET", "/admin/users");
    renderUsers();
  },
  async invites() {
    const list = await api("GET", "/admin/invites");
    $("#invite-rows").innerHTML = list.map((i) => `<tr>
      <td><code>${esc(i.code)}</code>${i.make_admin ? ' <span class="pill admin">admin</span>' : ""}</td>
      <td>${esc(i.note)}</td><td>${i.uses} / ${i.max_uses}</td><td>${date(i.expires_at)}</td>
      <td class="actions"><button data-copy="${esc(i.url)}">Copy link</button> <button class="danger" data-del-invite="${esc(i.code)}">Revoke</button></td></tr>`).join("")
      || '<tr><td colspan="5" class="muted">No invites yet.</td></tr>';
  },
  async audit() {
    const list = await api("GET", "/admin/audit");
    $("#audit-rows").innerHTML = list.map((a) => `<tr><td>${date(a.at)}</td><td>${esc(a.actor || "system")}</td><td><code>${esc(a.action)}</code></td><td>${esc(a.target)}</td></tr>`).join("");
  },
  async settings() {
    const s = await api("GET", "/admin/settings");
    const f = $("#settings-form");
    for (const [k, v] of Object.entries(s)) {
      const input = f.elements[k]; if (!input) continue;
      input.type === "checkbox" ? (input.checked = !!v) : (input.value = v);
    }
    f.elements.default_quota_mb.value = Math.round((s.default_quota_bytes || 0) / 1048576);
  },
};

let users = [];
function renderUsers() {
  const q = $("#user-filter").value.toLowerCase();
  $("#user-rows").innerHTML = users.filter((u) => !q || u.username.includes(q) || u.display_name.toLowerCase().includes(q)).map((u) => `<tr>
    <td><strong>${esc(u.display_name)}</strong><br><span class="muted">@${esc(u.username)}</span></td>
    <td>${u.online ? '<span class="pill on">online</span>' : ""}${u.is_admin ? '<span class="pill admin">admin</span>' : ""}${u.is_bot ? '<span class="pill">bot</span>' : ""}${u.disabled ? '<span class="pill off">disabled</span>' : ""}</td>
    <td>${u.device_count}</td><td>${bytes(u.storage_used)}${u.storage_quota ? " / " + bytes(u.storage_quota) : ""}</td><td>${date(u.created_at)}</td>
    <td class="actions">
      ${u.is_bot ? "" : `<button data-act="admin" data-id="${u.id}">${u.is_admin ? "Remove admin" : "Make admin"}</button>
      <button data-act="reset" data-id="${u.id}">Reset password</button>`}
      <button data-act="disable" data-id="${u.id}">${u.disabled ? "Enable" : "Disable"}</button>
      <button data-act="delete" data-id="${u.id}" class="danger">Delete</button>
    </td></tr>`).join("");
}
$("#user-filter").addEventListener("input", renderUsers);
$("#user-rows").addEventListener("click", async (e) => {
  const b = e.target.closest("button[data-act]"); if (!b) return;
  const u = users.find((x) => x.id === b.dataset.id);
  try {
    if (b.dataset.act === "admin") await api("PATCH", `/admin/users/${u.id}`, { is_admin: !u.is_admin });
    if (b.dataset.act === "disable") await api("PATCH", `/admin/users/${u.id}`, { disabled: !u.disabled });
    if (b.dataset.act === "reset") {
      if (!(await dialog(`Reset the password for @${u.username}? They will be signed out of every device.`, true))) return;
      const r = await api("POST", `/admin/users/${u.id}/reset-password`);
      await dialog(`Temporary password for @${u.username}: ${r.temporary_password}`);
    }
    if (b.dataset.act === "delete") {
      if (!(await dialog(`Delete @${u.username} permanently? This removes their account, devices and memberships. It cannot be undone.`, true))) return;
      await api("DELETE", `/admin/users/${u.id}`);
    }
    loaders.users();
  } catch (err) { dialog(err.message); }
});

$("#invite-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target.elements;
  try {
    const inv = await api("POST", "/admin/invites", { note: f.note.value, max_uses: +f.max_uses.value, expires_hours: +f.expires_hours.value, make_admin: f.make_admin.checked });
    $("#new-invite").innerHTML = `<div class="invite-box">Code <code>${esc(inv.code)}</code> <span class="muted">${esc(inv.url)}</span> <button type="button" data-copy="${esc(inv.url)}">Copy link</button></div>`;
    loaders.invites();
  } catch (err) { dialog(err.message); }
});
document.addEventListener("click", async (e) => {
  const copy = e.target.closest("[data-copy]");
  if (copy) { try { await navigator.clipboard.writeText(copy.dataset.copy); copy.textContent = "Copied"; } catch { dialog(copy.dataset.copy); } }
  const del = e.target.closest("[data-del-invite]");
  if (del && (await dialog(`Revoke invite ${del.dataset.delInvite}?`, true))) { await api("DELETE", `/admin/invites/${del.dataset.delInvite}`); loaders.invites(); }
});

$("#settings-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target.elements;
  const body = {};
  for (const el of f) {
    if (!el.name || el.name === "default_quota_mb") continue;
    body[el.name] = el.type === "checkbox" ? el.checked : el.type === "number" ? +el.value : el.value;
  }
  body.default_quota_bytes = (+f.default_quota_mb.value || 0) * 1048576;
  try { const s = await api("PUT", "/admin/settings", body); $("#server-name").textContent = s.server_name; $("#settings-saved").textContent = "Saved."; }
  catch (err) { dialog(err.message); }
});

async function start() {
  if (!token()) { $("#login").hidden = false; return; }
  try {
    const meUser = await api("GET", "/me");
    if (!meUser.is_admin) return signOut();
    const info = await (await fetch("/api/v1/info")).json();
    $("#server-name").textContent = info.name;
    $("#login").hidden = true; $("#app").hidden = false;
    loaders.dashboard();
  } catch { $("#login").hidden = false; }
}
start();
