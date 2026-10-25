// RoNTAK ATAK interface.
(function () {
  "use strict";

  const POLL_MS = 250;
  const DOOR_HIT_PX = 20;
  const DOOR_ROOM_LINK_UNITS = 120;

  const TEAM_COLORS = { red: "#e53935", blue: "#1e88e5", gold: "#f9a825", unknown: "#9e9e9e" };
  const TEAM_LABEL = { red: "RED", blue: "BLUE", gold: "GOLD" };

  const OPTION_CHOICES = {
    breach: [["kick", "Kick"], ["shotgun", "Shotgun"], ["c2", "C2"], ["ram", "Ram"], ["leader", "Leader"]],
    grenade: [["none", "None"], ["flashbang", "Flash"], ["stinger", "Stinger"], ["cs", "CS Gas"],
      ["ninebang", "9-Bang"], ["launcher", "Launcher"]],
    side: [["auto", "Auto"], ["split", "Split"], ["left", "Left"], ["right", "Right"]],
    scan: [["slice", "Slice"], ["slide", "Slide"], ["snap", "Snap"], ["center", "Center"]],
  };
  const OPTION_LABEL = { breach: "Breach", grenade: "Grenade", side: "Stack", scan: "Scan" };
  // Option values that use up an item. The mod reports item counts per officer.
  const OPTION_ITEMS = {
    breach: { c2: "c2", shotgun: "shotgun", ram: "ram" },
    grenade: { flashbang: "flashbang", stinger: "stinger", cs: "cs", ninebang: "ninebang", launcher: "launcher" },
  };
  // Items an order needs (any one of them).
  const ACTION_ITEMS = {
    wedge_door: ["wedge"], scan_door: ["mirror"], pick_lock: ["multitool", "lockpick_gun"],
    disarm_trap: ["multitool"], chemlight: ["chemlight"],
  };
  const ITEM_LABEL = { lockpick_gun: "lockpick", multitool: "multitool" };

  // needs: "door" (a door, or a room through one of its doors), "spot" (a point on
  // the map), "person" (a surrendered / restrained / downed person), null (team-wide).
  // door: "closed" / "open" = only on a door in that state. values: allowed option values.
  const ACTIONS = [
    { id: "stack_up", label: "Stack Up", needs: "door", options: ["side"] },
    { id: "breach_clear", label: "Breach & Clear", needs: "door", door: "closed", options: ["breach", "grenade", "side"] },
    { id: "open_clear", label: "Open & Clear", needs: "door", door: "closed", options: ["grenade", "side"] },
    { id: "move_clear", label: "Move & Clear", needs: "door", door: "open", options: ["grenade", "side"] },
    { id: "scan_open", label: "Scan Room", needs: "door", door: "open", options: ["scan"] },
    { id: "scan_door", label: "Mirror Door", needs: "door", door: "closed", options: [] },
    { id: "pick_lock", label: "Pick Lock", needs: "door", door: "closed", options: [] },
    { id: "check_traps", label: "Check for Traps", needs: "door", door: "closed", options: [] },
    { id: "disarm_trap", label: "Disarm Trap", needs: "door", door: "closed", options: [] },
    { id: "wedge_door", label: "Wedge Door", needs: "door", door: "closed", options: [] },
    { id: "remove_wedge", label: "Remove Wedge", needs: "door", door: "closed", options: [] },
    { id: "close_door", label: "Close Door", needs: "door", door: "open", options: [] },
    { id: "restrain", label: "Restrain", needs: "person", options: [] },
    { id: "report", label: "Report", needs: "person", options: [] },
    { id: "move_to", label: "Move To", needs: "spot", options: [] },
    { id: "cover_area", label: "Cover Area", needs: "spot", options: [] },
    { id: "deploy_grenade", label: "Deploy Grenade", needs: "spot", options: ["grenade"],
      values: { grenade: ["flashbang", "stinger", "cs", "ninebang"] } },
    { id: "chemlight", label: "Drop Chemlight", needs: "spot", options: [] },
    { id: "fall_in", label: "Fall In", needs: null, options: [] },
    { id: "hold", label: "Hold", needs: null, options: [] },
    { id: "search_secure", label: "Search & Secure", needs: null, options: [] },
  ];
  const ACTION_BY_ID = Object.fromEntries(ACTIONS.map((a) => [a.id, a]));

  const $ = (id) => document.getElementById(id);

  // Per-browser settings; storage can be unavailable (private windows).
  function loadSetting(key) {
    try { return localStorage.getItem("rontak." + key); } catch (e) { return null; }
  }
  function saveSetting(key, value) {
    try { localStorage.setItem("rontak." + key, value); } catch (e) { /* not remembered */ }
  }
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
    gameRooms: [], // rooms read from the game (rooms.json), see loadGameRooms()
    showGameRooms: loadSetting("showGameRooms") === "1", // off: their names are just "Room 5"
    mapLoaded: false, // map.json of app.level has been read
    roomsVersion: null,
    pendingAnchor: null, // calibration: world position of the door tapped first
    holdForGo: false, // send orders as "held" until GO
    draft: [],
    dirty: true,
  };

  // ---------------------------------------------------------------- helpers

  function floor() {
    return app.map.floors[app.floorIndex] || null;
  }

  function transform() {
    const f = floor();
    const anchors = (f && f.anchors) || [];
    if (anchors.length >= 2) return Geo.fit(anchors);
    return provisionalTransform(f, anchors[0]);
  }

  // Before a floor plan is calibrated, lay the level's doors and rooms over
  // the image area (top-down, +X up) so their markers can be tapped as anchors.
  // With one anchor, shift so that anchor already lines up.
  function provisionalTransform(f, anchor) {
    const img = f && app.images[f.image];
    if (!img || !img.naturalWidth) return Geo.DEFAULT;
    const pts = ((app.state && app.state.doors) || []).filter((d) => onFloor(d.pos.z, f)).map((d) => [d.pos.x, d.pos.y]);
    app.gameRooms.forEach((r) => { if (onFloor(r.z, f)) (r.polygon || []).forEach((p) => pts.push(p)); });
    if (pts.length < 2) return Geo.DEFAULT;
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
    // Image u follows world Y, image v follows world -X.
    const k = 0.9 * Math.min(img.naturalWidth / Math.max(1, maxY - minY), img.naturalHeight / Math.max(1, maxX - minX));
    let e = img.naturalWidth / 2 - k * (minY + maxY) / 2;
    let fOff = img.naturalHeight / 2 + k * (minX + maxX) / 2;
    if (anchor) {
      e = anchor.px[0] - k * anchor.world[1];
      fOff = anchor.px[1] + k * anchor.world[0];
    }
    return { a: 0, b: k, c: -k, d: 0, e, f: fOff };
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

  // "Living_Room_2" -> "Living Room 2"
  function prettyRoom(name) {
    return String(name).replace(/_/g, " ").replace(/\s+/g, " ").trim();
  }

  // Rooms drawn by hand (map.json), plus, when the guide is switched on, the
  // game's rooms (a hand-drawn room with the same name wins).
  function allRooms() {
    const manual = app.map.rooms;
    if (!app.showGameRooms) return manual;
    const names = new Set(manual.map((r) => r.name));
    return manual.concat(app.gameRooms.filter((r) => !names.has(r.name)));
  }

  function findRoom(name) {
    return allRooms().find((r) => r.name === name) || null;
  }

  function roomsOnFloor() {
    const f = floor();
    return allRooms().filter((r) => (r.game ? onFloor(r.z, f) : !f || !r.floor || r.floor === f.name));
  }

  function hasOutline(room) {
    return Boolean(room.polygon && room.polygon.length >= 3);
  }

  function roomCenter(room) {
    return hasOutline(room) ? Geo.centroid(room.polygon) : room.center;
  }

  function doorLabel(id) {
    const door = doorById(id);
    const sides = door && app.showGameRooms ? [door.front_room, door.back_room].filter(Boolean).map(prettyRoom) : [];
    const room = sides.length ? null : allRooms().find((r) => (r.doors || []).includes(id));
    const base = sides.length ? `${sides.join(" / ")} door` : room ? `${room.name} door` : `Door ${id.replace(/^.*_/, "#")}`;
    if (!door) return base;
    const notes = [];
    if (door.broken) notes.push("broken");
    else if (door.open) notes.push("open");
    if (door.wedged) notes.push("wedged");
    if (door.locked && !door.open) notes.push("locked");
    if (door.trap) notes.push("trapped");
    return notes.length ? `${base} (${notes.join(", ")})` : base;
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

  // Floors from the heights of the level's doors, for maps without any floors
  // yet. Rename them in Calibrate; Save map keeps them.
  // Ready or Not's floor names: Ground, 1st, 2nd, ... (rename a basement yourself).
  function floorName(i) {
    if (i === 0) return "Ground";
    const suffix = i % 10 === 1 && i !== 11 ? "st" : i % 10 === 2 && i !== 12 ? "nd" : i % 10 === 3 && i !== 13 ? "rd" : "th";
    return `${i}${suffix}`;
  }

  function autoFloors(doors) {
    const bands = Geo.floorBands(doors.map((d) => d.pos.z));
    return bands.map((b, i) => ({
      name: floorName(i),
      image: null, zMin: Math.round(b.zMin), zMax: Math.round(b.zMax), anchors: [], auto: true,
    }));
  }

  function ensureAutoFloors() {
    const doors = (app.state && app.state.doors) || [];
    if (!app.mapLoaded || app.map.floors.length || !doors.length) return;
    app.map.floors = autoFloors(doors);
    app.floorIndex = 0;
    app.view.fitted = false;
    renderFloorSelect();
    renderCalibration();
  }

  async function loadMap(level) {
    app.mapLoaded = false;
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
    app.mapLoaded = true;
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

  // Game room outline: the hull of the AI's threat points, pushed out a little
  // because those points sit inside the room, not on its walls.
  const GAME_ROOM_PADDING = 60;

  function padOutline(hull) {
    if (hull.length < 3) return null;
    const [cx, cy] = Geo.centroid(hull);
    return hull.map(([x, y]) => {
      const len = Math.hypot(x - cx, y - cy) || 1;
      return [x + ((x - cx) / len) * GAME_ROOM_PADDING, y + ((y - cy) / len) * GAME_ROOM_PADDING];
    });
  }

  async function loadGameRooms() {
    try {
      const data = await api("GET", "/api/rooms");
      if (data.level !== app.level) return;
      app.gameRooms = (data.rooms || []).map((r) => {
        const polygon = padOutline(r.hull || []);
        let center = polygon ? Geo.centroid(polygon) : r.hull && r.hull.length ? Geo.centroid(r.hull) : null;
        if (!center) {
          const doors = (r.doors || []).map(doorById).filter(Boolean);
          if (doors.length) center = [doors[0].pos.x, doors[0].pos.y];
        }
        return { name: prettyRoom(r.name), game: true, polygon, center, z: r.z, doors: r.doors || [] };
      });
      if (!app.map.floors.length) app.view.fitted = false;
      renderRooms();
      redraw();
    } catch (e) {
      console.warn("rooms load failed", e);
    }
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
      app.gameRooms.forEach((r) => (r.polygon || []).forEach(([x, y]) => pts.push({ x, y })));
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
    drawPeople();
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
    const f = floor();
    for (const room of roomsOnFloor()) {
      const isSel = room.name === selected;
      if (hasOutline(room)) {
        polygonPath(room.polygon);
        ctx.fillStyle = isSel ? "rgba(0, 188, 212, 0.22)" : "rgba(0, 188, 212, 0.05)";
        ctx.fill();
        ctx.strokeStyle = isSel ? "#00bcd4" : "rgba(0, 188, 212, 0.35)";
        ctx.lineWidth = isSel ? 2.5 : 1;
        // Game rooms are outlined around the AI's points, not the walls: dashed.
        ctx.setLineDash(room.game ? [6, 4] : []);
        ctx.stroke();
        ctx.setLineDash([]);
      }
      // Game room names are always shown (they are what the image lacks).
      if ((isSel || room.game || !(f && f.image)) && roomCenter(room)) {
        const [cx, cy] = roomCenter(room);
        const [sx, sy] = worldToScreen(cx, cy);
        ctx.font = "600 12px system-ui, sans-serif";
        ctx.textAlign = "center";
        // Dark halo so names stay readable on light floor plan images.
        ctx.lineWidth = 3;
        ctx.strokeStyle = "rgba(16, 19, 22, 0.85)";
        ctx.strokeText(room.name, sx, sy);
        ctx.fillStyle = isSel ? "#00bcd4" : "#e6e9ec";
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
      ctx.strokeStyle = sel ? "#00bcd4" : d.broken ? "#9e9e9e" : d.open ? "#66bb6a" : d.wedged ? "#ab47bc"
        : d.locked ? "#ff7043" : "#ffd54f";
      ctx.lineWidth = sel ? 7 : 5;
      ctx.beginPath();
      ctx.moveTo(bx, by);
      ctx.lineTo(ex, ey);
      ctx.stroke();
      if (d.trap) {
        ctx.fillStyle = "#e53935";
        ctx.font = "800 14px system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.fillText("!", sx, sy - 10);
      }
      if (sel) {
        ctx.beginPath();
        ctx.arc(sx, sy, 14, 0, Math.PI * 2);
        ctx.strokeStyle = "#00bcd4";
        ctx.lineWidth = 2;
        ctx.stroke();
      }
    }
  }

  const PERSON_COLORS = { suspect: "#ff7043", civilian: "#81c784" };
  const PERSON_LETTER = { surrendered: "S", arrested: "R", down: "✕" };

  // Surrendered / restrained / downed people: suspects as diamonds, civilians
  // as circles, with a letter for their state. Reported people are faded.
  function drawPeople() {
    const f = floor();
    const selected = app.target && app.target.type === "person" ? app.target.character : null;
    for (const t of (app.state && app.state.targets) || []) {
      const [sx, sy] = worldToScreen(t.pos.x, t.pos.y);
      ctx.globalAlpha = (onFloor(t.pos.z, f) ? 1 : 0.3) * (t.reported ? 0.5 : 1);
      ctx.fillStyle = PERSON_COLORS[t.kind] || "#bdbdbd";
      ctx.strokeStyle = "#101316";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      if (t.kind === "suspect") {
        ctx.moveTo(sx, sy - 10); ctx.lineTo(sx + 10, sy); ctx.lineTo(sx, sy + 10); ctx.lineTo(sx - 10, sy);
        ctx.closePath();
      } else {
        ctx.arc(sx, sy, 8, 0, Math.PI * 2);
      }
      ctx.fill();
      ctx.stroke();
      ctx.fillStyle = "#101316";
      ctx.font = "700 10px system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(PERSON_LETTER[t.status] || "?", sx, sy + 0.5);
      ctx.textBaseline = "alphabetic";
      if (t.id === selected) {
        ctx.strokeStyle = "#00bcd4";
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(sx, sy, 15, 0, Math.PI * 2);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
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
    if (app.pendingAnchor) {
      const [sx, sy] = worldToScreen(app.pendingAnchor.x, app.pendingAnchor.y);
      ctx.strokeStyle = "#ff4081";
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.arc(sx, sy, 16, 0, Math.PI * 2);
      ctx.stroke();
    }
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

  // The door marker under a screen point (on the current floor), or null.
  function doorAt(sx, sy) {
    const f = floor();
    let best = null, bestD = DOOR_HIT_PX;
    for (const d of (app.state && app.state.doors) || []) {
      if (!onFloor(d.pos.z, f)) continue;
      const [dx, dy] = worldToScreen(d.pos.x, d.pos.y);
      const dist = Math.hypot(dx - sx, dy - sy);
      if (dist < bestD) { best = d; bestD = dist; }
    }
    return best;
  }

  const PERSON_HIT_PX = 16;

  // The person marker under a screen point (on the current floor), or null.
  function personAt(sx, sy) {
    const f = floor();
    let best = null, bestD = PERSON_HIT_PX;
    for (const t of (app.state && app.state.targets) || []) {
      if (!onFloor(t.pos.z, f)) continue;
      const [px, py] = worldToScreen(t.pos.x, t.pos.y);
      const dist = Math.hypot(px - sx, py - sy);
      if (dist < bestD) { best = t; bestD = dist; }
    }
    return best;
  }

  function selectAt(sx, sy) {
    const person = personAt(sx, sy);
    const best = person ? null : doorAt(sx, sy);
    const [wx, wy] = screenToWorld(sx, sy);
    if (person) {
      app.target = { type: "person", character: person.id };
    } else if (best) {
      const room = allRooms().find((r) => (r.doors || []).includes(best.id));
      app.target = { type: "door", door: best.id, room: room && room.name };
    } else {
      const room = roomsOnFloor().find((r) => hasOutline(r) && Geo.pointInPolygon(wx, wy, r.polygon));
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

  // The order picked when a target is tapped: the first one that can be given.
  function defaultAction() {
    const t = app.target;
    if (!t) return null;
    let preferred = ["move_to"];
    if (t.type === "person") preferred = ["restrain", "report"];
    else if (t.door) {
      const door = doorById(t.door);
      preferred = door && door.wedged ? ["remove_wedge", "stack_up"]
        : doorIsOpen(door) ? ["move_clear", "stack_up"] : ["stack_up"];
    }
    return preferred.find((id) => actionAllowed(ACTION_BY_ID[id])) || preferred[0];
  }

  // ---------------------------------------------------------------- orders

  function doorIsOpen(door) {
    return Boolean(door && (door.open || door.broken));
  }

  // Total of an item carried by the selected team, or null when the mod does
  // not report inventory (then nothing is disabled).
  function teamItemCount(item) {
    const members = teamMembers(app.team).filter((o) => o.items);
    if (!members.length) return null;
    return members.reduce((sum, o) => sum + (o.items[item] || 0), 0);
  }

  // True when the team has none of the items (any one of them would do).
  function itemsMissing(items) {
    if (!items || !items.length) return false;
    return items.every((item) => teamItemCount(item) === 0);
  }

  function personById(id) {
    return ((app.state && app.state.targets) || []).find((t) => t.id === id) || null;
  }

  // Whether an order belongs on the panel for the current target at all.
  function actionVisible(action) {
    const t = app.target;
    if (!action.needs) return true;
    if (!t) return false;
    if (action.needs === "person") return t.type === "person";
    if (action.needs === "door") return Boolean(t.door) && (t.type === "door" || t.type === "room");
    // Spot orders: on a map point or a room; on a door only Move To.
    if (t.type === "location" || t.type === "room") return true;
    return t.type === "door" && action.id === "move_to";
  }

  // Option values offered for an order (e.g. no "None" for Deploy Grenade).
  function optionValues(action, key) {
    const allowed = action.values && action.values[key];
    return OPTION_CHOICES[key].filter(([value]) => !allowed || allowed.includes(value));
  }

  function optionAvailable(key, value) {
    const item = (OPTION_ITEMS[key] || {})[value];
    return !item || teamItemCount(item) !== 0;
  }

  // Why an order on a door can't be given in the door's current state, or null.
  function doorReason(action, door) {
    if (!door) return null;
    const open = doorIsOpen(door);
    if (action.door === "closed" && open) return "door is open";
    if (action.door === "open" && !open) return "door is closed";
    if (action.id === "close_door" && door.broken) return "door is broken";
    if (door.wedged && !["remove_wedge", "stack_up"].includes(action.id)) return "door is wedged";
    if (action.id === "remove_wedge" && !door.wedged) return "not wedged";
    if (action.id === "disarm_trap" && !door.trap) return "no known trap";
    if (action.id === "open_clear" && door.locked) return "door is locked";
    if (action.id === "pick_lock" && door.locked === false) return "not locked";
    return null;
  }

  function personReason(action, person) {
    if (!person) return "no longer on the map";
    if (action.id === "restrain" && person.status === "arrested") return "already restrained";
    if (action.id === "report" && person.reported) return "already reported";
    if (action.id === "report" && person.status === "surrendered") return "restrain first";
    return null;
  }

  // Why an order cannot be given right now, or null if it can.
  function blockedReason(action) {
    if (!actionVisible(action)) return "pick a target";
    if (action.needs === "door") {
      const reason = doorReason(action, doorById(app.target.door));
      if (reason) return reason;
    }
    if (action.needs === "person") {
      const reason = personReason(action, personById(app.target.character));
      if (reason) return reason;
    }
    const items = ACTION_ITEMS[action.id];
    if (itemsMissing(items)) return `no ${ITEM_LABEL[items[0]] || items[0]} on ${TEAM_LABEL[app.team]}`;
    for (const key of action.options) {
      if (!optionValues(action, key).some(([value]) => optionAvailable(key, value))) {
        return `no ${OPTION_LABEL[key].toLowerCase()} gear on ${TEAM_LABEL[app.team]}`;
      }
    }
    return null;
  }

  function actionAllowed(action) {
    return blockedReason(action) === null;
  }

  // Orders blocked for these reasons are left off the panel (they don't fit
  // the door at all); other blocked orders are shown greyed with the reason.
  const HIDDEN_REASONS = new Set(["door is open", "door is closed", "door is wedged", "not wedged", "no known trap", "not locked"]);

  // Moves the options of the selected order to values it offers and the team
  // has gear for (e.g. back to Kick when the C2 is used up).
  function fixOptions() {
    const action = ACTION_BY_ID[app.action];
    if (!action) return;
    for (const key of action.options) {
      const values = optionValues(action, key);
      const current = values.find(([value]) => value === app.options[key]);
      if (!current || !optionAvailable(key, current[0])) {
        const first = values.find(([value]) => optionAvailable(key, value));
        if (first) app.options[key] = first[0];
      }
    }
  }

  function targetLocation() {
    const t = app.target;
    if (!t) return null;
    if (t.type === "person") {
      const person = personById(t.character);
      return person ? person.pos : null;
    }
    if (t.type === "location") return t.location;
    if (t.type === "room") {
      const room = findRoom(t.room);
      if (room && roomCenter(room)) {
        const [x, y] = roomCenter(room);
        const door = doorById(t.door);
        return { x, y, z: room.game ? room.z : door ? door.pos.z : 0 };
      }
    }
    const door = doorById(t.door);
    return door ? door.pos : null;
  }

  const PERSON_STATUS = { surrendered: "Surrendered", arrested: "Restrained", down: "Downed" };

  function describePerson(person) {
    if (!person) return "Person (gone)";
    const text = `${PERSON_STATUS[person.status] || person.status} ${person.kind}`;
    return person.reported ? `${text} (reported)` : text;
  }

  function describeTarget() {
    const t = app.target;
    if (!t) return "Tap a door, room, person or spot on the map";
    if (t.type === "person") return describePerson(personById(t.character));
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
    fixOptions();
    const action = ACTION_BY_ID[app.action];
    if (!action || !actionAllowed(action)) return;
    const target = {};
    if (app.target && app.target.door) target.door = app.target.door;
    if (app.target && app.target.room) target.room = app.target.room;
    if (app.target && app.target.character) target.character = app.target.character;
    const loc = targetLocation();
    if (loc) target.location = { x: loc.x, y: loc.y, z: loc.z || 0 };
    const options = {};
    for (const k of action.options) options[k] = app.options[k];

    const order = { team: app.team, action: action.id, target, options, hold: app.holdForGo };
    try {
      const sent = await api("POST", "/api/command", order);
      app.sent.unshift({ ...order, id: sent.id, where: app.target && action.needs ? describeTarget() : "" });
      app.sent.length = Math.min(app.sent.length, 30);
      renderTasks();
    } catch (e) {
      alert("Could not send order: " + e.message);
    }
  }

  // ---------------------------------------------------------------- panels

  function renderOrders() {
    fixOptions();
    if (app.action && !actionAllowed(ACTION_BY_ID[app.action])) app.action = defaultAction();
    $("target-text").textContent = describeTarget();

    const choice = $("door-choice");
    choice.innerHTML = "";
    if (app.target && app.target.type === "room") {
      const room = findRoom(app.target.room);
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
    for (const a of ACTIONS.filter((x) => actionVisible(x) && !HIDDEN_REASONS.has(blockedReason(x)))) {
      const b = document.createElement("button");
      b.textContent = a.label;
      const reason = blockedReason(a);
      b.disabled = reason !== null;
      b.className = a.id === app.action ? "active" : "";
      const note = app.state && app.state.connected && !configured.has(a.id) ? "not set up in config.lua"
        : reason && reason !== "pick a target" && reason !== "needs a door" ? reason : null;
      if (note) {
        const tag = document.createElement("span");
        tag.className = "tag";
        tag.textContent = note;
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
      for (const [value, label] of optionValues(action, key)) {
        const b = document.createElement("button");
        const item = (OPTION_ITEMS[key] || {})[value];
        const count = item ? teamItemCount(item) : null;
        b.textContent = count === null ? label : `${label} ×${count}`;
        b.disabled = !optionAvailable(key, value);
        b.className = app.options[key] === value ? "active" : "";
        b.onclick = () => { app.options[key] = value; renderOrders(); };
        chips.appendChild(b);
      }
      wrap.appendChild(chips);
      opts.appendChild(wrap);
    }

    const exec = $("execute");
    exec.disabled = !action || !actionAllowed(action);
    exec.textContent = action
      ? `${app.holdForGo ? "HOLD: " : ""}${TEAM_LABEL[app.team]} — ${action.label.toUpperCase()}` : "SELECT AN ORDER";
    renderHeld();
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

  // An anchor pairs a world position with a point on the image. The world
  // position is a door (tap its marker first) or, failing that, where you
  // are standing in game.
  function addAnchor(sx, sy) {
    let world = app.pendingAnchor;
    if (!world) {
      const door = doorAt(sx, sy);
      if (door) {
        app.pendingAnchor = { x: door.pos.x, y: door.pos.y };
        setHint("Now tap where that door is on the image.");
        return redraw();
      }
      const p = app.state && app.state.player && app.state.player.pos;
      if (!p || !(app.state && app.state.connected)) {
        return alert("Tap a door marker first, then the same door on the image.");
      }
      if (!confirm("No door marker there. Use the spot where you are standing in game for this anchor?")) return;
      world = p;
    }
    app.pendingAnchor = null;
    const f = ensureFloor();
    f.anchors = f.anchors || [];
    f.anchors.push({ world: [world.x, world.y], px: screenToPx(sx, sy) });
    setHint(f.anchors.length < 2 ? "Anchor added. Add one more, far from the first." : "Anchor added. Save map when it lines up.");
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
    if (!app.map.rooms.length) list.innerHTML = "<li>No hand-drawn rooms</li>";
    $("show-game-rooms").checked = app.showGameRooms;
    $("game-room-count").textContent = app.gameRooms.length ? `(${app.gameRooms.length})` : "";
  }

  $("show-game-rooms").onchange = (e) => {
    app.showGameRooms = e.target.checked;
    saveSetting("showGameRooms", app.showGameRooms ? "1" : "0");
    if (app.target && app.target.type === "room" && !findRoom(app.target.room)) app.target = null;
    renderRooms();
    renderOrders();
    redraw();
  };

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
      calibrate: "Calibrate: tap a door marker, then the same door on the image. Do this for two doors.",
      rooms: "Rooms: tap the corners of a room, then press Finish room.",
    }[app.mode] || "");
    if (app.mode === "calibrate") renderCalibration();
    redraw();
  }

  $("btn-calibrate").onclick = () => setMode("calibrate");
  $("btn-rooms").onclick = () => setMode("rooms");
  $("btn-center").onclick = centerOnPlayer;
  $("execute").onclick = execute;

  // ---------------------------------------------------------------- phone

  const QR_SCRIPT = "https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js";
  let serverInfo = {};

  async function loadInfo() {
    try {
      serverInfo = await api("GET", "/api/info");
      if (serverInfo.version) $("level").title = `RoNTAK ${serverInfo.version}`;
    } catch (e) {
      serverInfo = {};
    }
  }

  // The QR library is only fetched when this panel opens, so the ATAK screen
  // never needs the internet; without it the address is still shown.
  function loadQrLibrary() {
    if (window.QRCode) return Promise.resolve(true);
    return new Promise((resolve) => {
      const script = document.createElement("script");
      script.src = QR_SCRIPT;
      script.onload = () => resolve(Boolean(window.QRCode));
      script.onerror = () => resolve(false);
      document.head.appendChild(script);
    });
  }

  async function openPhone() {
    await loadInfo();
    const body = $("phone-body");
    body.innerHTML = "";
    $("phone-modal").hidden = false;
    if (!serverInfo.lan_url) {
      body.innerHTML = `<p class="steps">Phone access is off. Close the companion window and start it again with
        <b>--lan</b> (for example <code>Start RoNTAK.bat --lan</code>); it's remembered from then on.</p>`;
      return;
    }
    const intro = document.createElement("p");
    intro.className = "steps";
    intro.textContent = "Connect the phone to the same Wi-Fi as this PC, then scan the code or type the address:";
    const url = document.createElement("div");
    url.className = "phone-url";
    url.textContent = serverInfo.lan_url;
    const qr = document.createElement("div");
    qr.className = "qr";
    body.append(intro, qr, url);
    if (await loadQrLibrary()) {
      new window.QRCode(qr, { text: serverInfo.lan_url, width: 200, height: 200 });
    } else {
      qr.remove();
    }
  }

  $("btn-phone").onclick = openPhone;
  $("phone-close").onclick = () => { $("phone-modal").hidden = true; };
  $("phone-modal").onclick = (e) => { if (e.target.id === "phone-modal") $("phone-modal").hidden = true; };

  $("hold-for-go").onchange = (e) => { app.holdForGo = e.target.checked; renderOrders(); };

  async function sendControl(action) {
    try {
      await api("POST", "/api/command", { team: "gold", action });
    } catch (e) {
      alert("Could not send: " + e.message);
    }
  }
  $("go").onclick = () => sendControl("go");
  $("clear-held").onclick = () => sendControl("clear_held");

  // Orders the mod is holding for GO (from state.json).
  function renderHeld() {
    const held = (app.state && app.state.held) || [];
    $("held").hidden = !held.length;
    const list = $("held-list");
    list.innerHTML = "";
    for (const h of held) {
      const sent = app.sent.find((o) => o.id === h.id);
      const li = document.createElement("li");
      li.innerHTML = `<span style="color:${TEAM_COLORS[h.team]};font-weight:800">${TEAM_LABEL[h.team]}</span><span></span>`;
      li.children[1].textContent = sent ? describeOrder(sent) : (ACTION_BY_ID[h.action] || { label: h.action }).label;
      list.appendChild(li);
    }
  }

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
      const room = findRoom(app.target.room);
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
      ensureAutoFloors();
      if (s.rooms_version && s.rooms_version !== app.roomsVersion) {
        app.roomsVersion = s.rooms_version;
        await loadGameRooms();
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
      // Re-render when anything the order panel depends on changes.
      const s = app.state || {};
      const door = app.target && app.target.door ? doorById(app.target.door) : null;
      const person = app.target && app.target.character ? personById(app.target.character) : null;
      const configuredKey = JSON.stringify([s.configured_actions || [], s.connected,
        teamMembers(app.team).map((o) => o.items || null),
        door && [door.open, door.broken, door.locked, door.wedged, door.trap],
        person && [person.status, person.reported], s.held || []]);
      if (configuredKey !== app.lastConfiguredKey) { app.lastConfiguredKey = configuredKey; renderOrders(); }
    }
    redraw();
    setTimeout(poll, POLL_MS);
  }

  window.addEventListener("resize", resizeCanvas);
  loadInfo();
  resizeCanvas();
  renderOrders();
  renderFloorSelect();
  requestAnimationFrame(frame);
  poll();
})();
