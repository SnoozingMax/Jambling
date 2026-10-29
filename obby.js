/* Jambling Obby: a 3D obstacle course (three.js) with everyone online shown live through Supabase Realtime. */
window.Obby = (function () {
  const G = 30, JUMP = 11, SPEED = 7.5, PW = 0.4, PH = 1.8;          // gravity, jump speed, run speed, player half-width / height
  let THREE, sb, me, renderer, scene, camera, wrap, canvas, raf = null, open = false, ch = null, joined = false;
  let parts = [], killers = [], spinners = [], cps = [], finishBox = null, player, remote = {}, lastSend = 0, lastSig = '';
  const S = { x: 0, y: 1, z: 0, vx: 0, vy: 0, vz: 0, yaw: 0, ground: null, cp: 0, deaths: 0, t0: null, done: false, best: null, moving: false, walk: 0, spawnAt: 0 };
  const cam = { yaw: Math.PI, pitch: 0.35, dist: 7.5 };
  const keys = {}; let joy = null, camDrag = null, jumpQ = false;
  const onHud = {};

  /* ---------- course ---------- */
  function course() {
    const P = [];
    const box = (x, y, z, w, h, d, o = {}) => P.push(Object.assign({ x, y, z, w, h, d, color: 0x9aa4b2 }, o));
    const cp = (x, y, z, n) => box(x, y, z, 6, 1, 6, { color: 0x3fcf7a, cp: n });
    // 0 spawn
    box(0, 0, 0, 10, 1, 10, { color: 0x6c8ef5 }); cps.push([0, 1, 0]);
    // 1 jump blocks
    [[1, 6], [-1.2, 10], [1.4, 14], [-1, 18.5], [1, 23]].forEach(([x, z], i) => box(x, 0, z, 2.2, 1, 2.2, { color: i % 2 ? 0xf5b86c : 0xf58f6c }));
    cp(0, 0, 28, 1); cps.push([0, 1, 28]);
    // 2 lava field with stepping stones
    box(0, -1.2, 44, 22, 0.6, 26, { color: 0xff3b2f, kill: true, lava: true });
    [[0, 34, 0], [2.4, 38, 0.3], [-1.5, 42, 0.7], [1.8, 46, 1.0], [-2.2, 50, 1.3], [0.5, 54, 1.6]].forEach(([x, z, y]) => box(x, y, z, 1.8, 0.6, 1.8, { color: 0x4b4f5c }));
    cp(0, 1.8, 60, 2); cps.push([0, 2.8, 60]);
    // 3 moving platforms over the void
    box(0, 1.8, 66, 3, 0.6, 3, { color: 0x6cc6f5, move: { axis: 'x', amp: 4, speed: 1.1, phase: 0 } });
    box(0, 1.8, 72, 3, 0.6, 3, { color: 0x6cc6f5, move: { axis: 'x', amp: 4, speed: 1.1, phase: Math.PI } });
    box(0, 1.8, 78, 3, 0.6, 3, { color: 0x6cc6f5, move: { axis: 'y', amp: 2, speed: 1.4, phase: 0 } });
    cp(0, 1.8, 84, 3); cps.push([0, 2.8, 84]);
    // 4 spinner arena
    box(0, 1.8, 95, 14, 0.6, 14, { color: 0x8d93a6 });
    spinners.push({ x: 0, y: 2.5, z: 95, len: 12, speed: 1.6, a: 0 });
    cp(0, 1.8, 106, 4); cps.push([0, 2.8, 106]);
    // 5 narrow beams
    box(0, 1.8, 115, 0.7, 0.5, 12, { color: 0xf5e36c });
    box(3, 1.8, 121, 6.7, 0.5, 0.7, { color: 0xf5e36c });
    box(6, 1.8, 127, 0.7, 0.5, 12, { color: 0xf5e36c });
    cp(6, 1.8, 136, 5); cps.push([6, 2.8, 136]);
    // 6 stairs up
    for (let i = 0; i < 7; i++) box(6, 1.8 + (i + 1) * 1.1, 141 + i * 2.6, 2.4, 0.6, 2.2, { color: i % 2 ? 0xb59cf5 : 0x9c7ef0 });
    cp(6, 9.5, 162, 6); cps.push([6, 10.5, 162]);
    // 7 vanishing blocks
    [[6, 167], [4.5, 171], [7.5, 175], [6, 179], [4.5, 183], [7.5, 187]].forEach(([x, z], i) => box(x, 9.5, z, 2.2, 0.6, 2.2, { color: 0xffffff, blink: { period: 3.2, on: 1.9, phase: i * 0.55 } }));
    // 8 finish
    box(6, 9.5, 194, 8, 1, 8, { color: 0xe8b23a, finish: true }); finishBox = P[P.length - 1];
    return P;
  }

  /* ---------- scene ---------- */
  function build() {
    scene = new THREE.Scene(); scene.background = new THREE.Color(0x8fc8ff); scene.fog = new THREE.Fog(0x8fc8ff, 60, 170);
    camera = new THREE.PerspectiveCamera(65, 1, 0.1, 400);
    scene.add(new THREE.HemisphereLight(0xdfefff, 0x6b7a8f, 0.55));
    const sun = new THREE.DirectionalLight(0xffffff, 0.75); sun.position.set(30, 60, 20); sun.castShadow = true;
    sun.shadow.mapSize.set(2048, 2048); Object.assign(sun.shadow.camera, { left: -60, right: 60, top: 60, bottom: -60, near: 1, far: 200 });
    scene.add(sun); scene.userData.sun = sun;
    parts = course();
    const geo = new THREE.BoxGeometry(1, 1, 1);
    for (const p of parts) {
      const mat = new THREE.MeshLambertMaterial({ color: p.color, transparent: !!p.blink, emissive: p.lava ? 0x5a0d08 : 0x000000 });
      const m = new THREE.Mesh(geo, mat); m.scale.set(p.w, p.h, p.d); m.position.set(p.x, p.y + p.h / 2, p.z);
      m.castShadow = !p.lava; m.receiveShadow = true; scene.add(m); p.mesh = m; p.x0 = p.x; p.y0 = p.y; p.z0 = p.z;
      if (p.cp != null) { const ring = new THREE.Mesh(new THREE.TorusGeometry(2.2, 0.12, 8, 32), new THREE.MeshBasicMaterial({ color: 0xffffff })); ring.rotation.x = Math.PI / 2; ring.position.set(p.x, p.y + p.h + 0.05, p.z); scene.add(ring); }
      if (p.kill) killers.push(p);
    }
    for (const s of spinners) {
      const bar = new THREE.Mesh(new THREE.BoxGeometry(s.len, 0.8, 0.8), new THREE.MeshLambertMaterial({ color: 0xff5a3c })); bar.castShadow = true;
      const hub = new THREE.Mesh(new THREE.CylinderGeometry(0.6, 0.6, 2.4, 16), new THREE.MeshLambertMaterial({ color: 0x3a3548 }));
      bar.position.set(s.x, s.y + 0.4, s.z); hub.position.set(s.x, s.y + 0.6, s.z); scene.add(bar, hub); s.mesh = bar;
    }
    // finish beacon
    const beam = new THREE.Mesh(new THREE.CylinderGeometry(0.3, 0.3, 30, 12, 1, true), new THREE.MeshBasicMaterial({ color: 0xfff1b0, transparent: true, opacity: 0.35, side: THREE.DoubleSide }));
    beam.position.set(finishBox.x, finishBox.y + 15, finishBox.z); scene.add(beam);
    // ground far below (visual only)
    const sea = new THREE.Mesh(new THREE.PlaneGeometry(600, 600), new THREE.MeshLambertMaterial({ color: 0x5aa0e6 })); sea.rotation.x = -Math.PI / 2; sea.position.y = -40; scene.add(sea);
    player = avatar(me.color, me.name); scene.add(player.g);
  }
  function avatar(color, name) {
    const g = new THREE.Group(), skin = new THREE.MeshLambertMaterial({ color: 0xf1c27d }), body = new THREE.MeshLambertMaterial({ color }), pants = new THREE.MeshLambertMaterial({ color: 0x2c3e66 });
    const mk = (w, h, d, mat, x, y, z) => { const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat); m.position.set(x, y, z); m.castShadow = true; g.add(m); return m; };
    const head = mk(0.7, 0.7, 0.7, skin, 0, 1.45, 0), torso = mk(0.8, 0.7, 0.4, body, 0, 0.8, 0);
    const la = mk(0.3, 0.7, 0.3, body, -0.55, 0.8, 0), ra = mk(0.3, 0.7, 0.3, body, 0.55, 0.8, 0);
    const ll = mk(0.35, 0.7, 0.35, pants, -0.2, 0.1, 0), rl = mk(0.35, 0.7, 0.35, pants, 0.2, 0.1, 0);
    [la, ra, ll, rl].forEach(m => { m.geometry.translate(0, -0.35, 0); m.position.y += 0.35; });
    // face
    const eye = new THREE.MeshBasicMaterial({ color: 0x222222 });
    [-0.15, 0.15].forEach(x => { const e = new THREE.Mesh(new THREE.BoxGeometry(0.08, 0.1, 0.02), eye); e.position.set(x, 1.5, 0.36); g.add(e); });
    const smile = new THREE.Mesh(new THREE.BoxGeometry(0.26, 0.05, 0.02), eye); smile.position.set(0, 1.32, 0.36); g.add(smile);
    // name tag
    const c = document.createElement('canvas'); c.width = 256; c.height = 64; const x = c.getContext('2d');
    x.font = '700 34px Inter, Arial'; x.textAlign = 'center'; x.fillStyle = 'rgba(0,0,0,.45)'; x.fillRect(0, 8, 256, 48); x.fillStyle = '#fff'; x.fillText(name.slice(0, 14), 128, 44);
    const tag = new THREE.Sprite(new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(c), depthTest: false })); tag.scale.set(2.4, 0.6, 1); tag.position.y = 2.25; g.add(tag);
    return { g, la, ra, ll, rl, head, walk: 0, tx: 0, ty: 0, tz: 0, tr: 0, m: 0 };
  }
  function animate(av, moving, air, dt) {
    if (moving && !air) av.walk += dt * 11; else av.walk += (0 - (av.walk % (Math.PI * 2))) * Math.min(1, dt * 12);
    const s = Math.sin(av.walk) * (moving && !air ? 0.8 : 0), a = air ? -2.6 : 0;
    av.la.rotation.x = a || -s; av.ra.rotation.x = a || s; av.ll.rotation.x = s; av.rl.rotation.x = -s;
  }

  /* ---------- physics ---------- */
  const now = () => performance.now() / 1000;
  function partBox(p) { return { x0: p.x - p.w / 2, x1: p.x + p.w / 2, y0: p.y, y1: p.y + p.h, z0: p.z - p.d / 2, z1: p.z + p.d / 2 }; }
  function solid(p) { return !p.kill && !(p.blink && !p.on); }
  function overlapXZ(b) { return S.x + PW > b.x0 && S.x - PW < b.x1 && S.z + PW > b.z0 && S.z - PW < b.z1; }
  function respawn() {
    const c = cps[S.cp]; S.x = c[0]; S.y = c[1]; S.z = c[2]; S.vx = S.vy = S.vz = 0; S.ground = null; S.spawnAt = now();
    cam.yaw = Math.PI;
  }
  function die() { S.deaths++; hud(); flash(); respawn(); }
  function step(dt) {
    const t = now();
    // moving parts
    for (const p of parts) {
      if (p.move) { const v = Math.sin(t * p.move.speed + p.move.phase) * p.move.amp; p.px = p.x; p.py = p.y; p.pz = p.z; p[p.move.axis] = p[p.move.axis + '0'] + v; p.dx = p.x - p.px; p.dy = p.y - p.py; p.dz = p.z - p.pz; p.mesh.position.set(p.x, p.y + p.h / 2, p.z); }
      if (p.blink) { const k = (t + p.blink.phase) % p.blink.period; p.on = k < p.blink.on; p.mesh.material.opacity = p.on ? (k > p.blink.on - 0.5 ? 0.45 : 1) : 0.08; }
    }
    for (const s of spinners) { s.a += s.speed * dt; s.mesh.rotation.y = s.a; }
    // ride a moving platform
    if (S.ground && S.ground.move) { S.x += S.ground.dx || 0; S.y += S.ground.dy || 0; S.z += S.ground.dz || 0; }
    // input -> velocity (relative to camera)
    let ix = 0, iz = 0;
    if (keys.w) iz += 1; if (keys.s) iz -= 1; if (keys.a) ix -= 1; if (keys.d) ix += 1;
    if (joy) { ix += joy.x; iz -= joy.y; }
    const il = Math.hypot(ix, iz); if (il > 1) { ix /= il; iz /= il; }
    const fy = cam.yaw, fx = -Math.sin(fy), fz = -Math.cos(fy), rx = Math.cos(fy), rz = -Math.sin(fy);   // forward = away from camera
    const wx = (fx * iz + rx * ix) * SPEED, wz = (fz * iz + rz * ix) * SPEED;
    const acc = S.ground ? 18 : 8; S.vx += (wx - S.vx) * Math.min(1, acc * dt); S.vz += (wz - S.vz) * Math.min(1, acc * dt);
    S.moving = il > 0.1; if (S.moving) S.yaw = Math.atan2(wx, wz);
    if (jumpQ && S.ground) { S.vy = JUMP; S.ground = null; } jumpQ = false;
    S.vy -= G * dt; if (S.vy < -40) S.vy = -40;
    if (S.t0 == null && !S.done && (S.moving || S.vy > 0)) S.t0 = t;
    // move + collide, one axis at a time
    const boxes = parts.filter(solid).map(p => (p.b = partBox(p), p));
    S.x += S.vx * dt;
    for (const p of boxes) { const b = p.b; if (!overlapXZ(b) || S.y + PH <= b.y0 || S.y >= b.y1) continue; if (S.vx > 0) S.x = b.x0 - PW; else if (S.vx < 0) S.x = b.x1 + PW; S.vx = 0; }
    S.z += S.vz * dt;
    for (const p of boxes) { const b = p.b; if (!overlapXZ(b) || S.y + PH <= b.y0 || S.y >= b.y1) continue; if (S.vz > 0) S.z = b.z0 - PW; else if (S.vz < 0) S.z = b.z1 + PW; S.vz = 0; }
    S.y += S.vy * dt; S.ground = null;
    for (const p of boxes) { const b = p.b; if (!overlapXZ(b) || S.y + PH <= b.y0 || S.y >= b.y1) continue;
      if (S.vy <= 0 && S.y > b.y1 - 0.6) { S.y = b.y1; S.vy = 0; S.ground = p; } else if (S.vy > 0) { S.y = b.y0 - PH; S.vy = 0; } }
    // hazards
    for (const k of killers) { const b = partBox(k); if (overlapXZ(b) && S.y < b.y1 && S.y + PH > b.y0) return die(); }
    for (const s of spinners) {
      const dx = S.x - s.x, dz = S.z - s.z, lx = dx * Math.cos(s.a) - dz * Math.sin(s.a), lz = dx * Math.sin(s.a) + dz * Math.cos(s.a);
      if (Math.abs(lx) < s.len / 2 + PW && Math.abs(lz) < 0.4 + PW && S.y < s.y + 0.8 && S.y + PH > s.y) return die();
    }
    if (S.y < -25) return die();
    // checkpoints + finish
    if (S.ground && S.ground.cp != null && S.ground.cp > S.cp) { S.cp = S.ground.cp; hud(); toastLocal('Checkpoint ' + S.cp); }
    if (S.ground && S.ground.finish && !S.done) finish(t);
  }
  function finish(t) {
    S.done = true; const secs = S.t0 == null ? 0 : t - S.t0; const prev = S.best;
    if (prev == null || secs < prev) { S.best = secs; try { localStorage.setItem('obby_best', String(secs)); } catch {} }
    hud(); toastLocal(`Finished in ${secs.toFixed(1)}s${prev == null || secs < prev ? ' · new best!' : ''}`);
    send('fin', { secs: +secs.toFixed(1), deaths: S.deaths });
    onHud.finish && onHud.finish(secs, S.deaths);
  }
  function restart() { S.cp = 0; S.deaths = 0; S.t0 = null; S.done = false; respawn(); hud(); }

  /* ---------- camera + input ---------- */
  function updateCam(dt) {
    const tx = S.x, ty = S.y + 1.4, tz = S.z;
    const cx = tx + Math.sin(cam.yaw) * Math.cos(cam.pitch) * cam.dist, cy = ty + Math.sin(cam.pitch) * cam.dist, cz = tz + Math.cos(cam.yaw) * Math.cos(cam.pitch) * cam.dist;
    camera.position.set(cx, Math.max(cy, S.y - 2), cz); camera.lookAt(tx, ty, tz);
    const sun = scene.userData.sun; sun.position.set(S.x + 30, S.y + 60, S.z + 20); sun.target.position.set(S.x, S.y, S.z); sun.target.updateMatrixWorld();
  }
  const KEYMAP = { w: 'w', arrowup: 'w', s: 's', arrowdown: 's', a: 'a', arrowleft: 'a', d: 'd', arrowright: 'd' };
  function onKey(e, down) {
    if (!open || /input|textarea/i.test(e.target.tagName)) return;
    const k = e.key.toLowerCase();
    if (k === ' ') { e.preventDefault(); if (down && !e.repeat) jumpQ = true; return; }
    if (k === 'r' && down) return restart();
    if (KEYMAP[k]) { e.preventDefault(); keys[KEYMAP[k]] = down; }
  }
  function bindInput() {
    window.addEventListener('keydown', e => onKey(e, true)); window.addEventListener('keyup', e => onKey(e, false));
    window.addEventListener('blur', () => { for (const k in keys) keys[k] = false; joy = null; });
    const ptr = {};
    canvas.addEventListener('pointerdown', e => {
      canvas.setPointerCapture(e.pointerId);
      const r = canvas.getBoundingClientRect(), touch = e.pointerType === 'touch';
      if (touch && e.clientX - r.left < r.width * 0.45) { ptr[e.pointerId] = { kind: 'joy', ox: e.clientX, oy: e.clientY }; joy = { x: 0, y: 0 }; showJoy(e.clientX - r.left, e.clientY - r.top, 0, 0); }
      else ptr[e.pointerId] = { kind: 'cam', lx: e.clientX, ly: e.clientY };
    });
    canvas.addEventListener('pointermove', e => {
      const p = ptr[e.pointerId]; if (!p) return;
      if (p.kind === 'joy') { const dx = e.clientX - p.ox, dy = e.clientY - p.oy, l = Math.hypot(dx, dy), m = Math.min(1, l / 45); joy = { x: l ? dx / l * m : 0, y: l ? dy / l * m : 0 }; const r = canvas.getBoundingClientRect(); showJoy(p.ox - r.left, p.oy - r.top, dx, dy); }
      else { cam.yaw -= (e.clientX - p.lx) * 0.006; cam.pitch = Math.max(-0.3, Math.min(1.2, cam.pitch + (e.clientY - p.ly) * 0.005)); p.lx = e.clientX; p.ly = e.clientY; }
    });
    const end = e => { const p = ptr[e.pointerId]; if (!p) return; delete ptr[e.pointerId]; if (p.kind === 'joy') { joy = null; hideJoy(); } };
    canvas.addEventListener('pointerup', end); canvas.addEventListener('pointercancel', end);
    canvas.addEventListener('wheel', e => { e.preventDefault(); cam.dist = Math.max(3, Math.min(14, cam.dist + e.deltaY * 0.01)); }, { passive: false });
    const jb = wrap.querySelector('.obby-jump'); if (jb) { jb.addEventListener('pointerdown', e => { e.preventDefault(); jumpQ = true; }); }
  }
  function showJoy(x, y, dx, dy) { const j = wrap.querySelector('.obby-joy'); if (!j) return; j.hidden = false; j.style.left = x + 'px'; j.style.top = y + 'px'; const l = Math.hypot(dx, dy), m = Math.min(45, l); j.firstElementChild.style.transform = `translate(${l ? dx / l * m : 0}px,${l ? dy / l * m : 0}px)`; }
  function hideJoy() { const j = wrap.querySelector('.obby-joy'); if (j) j.hidden = true; }
  let flashT = 0; function flash() { flashT = now(); }
  function toastLocal(t) { onHud.msg && onHud.msg(t); }
  function hud() { onHud.hud && onHud.hud({ cp: S.cp, stages: cps.length - 1, deaths: S.deaths, best: S.best, players: Object.keys(remote).length + 1 }); }

  /* ---------- multiplayer ---------- */
  function send(ev, payload) { if (ch && joined) ch.send({ type: 'broadcast', event: ev, payload }); }
  function connect() {
    ch = sb.channel('obby', { config: { broadcast: { self: false, ack: false }, presence: { key: me.id } } });
    ch.on('broadcast', { event: 'p' }, ({ payload: p }) => {
      const r = remote[p.id] || add(p.id, p.n, p.c); if (!r) return;
      r.tx = p.x; r.ty = p.y; r.tz = p.z; r.tr = p.r; r.m = p.m; r.air = p.j; r.seen = now();
    });
    ch.on('broadcast', { event: 'fin' }, ({ payload: p }) => { const r = remote[p.id]; toastLocal(`${(r && r.name) || p.n || 'Someone'} finished the obby in ${p.secs}s`); });
    ch.on('presence', { event: 'sync' }, () => {
      const st = ch.presenceState();
      for (const id in st) { if (id === me.id) continue; const info = st[id][0] || {}; if (!remote[id]) add(id, info.name || 'player', info.color || 0x9b5cf6); }
      for (const id in remote) if (!st[id]) drop(id);
      hud();
    });
    ch.subscribe(async status => {
      joined = status === 'SUBSCRIBED';
      if (joined) await ch.track({ name: me.name, color: me.color });
      if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') setTimeout(() => { if (open) reconnect(); }, 1500);
    });
  }
  async function reconnect() { try { joined = false; if (ch) await sb.removeChannel(ch); } catch {} ch = null; if (open) connect(); }
  function add(id, name, color) { const av = avatar(color, name); av.name = name; av.id = id; av.seen = now(); av.tx = 0; av.ty = 1; av.tz = 0; av.g.position.set(0, 1, 0); scene.add(av.g); remote[id] = av; hud(); return av; }
  function drop(id) { const r = remote[id]; if (!r) return; scene.remove(r.g); delete remote[id]; hud(); }
  function netTick(t) {
    const sig = [S.x.toFixed(1), S.y.toFixed(1), S.z.toFixed(1), S.yaw.toFixed(1), S.moving ? 1 : 0, S.ground ? 0 : 1].join(',');
    const rate = sig !== lastSig ? 0.08 : 1.5;
    if (t - lastSend >= rate) { lastSend = t; lastSig = sig; send('p', { id: me.id, n: me.name, c: me.color, x: +S.x.toFixed(2), y: +S.y.toFixed(2), z: +S.z.toFixed(2), r: +S.yaw.toFixed(2), m: S.moving ? 1 : 0, j: S.ground ? 0 : 1 }); }
  }

  /* ---------- loop ---------- */
  let last = 0;
  function frame() {
    if (!open) return; raf = requestAnimationFrame(frame);
    const t = now(), dt = Math.min(0.05, t - (last || t)); last = t;
    // fixed-ish substeps so fast falls don't tunnel through thin beams
    const n = Math.max(1, Math.ceil(dt / (1 / 120))); for (let i = 0; i < n; i++) step(dt / n);
    player.g.position.set(S.x, S.y, S.z); player.g.rotation.y = S.yaw; animate(player, S.moving, !S.ground, dt);
    for (const id in remote) { const r = remote[id]; const f = 1 - Math.exp(-dt * 14);
      r.g.position.x += (r.tx - r.g.position.x) * f; r.g.position.y += (r.ty - r.g.position.y) * f; r.g.position.z += (r.tz - r.g.position.z) * f;
      let d = r.tr - r.g.rotation.y; d = Math.atan2(Math.sin(d), Math.cos(d)); r.g.rotation.y += d * f; animate(r, !!r.m, !!r.air, dt);
      if (t - r.seen > 25) drop(id);
    }
    updateCam(dt); netTick(t);
    if (onHud.timer) onHud.timer(S.done ? null : S.t0 == null ? 0 : t - S.t0);
    const fl = wrap.querySelector('.obby-flash'); if (fl) fl.style.opacity = Math.max(0, 0.55 - (t - flashT) * 2);
    renderer.render(scene, camera);
  }
  function resize() {
    if (!renderer) return;
    const w = wrap.clientWidth, h = wrap.classList.contains('obby-fs') ? window.innerHeight : Math.max(260, Math.min(Math.round(window.innerHeight * 0.72), Math.round(w * 0.62)));
    renderer.setSize(w, h, false); canvas.style.width = w + 'px'; canvas.style.height = h + 'px'; camera.aspect = w / h; camera.updateProjectionMatrix();
  }

  /* ---------- public ---------- */
  async function init(opts) {
    sb = opts.sb; me = opts.me; wrap = opts.wrap; canvas = opts.canvas; Object.assign(onHud, opts.on || {});
    if (!window.THREE) await new Promise((res, rej) => { const s = document.createElement('script'); s.src = 'https://cdn.jsdelivr.net/npm/three@0.150.1/build/three.min.js'; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
    THREE = window.THREE;
    renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2)); renderer.shadowMap.enabled = true; renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    try { const b = parseFloat(localStorage.getItem('obby_best')); if (b > 0) S.best = b; } catch {}
    build(); bindInput(); window.addEventListener('resize', resize); respawn(); hud();
  }
  return {
    async start(opts) { if (!renderer) await init(opts); open = true; last = 0; resize(); if (!ch) connect(); if (!raf) frame(); hud(); },
    stop() { open = false; if (raf) cancelAnimationFrame(raf); raf = null; if (ch) { const c = ch; ch = null; joined = false; sb.removeChannel(c).catch(() => {}); } for (const id in remote) drop(id); },
    resize, restart, state: S
  };
})();
