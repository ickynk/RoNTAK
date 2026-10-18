// RoNTAK ATAK interface.
(function () {
  "use strict";

  const POLL_MS = 250;
  const DOOR_HIT_PX = 20;
  const DOOR_ROOM_LINK_UNITS = 120;

  const TEAM_COLORS = { red: "#e53935", blue: "#1e88e5", gold: "#f9a825", unknown: "#9e9e9e" };
  const TEAM_LABEL = { red: "RED", blue: "BLUE", gold: "GOLD" };

  const OPTION_CHOICES = {
    breach: [["kick", "Kick"], ["shotgun", "Shotgun"], ["c2", "C2"], ["ram", "Ram"], ["leader", "Leader"], ["open", "Open"]],
    grenade: [["none", "None"], ["flashbang", "Flash"], ["stinger", "Stinger"], ["cs", "CS Gas"]],
    side: [["auto", "Auto"], ["split", "Split"], ["left", "Left"], ["right", "Right"]],
  };
  const OPTION_LABEL = { breach: "Breach", grenade: "Grenade", side: "Stack" };

  // needs: "door" (door or room target), "location" (any target), null (team-wide)
  const ACTIONS = [
    { id: "stack_up", label: "Stack Up", needs: "door", options: ["side"] },
    { id: "breach_clear", label: "Breach & Clear", needs: "door", options: ["breach", "grenade"] },
    { id: "open_clear", label: "Open & Clear", needs: "door", options: ["grenade"] },
    { id: "scan_door", label: "Mirror Door", needs: "door", options: [] },
    { id: "wedge_door", label: "Wedge Door", needs: "door", options: [] },
    { id: "move_to", label: "Move To", needs: "location", options: [] },
    { id: "fall_in", label: "Fall In", needs: null, options: [] },
    { id: "hold", label: "Hold", needs: null, options: [] },
    { id: "search_secure", label: "Search & Secure", needs: null, options: [] },
  ];
  const ACTION_BY_ID = Object.fromEntries(ACTIONS.map((a) => [a.id, a]));

  const $ = (id) => document.getElementById(id);
  const canvas = $("map");
  const ctx = canvas.getContext("2d");

  const app = {
    state: null,
    level: null,
    map: { floors: [], rooms: [] },
    images: {},
    floorIndex: 0,
    autoFloor: true,
    view: { zoom: 1, panX: 0, panY: 0, fitted: false },
    mode: "orders", // orders | calibrate | rooms
    team: "red",
    target: null, // {type: "door"|"room"|"location", ...}
    action: null,
    options: { breach: "kick", grenade: "flashbang", side: "auto" },
    sent: [],
    draft: [],
    dirty: true,
  };

  // ---------------------------------------------------------------- helpers

  function floor() {
    return app.map.floors[app.floorIndex] || null;
  }

  function transform() {
    const f = floor();
    return Geo.fit(f && f.anchors);
  }

  function worldToScreen(x, y) {
    const [u, v] = Geo.apply(transform(), x, y);
    return [u * app.view.zoom + app.view.panX, v * app.view.zoom + app.view.panY];
  }

  function screenToPx(sx, sy) {
    return [(sx - app.view.panX) / app.view.zoom, (sy - app.view.panY) / app.view.zoom];
  }

  function screenToWorld(sx, sy) {
    const [u, v] = screenToPx(sx, sy);
    return Geo.apply(Geo.invert(transform()), u, v);
  }

  function onFloor(z, f) {
    if (!f || z === undefined || z === null) return true;
    return z >= f.zMin && z < f.zMax;
  }

  function floorForZ(z) {
    const i = app.map.floors.findIndex((f) => onFloor(z, f));
    return i < 0 ? app.floorIndex : i;
  }

  function doorById(id) {
    return (app.state && app.state.doors || []).find((d) => d.id === id) || null;
  }

  function roomsOnFloor() {
    const f = floor();
    return app.map.rooms.filter((r) => !f || !r.floor || r.floor === f.name);
  }

  function doorLabel(id) {
    const room = app.map.rooms.find((r) => (r.doors || []).includes(id));
    const door = doorById(id);
    const base = room ? `${room.name} door` : `Door ${id.replace(/^.*_/, "#")}`;
    return door && door.locked ? `${base} (locked)` : base;
  }

  function teamMembers(team) {
    const officers = (app.state && app.state.officers) || [];
    return officers.filter((o) => team === "gold" || o.team === team);
  }

  function setHint(text) {
    $("hint").textContent = text || "";
  }

  function redraw() {
    app.dirty = true;
  }

  async function api(method, url, body, isRaw) {
    const res = await fetch(url, {
      method,
      headers: isRaw ? {} : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : isRaw ? body : JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || res.statusText);
    return data;
  }

  // ---------------------------------------------------------------- map data

  async function loadMap(level) {
    app.map = { floors: [], rooms: [] };
    app.images = {};
    app.view.fitted = false;
    try {
      const data = await api("GET", `/api/maps/${encodeURIComponent(level)}`);
      app.map = { floors: data.floors || [], rooms: data.rooms || [] };
    } catch (e) {
      console.warn("map load failed", e);
    }
    app.floorIndex = 0;
    app.map.floors.forEach(loadImage);
    renderFloorSelect();
    renderCalibration();
    renderRooms();
    redraw();
  }

  function loadImage(f) {
    if (!f.image || app.images[f.image]) return;
    const img = new Image();
    img.onload = () => {
      if (!app.view.fitted) fitView();
      redraw();
    };
    img.src = `/maps/${encodeURIComponent(app.level)}/${encodeURIComponent(f.image)}?v=${Date.now()}`;
    app.images[f.image] = img;
  }

  async function saveMap() {
    if (!app.level) return alert("No level loaded yet. Start a mission first.");
    await api("PUT", `/api/maps/${encodeURIComponent(app.level)}`, { level: app.level, ...app.map });
    setHint("Map saved.");
  }

  // ---------------------------------------------------------------- view

  function resizeCanvas() {
    const r = canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(r.width * dpr);
    canvas.height = Math.round(r.height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    redraw();
  }

  function fitView() {
    const r = canvas.getBoundingClientRect();
    if (!r.width) return;
    const f = floor();
    const img = f && app.images[f.image];
    let box;
    if (img && img.complete && img.naturalWidth) {
      box = [0, 0, img.naturalWidth, img.naturalHeight];
    } else if (img) {
      return; // fit once the floor plan has loaded
    } else {
      const pts = [];
      const s = app.state || {};
      if (s.player && s.player.pos) pts.push(s.player.pos);
      (s.officers || []).forEach((o) => pts.push(o.pos));
      (s.doors || []).forEach((d) => pts.push(d.pos));
      if (!pts.length) return;
      const t = transform();
      const px = pts.map((p) => Geo.apply(t, p.x, p.y));
      const us = px.map((p) => p[0]), vs = px.map((p) => p[1]);
      box = [Math.min(...us) - 100, Math.min(...vs) - 100, Math.max(...us) + 100, Math.max(...vs) + 100];
    }
    const [u0, v0, u1, v1] = box;
    const zoom = Math.min(r.width / (u1 - u0), r.height / (v1 - v0)) * 0.92;
    app.view.zoom = zoom;
    app.view.panX = (r.width - (u1 - u0) * zoom) / 2 - u0 * zoom;
    app.view.panY = (r.height - (v1 - v0) * zoom) / 2 - v0 * zoom;
    app.view.fitted = true;
    redraw();
  }

  function centerOnPlayer() {
    const p = app.state && app.state.player && app.state.player.pos;
    if (!p) return fitView();
    const r = canvas.getBoundingClientRect();
    const [sx, sy] = worldToScreen(p.x, p.y);
    app.view.panX += r.width / 2 - sx;
    app.view.panY += r.height / 2 - sy;
    redraw();
  }

  function zoomAt(sx, sy, factor) {
    const z = Math.min(20, Math.max(0.05, app.view.zoom * factor));
    const k = z / app.view.zoom;
    app.view.panX = sx - (sx - app.view.panX) * k;
    app.view.panY = sy - (sy - app.view.panY) * k;
    app.view.zoom = z;
    redraw();
  }

  // ---------------------------------------------------------------- drawing

  function draw() {
    const r = canvas.getBoundingClientRect();
    ctx.clearRect(0, 0, r.width, r.height);
    ctx.fillStyle = "#101316";
    ctx.fillRect(0, 0, r.width, r.height);

    const f = floor();
    const img = f && app.images[f.image];
    if (img && img.complete && img.naturalWidth) {
      ctx.drawImage(img, app.view.panX, app.view.panY, img.naturalWidth * app.view.zoom, img.naturalHeight * app.view.zoom);
    } else {
      drawGrid(r);
    }

    drawRooms();
    drawDoors();
    drawOfficers();
    drawPlayer();
    drawTargetLocation();
    if (app.mode === "calibrate") drawAnchors();
    if (app.mode === "rooms") drawDraft();
  }

  function drawGrid(r) {
    // 10 m grid in world space.
    const inv = Geo.invert(transform());
    const corners = [[0, 0], [r.width, 0], [0, r.height], [r.width, r.height]].map(([sx, sy]) => {
      const [u, v] = screenToPx(sx, sy);
      return Geo.apply(inv, u, v);
    });
    const xs = corners.map((c) => c[0]), ys = corners.map((c) => c[1]);
    const step = 1000;
    ctx.strokeStyle = "#1f262c";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = Math.floor(Math.min(...xs) / step) * step; x <= Math.max(...xs); x += step) {
      const [ax, ay] = worldToScreen(x, Math.min(...ys)), [bx, by] = worldToScreen(x, Math.max(...ys));
      ctx.moveTo(ax, ay); ctx.lineTo(bx, by);
    }
    for (let y = Math.floor(Math.min(...ys) / step) * step; y <= Math.max(...ys); y += step) {
      const [ax, ay] = worldToScreen(Math.min(...xs), y), [bx, by] = worldToScreen(Math.max(...xs), y);
      ctx.moveTo(ax, ay); ctx.lineTo(bx, by);
    }
    ctx.stroke();
  }

  function polygonPath(poly) {
    ctx.beginPath();
    poly.forEach(([x, y], i) => {
      const [sx, sy] = worldToScreen(x, y);
      if (i === 0) ctx.moveTo(sx, sy); else ctx.lineTo(sx, sy);
    });
    ctx.closePath();
  }

  function drawRooms() {
    const selected = app.target && app.target.type === "room" ? app.target.room : null;
    for (const room of roomsOnFloor()) {
      polygonPath(room.polygon);
      const isSel = room.name === selected;
      ctx.fillStyle = isSel ? "rgba(0, 188, 212, 0.22)" : "rgba(0, 188, 212, 0.05)";
      ctx.fill();
      ctx.strokeStyle = isSel ? "#00bcd4" : "rgba(0, 188, 212, 0.35)";
      ctx.lineWidth = isSel ? 2.5 : 1;
      ctx.stroke();
      const f = floor();
      if (isSel || !(f && f.image)) {
        const [cx, cy] = Geo.centroid(room.polygon);
        const [sx, sy] = worldToScreen(cx, cy);
        ctx.fillStyle = isSel ? "#00bcd4" : "rgba(230, 233, 236, 0.75)";
        ctx.font = "600 12px system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.fillText(room.name, sx, sy);
      }
    }
  }

  function drawDoors() {
    const f = floor();
    const selectedId = app.target && app.target.door;
    for (const d of (app.state && app.state.doors) || []) {
      if (!onFloor(d.pos.z, f)) continue;
      const [sx, sy] = worldToScreen(d.pos.x, d.pos.y);
      const rad = ((d.yaw || 0) * Math.PI) / 180;
      const [ex, ey] = worldToScreen(d.pos.x + Math.cos(rad) * 45, d.pos.y + Math.sin(rad) * 45);
      const [bx, by] = worldToScreen(d.pos.x - Math.cos(rad) * 45, d.pos.y - Math.sin(rad) * 45);
      const sel = d.id === selectedId;
      ctx.lineCap = "round";
      ctx.strokeStyle = sel ? "#00bcd4" : d.locked ? "#ff7043" : "#ffd54f";
      ctx.lineWidth = sel ? 7 : 5;
      ctx.beginPath();
      ctx.moveTo(bx, by);
      ctx.lineTo(ex, ey);
      ctx.stroke();
      if (sel) {
        ctx.beginPath();
        ctx.arc(sx, sy, 14, 0, Math.PI * 2);
        ctx.strokeStyle = "#00bcd4";
        ctx.lineWidth = 2;
        ctx.stroke();
      }
    }
  }

  function headingTip(pos, yaw, len) {
    const rad = ((yaw || 0) * Math.PI) / 180;
    return worldToScreen(pos.x + Math.cos(rad) * len, pos.y + Math.sin(rad) * len);
  }

  function drawOfficers() {
    const f = floor();
    const highlighted = new Set(teamMembers(app.team).map((o) => o.id));
    for (const o of (app.state && app.state.officers) || []) {
      const [sx, sy] = worldToScreen(o.pos.x, o.pos.y);
      const [hx, hy] = headingTip(o.pos, o.yaw, 70);
      ctx.globalAlpha = onFloor(o.pos.z, f) ? 1 : 0.3;
      const color = TEAM_COLORS[o.team] || TEAM_COLORS.unknown;

      // Heading wedge
      const ang = Math.atan2(hy - sy, hx - sx);
      ctx.fillStyle = color;
      ctx.beginPath();
      ctx.moveTo(sx + Math.cos(ang) * 16, sy + Math.sin(ang) * 16);
      ctx.lineTo(sx + Math.cos(ang + 2.5) * 9, sy + Math.sin(ang + 2.5) * 9);
      ctx.lineTo(sx + Math.cos(ang - 2.5) * 9, sy + Math.sin(ang - 2.5) * 9);
      ctx.closePath();
      ctx.fill();

      ctx.beginPath();
      ctx.arc(sx, sy, 8, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.lineWidth = highlighted.has(o.id) ? 3 : 1.5;
      ctx.strokeStyle = highlighted.has(o.id) ? "#ffffff" : "#101316";
      ctx.stroke();

      ctx.font = "600 11px system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.lineWidth = 3;
      ctx.strokeStyle = "rgba(16, 19, 22, 0.85)";
      ctx.strokeText(o.name, sx + 12, sy - 8);
      ctx.fillStyle = "#e6e9ec";
      ctx.fillText(o.name, sx + 12, sy - 8);
      ctx.globalAlpha = 1;
    }
  }

  function drawPlayer() {
    const p = app.state && app.state.player;
    if (!p || !p.pos) return;
    const [sx, sy] = worldToScreen(p.pos.x, p.pos.y);
    const [hx, hy] = headingTip(p.pos, p.yaw, 70);
    const ang = Math.atan2(hy - sy, hx - sx);
    // ATAK-style self marker: cyan arrowhead.
    ctx.fillStyle = "#00e5ff";
    ctx.strokeStyle = "#062327";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(sx + Math.cos(ang) * 16, sy + Math.sin(ang) * 16);
    ctx.lineTo(sx + Math.cos(ang + 2.4) * 12, sy + Math.sin(ang + 2.4) * 12);
    ctx.lineTo(sx + Math.cos(ang + Math.PI) * 5, sy + Math.sin(ang + Math.PI) * 5);
    ctx.lineTo(sx + Math.cos(ang - 2.4) * 12, sy + Math.sin(ang - 2.4) * 12);
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
  }

  function drawTargetLocation() {
    if (!app.target || app.target.type !== "location") return;
    const { x, y } = app.target.location;
    const [sx, sy] = worldToScreen(x, y);
    ctx.strokeStyle = "#00bcd4";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(sx, sy, 12, 0, Math.PI * 2);
    ctx.moveTo(sx - 18, sy); ctx.lineTo(sx + 18, sy);
    ctx.moveTo(sx, sy - 18); ctx.lineTo(sx, sy + 18);
    ctx.stroke();
  }

  function drawAnchors() {
    const f = floor();
    if (!f) return;
    (f.anchors || []).forEach((a, i) => {
      const sx = a.px[0] * app.view.zoom + app.view.panX;
      const sy = a.px[1] * app.view.zoom + app.view.panY;
      ctx.strokeStyle = "#ff4081";
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(sx - 12, sy); ctx.lineTo(sx + 12, sy);
      ctx.moveTo(sx, sy - 12); ctx.lineTo(sx, sy + 12);
      ctx.stroke();
      ctx.fillStyle = "#ff4081";
      ctx.font = "700 12px system-ui, sans-serif";
      ctx.fillText(String(i + 1), sx + 8, sy - 8);
    });
  }

  function drawDraft() {
    if (!app.draft.length) return;
    ctx.strokeStyle = "#ff4081";
    ctx.fillStyle = "rgba(255, 64, 129, 0.15)";
    ctx.lineWidth = 2;
    polygonPath(app.draft);
    if (app.draft.length > 2) ctx.fill();
    ctx.stroke();
    for (const [x, y] of app.draft) {
      const [sx, sy] = worldToScreen(x, y);
      ctx.fillStyle = "#ff4081";
      ctx.fillRect(sx - 4, sy - 4, 8, 8);
    }
  }

  function frame() {
    if (app.dirty) {
      app.dirty = false;
      draw();
    }
    requestAnimationFrame(frame);
  }

  // ---------------------------------------------------------------- input

  const pointers = new Map();
  let gesture = null;

  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
    gesture = { moved: false, startX: e.offsetX, startY: e.offsetY, pinch: pointers.size === 2 ? pinchInfo() : null };
  });

  canvas.addEventListener("pointermove", (e) => {
    const prev = pointers.get(e.pointerId);
    if (!prev || !gesture) return;
    pointers.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
    if (Math.hypot(e.offsetX - gesture.startX, e.offsetY - gesture.startY) > 6) gesture.moved = true;
    if (pointers.size === 2 && gesture.pinch) {
      const now = pinchInfo();
      zoomAt(now.cx, now.cy, now.dist / gesture.pinch.dist);
      app.view.panX += now.cx - gesture.pinch.cx;
      app.view.panY += now.cy - gesture.pinch.cy;
      gesture.pinch = now;
    } else if (pointers.size === 1 && gesture.moved) {
      app.view.panX += e.offsetX - prev.x;
      app.view.panY += e.offsetY - prev.y;
      redraw();
    }
  });

  function endPointer(e) {
    const wasTap = gesture && !gesture.moved && pointers.size === 1;
    pointers.delete(e.pointerId);
    if (wasTap && e.type === "pointerup") onTap(e.offsetX, e.offsetY);
    if (!pointers.size) gesture = null;
  }
  canvas.addEventListener("pointerup", endPointer);
  canvas.addEventListener("pointercancel", endPointer);

  function pinchInfo() {
    const [a, b] = [...pointers.values()];
    return { cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2, dist: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)) };
  }

  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    zoomAt(e.offsetX, e.offsetY, e.deltaY < 0 ? 1.15 : 1 / 1.15);
  }, { passive: false });

  function onTap(sx, sy) {
    if (app.mode === "calibrate") return addAnchor(sx, sy);
    if (app.mode === "rooms") {
      app.draft.push(screenToWorld(sx, sy));
      return redraw();
    }
    selectAt(sx, sy);
  }

  function selectAt(sx, sy) {
    const f = floor();
    let best = null, bestD = DOOR_HIT_PX;
    for (const d of (app.state && app.state.doors) || []) {
      if (!onFloor(d.pos.z, f)) continue;
      const [dx, dy] = worldToScreen(d.pos.x, d.pos.y);
      const dist = Math.hypot(dx - sx, dy - sy);
      if (dist < bestD) { best = d; bestD = dist; }
    }
    const [wx, wy] = screenToWorld(sx, sy);
    if (best) {
      const room = app.map.rooms.find((r) => (r.doors || []).includes(best.id));
      app.target = { type: "door", door: best.id, room: room && room.name };
    } else {
      const room = roomsOnFloor().find((r) => Geo.pointInPolygon(wx, wy, r.polygon));
      if (room) {
        app.target = { type: "room", room: room.name, door: bestDoorForRoom(room) };
      } else {
        const z = app.state && app.state.player && app.state.player.pos ? app.state.player.pos.z : 0;
        app.target = { type: "location", location: { x: wx, y: wy, z } };
      }
    }
    if (app.action && !actionAllowed(ACTION_BY_ID[app.action])) app.action = null;
    if (!app.action) app.action = defaultAction();
    renderOrders();
    redraw();
  }

  // The room door closest to the selected team (the side they would breach from).
  function bestDoorForRoom(room) {
    const ids = (room.doors || []).filter((id) => doorById(id));
    if (!ids.length) return null;
    const members = teamMembers(app.team);
    if (!members.length) return ids[0];
    const cx = members.reduce((s, o) => s + o.pos.x, 0) / members.length;
    const cy = members.reduce((s, o) => s + o.pos.y, 0) / members.length;
    return ids.reduce((a, b) => {
      const da = doorById(a).pos, db = doorById(b).pos;
      return Math.hypot(da.x - cx, da.y - cy) <= Math.hypot(db.x - cx, db.y - cy) ? a : b;
    });
  }

  function defaultAction() {
    if (!app.target) return null;
    if (app.target.type === "location") return "move_to";
    return app.target.door ? "stack_up" : "move_to";
  }

  // ---------------------------------------------------------------- orders

  function actionAllowed(action) {
    if (!action.needs) return true;
    if (!app.target) return false;
    if (action.needs === "door") return Boolean(app.target.door);
    return true;
  }

  function targetLocation() {
    const t = app.target;
    if (!t) return null;
    if (t.type === "location") return t.location;
    if (t.type === "room") {
      const room = app.map.rooms.find((r) => r.name === t.room);
      if (room) {
        const [x, y] = Geo.centroid(room.polygon);
        const door = doorById(t.door);
        return { x, y, z: door ? door.pos.z : 0 };
      }
    }
    const door = doorById(t.door);
    return door ? door.pos : null;
  }

  function describeTarget() {
    const t = app.target;
    if (!t) return "Tap a door, room or spot on the map";
    if (t.type === "location") return `Map point (${Math.round(t.location.x)}, ${Math.round(t.location.y)})`;
    if (t.type === "room") return t.door ? `${t.room} — via ${doorLabel(t.door)}` : `${t.room} (no linked door)`;
    return doorLabel(t.door);
  }

  function describeOrder(o) {
    const a = ACTION_BY_ID[o.action];
    const opts = (a.options || []).map((k) => (OPTION_CHOICES[k].find((c) => c[0] === o.options[k]) || [, ""])[1]).filter(Boolean);
    return `${a.label}${opts.length ? " (" + opts.join(", ") + ")" : ""}`;
  }

  async function execute() {
    const action = ACTION_BY_ID[app.action];
    if (!action || !actionAllowed(action)) return;
    const target = {};
    if (app.target && app.target.door) target.door = app.target.door;
    if (app.target && app.target.room) target.room = app.target.room;
    const loc = targetLocation();
    if (loc) target.location = { x: loc.x, y: loc.y, z: loc.z || 0 };
    const options = {};
    for (const k of action.options) options[k] = app.options[k];

    const order = { team: app.team, action: action.id, target, options };
    try {
      const sent = await api("POST", "/api/command", order);
      app.sent.unshift({ ...order, id: sent.id, where: app.target ? describeTarget() : "" });
      app.sent.length = Math.min(app.sent.length, 30);
      renderTasks();
    } catch (e) {
      alert("Could not send order: " + e.message);
    }
  }

  // ---------------------------------------------------------------- panels

  function renderOrders() {
    $("target-text").textContent = describeTarget();

    const choice = $("door-choice");
    choice.innerHTML = "";
    if (app.target && app.target.type === "room") {
      const room = app.map.rooms.find((r) => r.name === app.target.room);
      const ids = ((room && room.doors) || []).filter((id) => doorById(id));
      if (ids.length > 1) {
        ids.forEach((id, i) => {
          const b = document.createElement("button");
          b.textContent = `Entry ${i + 1}`;
          b.className = id === app.target.door ? "active" : "";
          b.onclick = () => { app.target.door = id; renderOrders(); redraw(); };
          choice.appendChild(b);
        });
      }
    }

    const configured = new Set((app.state && app.state.configured_actions) || []);
    const actions = $("actions");
    actions.innerHTML = "";
    for (const a of ACTIONS) {
      const b = document.createElement("button");
      b.textContent = a.label;
      b.disabled = !actionAllowed(a);
      b.className = a.id === app.action ? "active" : "";
      if (app.state && app.state.connected && !configured.has(a.id)) {
        const tag = document.createElement("span");
        tag.className = "tag";
        tag.textContent = "not set up in config.lua";
        b.appendChild(tag);
      }
      b.onclick = () => { app.action = a.id; renderOrders(); };
      actions.appendChild(b);
    }

    const opts = $("options");
    opts.innerHTML = "";
    const action = ACTION_BY_ID[app.action];
    for (const key of (action && action.options) || []) {
      const wrap = document.createElement("div");
      wrap.className = "opt";
      wrap.innerHTML = `<div class="label">${OPTION_LABEL[key]}</div>`;
      const chips = document.createElement("div");
      chips.className = "chips";
      for (const [value, label] of OPTION_CHOICES[key]) {
        const b = document.createElement("button");
        b.textContent = label;
        b.className = app.options[key] === value ? "active" : "";
        b.onclick = () => { app.options[key] = value; renderOrders(); };
        chips.appendChild(b);
      }
      wrap.appendChild(chips);
      opts.appendChild(wrap);
    }

    const exec = $("execute");
    exec.disabled = !action || !actionAllowed(action);
    exec.textContent = action ? `${TEAM_LABEL[app.team]} — ${action.label.toUpperCase()}` : "SELECT AN ORDER";
  }

  function renderRoster() {
    const list = $("roster");
    list.innerHTML = "";
    const officers = (app.state && app.state.officers) || [];
    if (!officers.length) {
      list.innerHTML = '<li class="muted">No officers found</li>';
      return;
    }
    for (const o of officers) {
      const li = document.createElement("li");
      const hp = typeof o.health === "number" ? `${Math.round(o.health)}%` : "";
      li.innerHTML = `<span class="swatch" style="background:${TEAM_COLORS[o.team] || TEAM_COLORS.unknown}"></span>
        <span></span><span class="hp">${(o.team || "unknown").toUpperCase()} ${hp}</span>`;
      li.children[1].textContent = o.name;
      list.appendChild(li);
    }
  }

  function renderTasks() {
    const results = new Map(((app.state && app.state.results) || []).map((r) => [r.id, r]));
    const list = $("tasks");
    list.innerHTML = "";
    for (const o of app.sent) {
      const r = results.get(o.id);
      const status = r ? r.status : "pending";
      const li = document.createElement("li");
      li.innerHTML = `<span style="color:${TEAM_COLORS[o.team]};font-weight:800">${TEAM_LABEL[o.team]}</span>
        <span class="what"></span><span class="state ${status}">${status.replace("_", " ")}</span>
        <span class="msg"></span>`;
      li.querySelector(".what").textContent = describeOrder(o);
      li.querySelector(".msg").textContent = [o.where, r && r.message].filter(Boolean).join(" — ");
      list.appendChild(li);
    }
  }

  function renderFloorSelect() {
    const sel = $("floor");
    sel.innerHTML = "";
    const auto = document.createElement("option");
    auto.value = "auto";
    auto.textContent = "Floor: auto";
    sel.appendChild(auto);
    app.map.floors.forEach((f, i) => {
      const opt = document.createElement("option");
      opt.value = String(i);
      opt.textContent = f.name;
      sel.appendChild(opt);
    });
    sel.value = app.autoFloor ? "auto" : String(app.floorIndex);
  }

  function renderStatus() {
    const s = app.state;
    const el = $("status");
    el.className = "status " + (s && s.connected ? "live" : s && s.level ? "stale" : "");
    $("status-text").textContent = !s ? "No server" : s.connected ? "Live" : s.level ? "Game paused / stale" : "Waiting for game";
    $("level").textContent = (s && s.level) || "—";
  }

  // ---------------------------------------------------------------- calibration

  function ensureFloor() {
    if (!app.map.floors.length) {
      app.map.floors.push({ name: "Ground", image: null, zMin: -100000, zMax: 100000, anchors: [] });
      app.floorIndex = 0;
      renderFloorSelect();
    }
    return floor();
  }

  function addAnchor(sx, sy) {
    const p = app.state && app.state.player && app.state.player.pos;
    if (!p || !(app.state && app.state.connected)) {
      return alert("Calibration uses your in-game position. Start a mission and stand on the spot first.");
    }
    const f = ensureFloor();
    f.anchors = f.anchors || [];
    f.anchors.push({ world: [p.x, p.y], px: screenToPx(sx, sy) });
    renderCalibration();
    redraw();
  }

  function renderCalibration() {
    const f = floor();
    $("cal-name").value = f ? f.name : "";
    $("cal-zmin").value = f ? f.zMin : "";
    $("cal-zmax").value = f ? f.zMax : "";
    const list = $("cal-anchors");
    list.innerHTML = "";
    ((f && f.anchors) || []).forEach((a, i) => {
      const li = document.createElement("li");
      li.textContent = `${i + 1}. world (${Math.round(a.world[0])}, ${Math.round(a.world[1])}) → image (${Math.round(a.px[0])}, ${Math.round(a.px[1])})`;
      const del = document.createElement("button");
      del.textContent = "✕";
      del.onclick = () => { f.anchors.splice(i, 1); renderCalibration(); redraw(); };
      li.appendChild(del);
      list.appendChild(li);
    });
    if (!f || !(f.anchors || []).length) list.innerHTML = "<li>No anchors yet</li>";
  }

  $("cal-name").onchange = (e) => {
    const f = ensureFloor();
    const old = f.name;
    f.name = e.target.value.trim() || old;
    app.map.rooms.forEach((r) => { if (r.floor === old) r.floor = f.name; });
    renderFloorSelect();
  };
  $("cal-zmin").onchange = (e) => { ensureFloor().zMin = Number(e.target.value); };
  $("cal-zmax").onchange = (e) => { ensureFloor().zMax = Number(e.target.value); };

  $("cal-image").onchange = async (e) => {
    const file = e.target.files[0];
    if (!file || !app.level) return;
    const f = ensureFloor();
    const safe = file.name.replace(/[^A-Za-z0-9_.-]/g, "_");
    try {
      await api("PUT", `/api/maps/${encodeURIComponent(app.level)}/${encodeURIComponent(safe)}`, file, true);
      f.image = safe;
      delete app.images[safe];
      app.view.fitted = false;
      loadImage(f);
      setHint("Image loaded. Now tap anchor points, then Save map.");
    } catch (err) {
      alert("Upload failed: " + err.message);
    }
    e.target.value = "";
  };

  $("cal-add-floor").onclick = () => {
    const n = app.map.floors.length + 1;
    app.map.floors.push({ name: `Floor ${n}`, image: null, zMin: 0, zMax: 300, anchors: [] });
    app.floorIndex = app.map.floors.length - 1;
    app.autoFloor = false;
    renderFloorSelect();
    renderCalibration();
    redraw();
  };

  $("cal-delete-floor").onclick = () => {
    const f = floor();
    if (!f || !confirm(`Delete floor "${f.name}"?`)) return;
    app.map.floors.splice(app.floorIndex, 1);
    app.floorIndex = 0;
    renderFloorSelect();
    renderCalibration();
    redraw();
  };

  $("cal-save").onclick = () => saveMap().catch((e) => alert("Save failed: " + e.message));

  // ---------------------------------------------------------------- rooms

  function renderRooms() {
    const list = $("room-list");
    list.innerHTML = "";
    for (const room of app.map.rooms) {
      const li = document.createElement("li");
      li.textContent = `${room.name} · ${(room.doors || []).length} door(s)`;
      const del = document.createElement("button");
      del.textContent = "✕";
      del.onclick = () => {
        app.map.rooms = app.map.rooms.filter((r) => r !== room);
        renderRooms();
        redraw();
      };
      li.appendChild(del);
      list.appendChild(li);
    }
    if (!app.map.rooms.length) list.innerHTML = "<li>No rooms yet</li>";
  }

  $("room-undo").onclick = () => { app.draft.pop(); redraw(); };

  $("room-finish").onclick = () => {
    if (app.draft.length < 3) return alert("Tap at least 3 corners first.");
    const name = (prompt("Room name?") || "").trim();
    if (!name) return;
    const f = ensureFloor();
    const doors = ((app.state && app.state.doors) || [])
      .filter((d) => onFloor(d.pos.z, f) && Geo.distToPolygonEdge(d.pos.x, d.pos.y, app.draft) < DOOR_ROOM_LINK_UNITS)
      .map((d) => d.id);
    app.map.rooms = app.map.rooms.filter((r) => r.name !== name);
    app.map.rooms.push({ name, floor: f.name, polygon: app.draft, doors });
    app.draft = [];
    renderRooms();
    redraw();
  };

  $("room-save").onclick = () => saveMap().catch((e) => alert("Save failed: " + e.message));

  // ---------------------------------------------------------------- toolbar

  function setMode(mode) {
    app.mode = app.mode === mode ? "orders" : mode;
    $("orders-panel").hidden = app.mode !== "orders";
    $("calibrate-panel").hidden = app.mode !== "calibrate";
    $("rooms-panel").hidden = app.mode !== "rooms";
    $("btn-calibrate").classList.toggle("active", app.mode === "calibrate");
    $("btn-rooms").classList.toggle("active", app.mode === "rooms");
    app.draft = [];
    setHint({
      calibrate: "Calibrate: stand on a spot in game, then tap the same spot on the image.",
      rooms: "Rooms: tap the corners of a room, then press Finish room.",
    }[app.mode] || "");
    if (app.mode === "calibrate") renderCalibration();
    redraw();
  }

  $("btn-calibrate").onclick = () => setMode("calibrate");
  $("btn-rooms").onclick = () => setMode("rooms");
  $("btn-center").onclick = centerOnPlayer;
  $("execute").onclick = execute;

  $("floor").onchange = (e) => {
    app.autoFloor = e.target.value === "auto";
    if (!app.autoFloor) app.floorIndex = Number(e.target.value);
    renderCalibration();
    redraw();
  };

  $("teams").addEventListener("click", (e) => {
    const team = e.target.dataset && e.target.dataset.team;
    if (!team) return;
    app.team = team;
    document.querySelectorAll(".team").forEach((b) => b.classList.toggle("active", b.dataset.team === team));
    if (app.target && app.target.type === "room") {
      const room = app.map.rooms.find((r) => r.name === app.target.room);
      if (room) app.target.door = bestDoorForRoom(room);
    }
    renderOrders();
    redraw();
  });

  // ---------------------------------------------------------------- polling

  async function poll() {
    try {
      const s = await api("GET", "/api/state");
      app.state = s;
      if (s.level && s.level !== app.level) {
        app.level = s.level;
        await loadMap(s.level);
      }
      if (app.autoFloor && app.map.floors.length && s.player && s.player.pos) {
        const i = floorForZ(s.player.pos.z);
        if (i !== app.floorIndex) { app.floorIndex = i; renderCalibration(); }
      }
      if (!app.view.fitted) fitView();
      if (app.mode === "orders") {
        setHint(s.level && !app.map.floors.length ? "No floor plan for this level yet — use Calibrate to add one." : "");
      }
    } catch (e) {
      app.state = null;
    }
    renderStatus();
    renderRoster();
    const pos = app.state && app.state.player && app.state.player.pos;
    $("cal-pos").textContent = pos ? `X ${Math.round(pos.x)}  Y ${Math.round(pos.y)}  Z ${Math.round(pos.z)}` : "—";
    renderTasks();
    if (app.mode === "orders") {
      // Keep the "not set up" tags current without stealing focus.
      const configuredKey = JSON.stringify([(app.state && app.state.configured_actions) || [], app.state && app.state.connected]);
      if (configuredKey !== app.lastConfiguredKey) { app.lastConfiguredKey = configuredKey; renderOrders(); }
    }
    redraw();
    setTimeout(poll, POLL_MS);
  }

  window.addEventListener("resize", resizeCanvas);
  resizeCanvas();
  renderOrders();
  renderFloorSelect();
  requestAnimationFrame(frame);
  poll();
})();
