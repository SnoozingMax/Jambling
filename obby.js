/* Jambling Obby: a 3D obstacle course (three.js) with everyone online shown live through Supabase Realtime. */
window.Obby = (function () {
  const G = 32, JUMP = 13, SPEED = 8, SPRINT = 1.35, PW = 0.4, PH = 1.8;   // gravity, jump speed, run speed, sprint mult, player half-width / height
  let THREE, sb, me, renderer, scene, camera, wrap, canvas, raf = null, open = false, ch = null, joined = false;
  let parts = [], killers = [], spinners = [], discs = [], coins = [], cps = [], stages = [], finishBox = null, player, remote = {}, lastSend = 0, lastSig = '', fx = [], clouds = [];
  const S = { x: 0, y: 1, z: 0, vx: 0, vy: 0, vz: 0, yaw: 0, ground: null, cp: 0, deaths: 0, t0: null, done: false, best: null, moving: false, coins: 0, air: 0, jumpBuf: 0, climb: false, lastGround: null, sprint: false };
  const cam = { yaw: Math.PI, pitch: 0.32, dist: 8, lastDrag: 0 };
  function zoom(d, abs) { cam.dist = Math.max(3, Math.min(16, abs ? d : cam.dist + d)); }
  const keys = {}; let joy = null, jumpQ = false, studTex = null;
  const onHud = {};
  const now = () => performance.now() / 1000;

  /* ---------- course ---------- */
  const C = { spawn: 0x6c8ef5, blockA: 0xf5a66c, blockB: 0xf58f6c, stone: 0x5a5f6e, lava: 0xff3b2f, ice: 0x8fe3ff, beam: 0xf5e36c, purple: 0xa98cf5, white: 0xf5f5f5, grass: 0x58c46a, conveyor: 0x3b3f4a, bounce: 0xff8ad8, truss: 0xd9b36c, gold: 0xe8b23a, pink: 0xff7bb0, teal: 0x4fd1c5, navy: 0x2f3b7a };
  function course() {
    const P = [];
    const box = (x, y, z, w, h, d, o = {}) => { const p = Object.assign({ x, y, z, w, h, d, color: 0x9aa4b2 }, o); P.push(p); return p; };
    const cp = (x, y, z, name) => { box(x, y, z, 6, 1, 6, { color: C.grass, cp: stages.length }); stages.push(name); cps.push([x, y + 1, z]); };
    const coin = (x, y, z) => coins.push({ x, y, z });
    const wall = (x, y, z, w, h, d, o) => box(x, y, z, w, h, d, Object.assign({ color: C.navy }, o));
    // ---- 0 spawn
    box(0, 0, 0, 12, 1, 12, { color: C.spawn }); stages.push('Spawn'); cps.push([0, 1, 0]);
    wall(0, 1, -6, 12, 2, 0.6); wall(-6, 1, 0, 0.6, 2, 12); wall(6, 1, 0, 0.6, 2, 12);
    // ---- 1 jump blocks
    [[1, 7], [-1.2, 11], [1.4, 15], [-1, 19.5], [1.2, 24]].forEach(([x, z], i) => { box(x, 0, z, 2.2, 1, 2.2, { color: i % 2 ? C.blockA : C.blockB }); coin(x, 2.2, z); });
    cp(0, 0, 29, 'Lava Hop');
    // ---- 2 lava field with stepping stones (some sink and rise)
    box(0, -1.2, 46, 24, 0.6, 28, { color: C.lava, kill: true, lava: true });
    [[0, 35, 0], [2.4, 39, 0.3], [-1.5, 43, 0.7], [1.8, 47, 1.0], [-2.2, 51, 1.3], [0.5, 55, 1.6]].forEach(([x, z, y], i) => box(x, y, z, 1.8, 0.6, 1.8, { color: C.stone, move: i === 2 || i === 4 ? { axis: 'y', amp: 0.9, speed: 1.3, phase: i } : null }));
    coin(-1.5, 3.2, 43); coin(-2.2, 3.8, 51);
    cp(0, 1.8, 61, 'Sliders');
    // ---- 3 moving platforms over the void
    box(0, 1.8, 67, 3, 0.6, 3, { color: C.ice, move: { axis: 'x', amp: 4.5, speed: 1.1, phase: 0 } });
    box(0, 1.8, 73, 3, 0.6, 3, { color: C.ice, move: { axis: 'x', amp: 4.5, speed: 1.1, phase: Math.PI } });
    box(0, 1.8, 79, 3, 0.6, 3, { color: C.ice, move: { axis: 'y', amp: 2.2, speed: 1.4, phase: 0 } });
    coin(0, 5, 73);
    cp(0, 1.8, 85, 'Spinner');
    // ---- 4 spinner arena (two bars at different heights)
    box(0, 1.8, 97, 16, 0.6, 16, { color: 0x8d93a6 });
    spinners.push({ x: 0, y: 2.5, z: 97, len: 14, speed: 1.5, a: 0, color: 0xff5a3c });
    spinners.push({ x: 0, y: 4.6, z: 97, len: 14, speed: -0.9, a: 1.2, color: 0xff8a3c, high: true });
    coin(5, 3.4, 97); coin(-5, 3.4, 97);
    cp(0, 1.8, 109, 'Beams');
    // ---- 5 narrow beams with a lava pit under them
    box(3, -2, 124, 16, 0.5, 26, { color: C.lava, kill: true, lava: true });
    box(0, 1.8, 118, 0.7, 0.5, 12, { color: C.beam });
    box(3, 1.8, 124.5, 6.7, 0.5, 0.7, { color: C.beam });
    box(6, 1.8, 131, 0.7, 0.5, 12, { color: C.beam });
    coin(3, 3.2, 124.5);
    cp(6, 1.8, 140, 'Bounce');
    // ---- 6 bounce pads up a cliff
    box(6, 1.8, 146, 3, 0.6, 3, { color: C.bounce, bounce: 19 });
    box(6, 7, 153, 3, 0.6, 3, { color: C.purple });
    box(6, 7, 158, 3, 0.6, 3, { color: C.bounce, bounce: 21 });
    box(6, 13.5, 166, 4, 0.6, 4, { color: C.purple }); coin(6, 15.5, 166);
    cp(6, 13.5, 172, 'Conveyors');
    // ---- 7 conveyor belts pushing sideways over void, then one pushing back
    box(6, 13.5, 180, 3, 0.6, 10, { color: C.conveyor, belt: { x: 3.2, z: 0 }, stripe: true });
    box(6, 13.5, 192, 3, 0.6, 10, { color: C.conveyor, belt: { x: -3.2, z: 0 }, stripe: true });
    box(6, 13.5, 204, 3, 0.6, 10, { color: C.conveyor, belt: { x: 0, z: -4.5 }, stripe: true });   // pushes you backwards: sprint through it
    coin(6, 15.5, 192);
    cp(6, 13.5, 213, 'Climb');
    // ---- 8 truss climb (climbable lattice) up a tall wall
    wall(6, 13.5, 219, 8, 12, 1.2, { color: 0x6a7086 });
    box(6, 13.5, 217.9, 2, 12.6, 1, { color: C.truss, truss: true });
    box(6, 25.5, 222, 8, 0.6, 6, { color: C.purple }); coin(6, 27.5, 222);
    cp(6, 25.5, 229, 'Blink');
    // ---- 9 vanishing blocks
    [[6, 234], [4.5, 238], [7.5, 242], [6, 246], [4.5, 250], [7.5, 254]].forEach(([x, z], i) => box(x, 25.5, z, 2.2, 0.6, 2.2, { color: C.white, blink: { period: 3.2, on: 1.9, phase: i * 0.55 } }));
    coin(6, 27.5, 246);
    cp(6, 25.5, 260, 'Carousel');
    // ---- 10 rotating discs that carry you around
    discs.push({ x: 6, y: 25.5, z: 270, r: 5, h: 0.6, speed: 0.8, a: 0, color: C.teal });
    discs.push({ x: 6, y: 25.5, z: 282, r: 4, h: 0.6, speed: -1.2, a: 0, color: C.pink });
    spinners.push({ x: 6, y: 26.2, z: 282, len: 7, speed: 2.2, a: 0, color: 0xff5a3c });
    coin(6, 28, 270); coin(6, 28, 282);
    cp(6, 25.5, 291, 'Gauntlet');
    // ---- 11 the gauntlet: thin ice blocks + bars + a backwards belt + lava walls
    box(6, 22, 306, 14, 0.5, 24, { color: C.lava, kill: true, lava: true });
    [[6, 297, 0], [8, 301, 0.5], [4, 305, 1], [6, 309, 1.5], [8, 313, 2]].forEach(([x, z, y]) => box(x, 25.5 + y, z, 1.6, 0.5, 1.6, { color: C.ice }));
    spinners.push({ x: 6, y: 26.4, z: 305, len: 9, speed: 2.6, a: 0, color: 0xff5a3c });
    box(6, 28.5, 320, 3, 0.6, 8, { color: C.conveyor, belt: { x: 0, z: -5 }, stripe: true });
    box(6, 28.5, 327, 3, 0.6, 3, { color: C.bounce, bounce: 20 });
    box(6, 34, 335, 4, 0.6, 4, { color: C.purple });
    cp(6, 34, 342, 'Ice Rink');
    // ---- 12 ice rink: slippery, you slide. Don't overshoot the gaps
    [[6, 348, 3, 5], [4, 356, 3, 4], [8.5, 363, 3, 4], [6, 370, 2.5, 4]].forEach(([x, z, w, d]) => box(x, 34, z, w, 0.5, d, { color: C.ice, ice: true }));
    coin(4, 36, 356); coin(8.5, 36, 363);
    cp(6, 34, 377, 'Wind Bridge');
    // ---- 13 wind bridge: a narrow bridge with crosswinds. Lean into it
    box(6, 34, 392, 1.4, 0.5, 24, { color: C.beam });
    box(6, 34, 386, 14, 6, 8, { color: 0x9ad8ff, zone: 'wind', wind: { x: 9, z: 0 } });
    box(6, 34, 398, 14, 6, 8, { color: 0x9ad8ff, zone: 'wind', wind: { x: -9, z: 0 } });
    coin(6, 36, 392);
    cp(6, 34, 408, 'Crumble');
    // ---- 14 crumbling blocks: they drop half a second after you land. Keep moving
    [[6, 413], [4.5, 417], [7.5, 421], [6, 425], [4.5, 429], [7.5, 433], [6, 437]].forEach(([x, z]) => box(x, 34, z, 2.2, 0.6, 2.2, { color: 0xc98a5a, fall: true }));
    coin(6, 36, 425);
    cp(6, 34, 443, 'Moon Jumps');
    // ---- 15 low gravity: huge floaty jumps over huge gaps
    box(6, 34, 465, 30, 14, 50, { color: 0xc9a8ff, zone: 'lowg' });
    [[6, 452], [6, 462], [6, 473], [6, 484]].forEach(([x, z], i) => box(x, 34 + (i % 2) * 2, z, 3, 0.6, 3, { color: C.purple }));
    coin(6, 40, 457); coin(6, 42, 468); coin(6, 42, 479);
    cp(6, 34, 492, 'Cannon Alley');
    // ---- 16 cannon alley: blocks come flying at you down two lanes. Jump them
    box(6, 34, 510, 5, 0.5, 28, { color: 0x8d93a6 });
    box(4.8, 34.5, 520, 1.6, 0.8, 1.6, { color: C.lava, kill: true, cyc: { axis: 'z', from: 497, to: 524, speed: 11, phase: 0 } });
    box(7.2, 34.5, 520, 1.6, 0.8, 1.6, { color: C.lava, kill: true, cyc: { axis: 'z', from: 497, to: 524, speed: 11, phase: 14 } });
    box(6, 34.5, 520, 1.2, 0.8, 1.2, { color: C.lava, kill: true, cyc: { axis: 'z', from: 497, to: 524, speed: 15, phase: 7 } });
    coin(6, 36, 510);
    cp(6, 34, 528, 'Warp');
    // ---- 17 warp pads: step on one to teleport. One of them is a trap
    box(3, 34, 534, 2.2, 0.6, 2.2, { color: C.teal, tp: [6, 46, 548] }); box(9, 34, 534, 2.2, 0.6, 2.2, { color: C.teal, tp: [6, 35, 528] });
    box(6, 45, 548, 6, 1, 6, { color: C.purple }); coin(6, 48, 548);
    box(6, 42, 556, 3, 0.6, 3, { color: C.bounce, bounce: 22 });
    box(6, 48, 565, 4, 0.6, 4, { color: C.purple });
    cp(6, 48, 572, 'Finish');
    // ---- 18 finish
    box(6, 48, 582, 10, 1, 10, { color: C.gold, finish: true }); finishBox = P[P.length - 1];
    [-4, 4].forEach(dx => wall(6 + dx, 49, 582, 0.8, 5, 0.8, { color: C.white }));
    return P;
  }

  /* ---------- textures + scene ---------- */
  function studTexture() {
    const c = document.createElement('canvas'); c.width = c.height = 64; const x = c.getContext('2d');
    x.fillStyle = '#ffffff'; x.fillRect(0, 0, 64, 64);
    x.fillStyle = 'rgba(0,0,0,.10)'; x.beginPath(); x.arc(32, 32, 12, 0, Math.PI * 2); x.fill();
    x.fillStyle = 'rgba(255,255,255,.35)'; x.beginPath(); x.arc(30, 30, 9, 0, Math.PI * 2); x.fill();
    x.strokeStyle = 'rgba(0,0,0,.08)'; x.lineWidth = 2; x.strokeRect(1, 1, 62, 62);
    const t = new THREE.CanvasTexture(c); t.wrapS = t.wrapT = THREE.RepeatWrapping; t.anisotropy = 4; return t;
  }
  function stripeTexture() {
    const c = document.createElement('canvas'); c.width = c.height = 64; const x = c.getContext('2d');
    x.fillStyle = '#3b3f4a'; x.fillRect(0, 0, 64, 64); x.fillStyle = '#f5e36c'; x.fillRect(0, 0, 64, 10);
    const t = new THREE.CanvasTexture(c); t.wrapS = t.wrapT = THREE.RepeatWrapping; return t;
  }
  function matFor(p) {
    if (p.lava) return new THREE.MeshLambertMaterial({ color: p.color, emissive: 0x6a1008 });
    if (p.zone) return new THREE.MeshBasicMaterial({ color: p.color, transparent: true, opacity: 0.12, depthWrite: false });
    if (p.stripe) { const t = stripeTexture(); t.repeat.set(1, p.d / 2); p.tex = t; return new THREE.MeshLambertMaterial({ map: t }); }
    const t = studTex.clone(); t.needsUpdate = true; t.repeat.set(Math.max(1, Math.round(p.w)), Math.max(1, Math.round(p.d)));
    return new THREE.MeshLambertMaterial({ color: p.color, map: t, transparent: !!p.blink || !!p.truss, opacity: p.truss ? 0.85 : 1 });
  }
  function build() {
    scene = new THREE.Scene(); scene.background = new THREE.Color(0x7fc3ff); scene.fog = new THREE.Fog(0x9fd3ff, 70, 220);
    camera = new THREE.PerspectiveCamera(65, 1, 0.1, 500);
    scene.add(new THREE.HemisphereLight(0xdfefff, 0x5f6b7d, 0.55));
    const sun = new THREE.DirectionalLight(0xfff4de, 0.8); sun.castShadow = true;
    sun.shadow.mapSize.set(2048, 2048); Object.assign(sun.shadow.camera, { left: -45, right: 45, top: 45, bottom: -45, near: 1, far: 220 }); sun.shadow.bias = -0.0005;
    scene.add(sun, sun.target); scene.userData.sun = sun;
    studTex = studTexture();
    parts = course();
    const geo = new THREE.BoxGeometry(1, 1, 1);
    for (const p of parts) {
      const m = new THREE.Mesh(geo, matFor(p)); m.scale.set(p.w, p.h, p.d); m.position.set(p.x, p.y + p.h / 2, p.z);
      m.castShadow = !p.lava && !p.zone; m.receiveShadow = !p.zone; scene.add(m); p.mesh = m; p.x0 = p.x; p.y0 = p.y; p.z0 = p.z;
      if (p.cp != null) { const ring = new THREE.Mesh(new THREE.TorusGeometry(2.2, 0.14, 8, 40), new THREE.MeshBasicMaterial({ color: 0xffffff })); ring.rotation.x = Math.PI / 2; ring.position.set(p.x, p.y + p.h + 0.06, p.z); scene.add(ring); p.ring = ring; }
      if (p.bounce) { const top = new THREE.Mesh(new THREE.CylinderGeometry(1, 1.2, 0.3, 24), new THREE.MeshLambertMaterial({ color: 0xffffff })); top.position.set(p.x, p.y + p.h + 0.15, p.z); scene.add(top); p.top = top; }
      if (p.kill) killers.push(p);
      if (p.truss) {   // draw lattice bars on the truss
        const bar = new THREE.MeshLambertMaterial({ color: 0x8c7340 });
        for (let y = 0.6; y < p.h; y += 1.2) { const b = new THREE.Mesh(new THREE.BoxGeometry(p.w, 0.18, p.d + 0.1), bar); b.position.set(p.x, p.y + y, p.z); scene.add(b); }
      }
    }
    for (const s of spinners) {
      const bar = new THREE.Mesh(new THREE.BoxGeometry(s.len, 0.8, 0.8), new THREE.MeshLambertMaterial({ color: s.color })); bar.castShadow = true;
      const hub = new THREE.Mesh(new THREE.CylinderGeometry(0.6, 0.6, 1.6, 16), new THREE.MeshLambertMaterial({ color: 0x3a3548 }));
      bar.position.set(s.x, s.y + 0.4, s.z); hub.position.set(s.x, s.y + 0.4, s.z); scene.add(bar, hub); s.mesh = bar;
    }
    for (const d of discs) {
      const t = studTex.clone(); t.needsUpdate = true; t.repeat.set(d.r * 2, d.r * 2);
      const m = new THREE.Mesh(new THREE.CylinderGeometry(d.r, d.r, d.h, 40), new THREE.MeshLambertMaterial({ color: d.color, map: t })); m.position.set(d.x, d.y + d.h / 2, d.z); m.castShadow = m.receiveShadow = true; scene.add(m); d.mesh = m;
      const post = new THREE.Mesh(new THREE.CylinderGeometry(0.5, 0.7, 6, 12), new THREE.MeshLambertMaterial({ color: 0x3a3548 })); post.position.set(d.x, d.y - 3, d.z); scene.add(post);
    }
    const coinGeo = new THREE.CylinderGeometry(0.45, 0.45, 0.12, 20), coinMat = new THREE.MeshLambertMaterial({ color: 0xffd34d, emissive: 0x5a4300 });
    for (const c of coins) { const m = new THREE.Mesh(coinGeo, coinMat); m.rotation.z = Math.PI / 2; m.position.set(c.x, c.y, c.z); m.castShadow = true; scene.add(m); c.mesh = m; c.got = false; }
    // finish beacon + flag
    const beam = new THREE.Mesh(new THREE.CylinderGeometry(0.5, 0.5, 40, 12, 1, true), new THREE.MeshBasicMaterial({ color: 0xfff1b0, transparent: true, opacity: 0.35, side: THREE.DoubleSide }));
    beam.position.set(finishBox.x, finishBox.y + 20, finishBox.z); scene.add(beam);
    // sky: sun + clouds
    const sunSpr = new THREE.Sprite(new THREE.SpriteMaterial({ map: discTex(255, 240, 200), transparent: true, depthWrite: false })); sunSpr.scale.set(40, 40, 1); sunSpr.position.set(120, 150, -200); scene.add(sunSpr);
    const cloudMat = new THREE.SpriteMaterial({ map: discTex(255, 255, 255), transparent: true, opacity: 0.85, depthWrite: false });
    for (let i = 0; i < 40; i++) { const sp = new THREE.Sprite(cloudMat); const s = 14 + Math.random() * 24; sp.scale.set(s * 1.7, s, 1); sp.position.set((Math.random() - 0.5) * 300, 40 + Math.random() * 50, -40 + Math.random() * 420); scene.add(sp); clouds.push({ sp, v: 0.6 + Math.random() }); }
    // sea far below
    const sea = new THREE.Mesh(new THREE.PlaneGeometry(900, 900), new THREE.MeshLambertMaterial({ color: 0x4f98e3 })); sea.rotation.x = -Math.PI / 2; sea.position.set(0, -40, 170); scene.add(sea);
    player = avatar(me.color, me.name); scene.add(player.g);
  }
  function discTex(r, g, b) {
    const c = document.createElement('canvas'); c.width = c.height = 128; const x = c.getContext('2d');
    const gr = x.createRadialGradient(64, 64, 10, 64, 64, 64); gr.addColorStop(0, `rgba(${r},${g},${b},1)`); gr.addColorStop(0.6, `rgba(${r},${g},${b},.6)`); gr.addColorStop(1, `rgba(${r},${g},${b},0)`);
    x.fillStyle = gr; x.fillRect(0, 0, 128, 128); return new THREE.CanvasTexture(c);
  }
  function avatar(color, name) {
    const g = new THREE.Group(), skin = new THREE.MeshLambertMaterial({ color: 0xf1c27d }), body = new THREE.MeshLambertMaterial({ color }), pants = new THREE.MeshLambertMaterial({ color: 0x2c3e66 });
    const mk = (w, h, d, mat, x, y, z) => { const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat); m.position.set(x, y, z); m.castShadow = true; g.add(m); return m; };
    const head = mk(0.7, 0.7, 0.7, skin, 0, 1.45, 0); mk(0.8, 0.7, 0.4, body, 0, 0.8, 0);
    const la = mk(0.3, 0.7, 0.3, body, -0.55, 0.8, 0), ra = mk(0.3, 0.7, 0.3, body, 0.55, 0.8, 0);
    const ll = mk(0.35, 0.7, 0.35, pants, -0.2, 0.1, 0), rl = mk(0.35, 0.7, 0.35, pants, 0.2, 0.1, 0);
    [la, ra, ll, rl].forEach(m => { m.geometry.translate(0, -0.35, 0); m.position.y += 0.35; });
    const hat = mk(0.8, 0.18, 0.8, new THREE.MeshLambertMaterial({ color: (color ^ 0x7f7f7f) & 0xffffff }), 0, 1.86, 0); mk(0.5, 0.3, 0.5, hat.material, 0, 2.05, 0);
    const eye = new THREE.MeshBasicMaterial({ color: 0x222222 });
    [-0.15, 0.15].forEach(x => { const e = new THREE.Mesh(new THREE.BoxGeometry(0.08, 0.1, 0.02), eye); e.position.set(x, 1.5, 0.36); g.add(e); });
    const smile = new THREE.Mesh(new THREE.BoxGeometry(0.26, 0.05, 0.02), eye); smile.position.set(0, 1.32, 0.36); g.add(smile);
    const c = document.createElement('canvas'); c.width = 256; c.height = 64; const x = c.getContext('2d');
    x.font = '700 34px Inter, Arial'; x.textAlign = 'center'; x.fillStyle = 'rgba(0,0,0,.45)'; x.fillRect(0, 8, 256, 48); x.fillStyle = '#fff'; x.fillText(name.slice(0, 14), 128, 44);
    const tag = new THREE.Sprite(new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(c), depthTest: false })); tag.scale.set(2.4, 0.6, 1); tag.position.y = 2.6; g.add(tag);
    const bubble = new THREE.Sprite(new THREE.SpriteMaterial({ transparent: true, depthTest: false, opacity: 0 })); bubble.scale.set(1.4, 1.4, 1); bubble.position.y = 3.4; g.add(bubble);
    return { g, la, ra, ll, rl, head, bubble, walk: 0, tx: 0, ty: 0, tz: 0, tr: 0, m: 0 };
  }
  function animate(av, moving, air, dt, climb) {
    if (climb) { av.walk += dt * 8; const s = Math.sin(av.walk) * 0.7; av.la.rotation.x = -2.4 + s; av.ra.rotation.x = -2.4 - s; av.ll.rotation.x = -0.6 - s; av.rl.rotation.x = -0.6 + s; return; }
    if (moving && !air) av.walk += dt * 11; else av.walk += (0 - (av.walk % (Math.PI * 2))) * Math.min(1, dt * 12);
    const s = Math.sin(av.walk) * (moving && !air ? 0.8 : 0), a = air ? -2.6 : 0;
    av.la.rotation.x = a || -s; av.ra.rotation.x = a || s; av.ll.rotation.x = air ? 0.5 : s; av.rl.rotation.x = air ? -0.3 : -s;
  }
  function emoteTex(txt) {
    const c = document.createElement('canvas'); c.width = c.height = 128; const x = c.getContext('2d');
    x.fillStyle = '#fff'; x.beginPath(); x.roundRect ? x.roundRect(8, 8, 112, 96, 24) : x.rect(8, 8, 112, 96); x.fill(); x.beginPath(); x.moveTo(52, 102); x.lineTo(76, 102); x.lineTo(64, 122); x.fill();
    x.font = (/^[A-Z]+$/.test(txt) ? '800 44px Inter, Arial' : '72px system-ui, "Apple Color Emoji", "Segoe UI Emoji"'); x.textAlign = 'center'; x.textBaseline = 'middle'; x.fillStyle = '#ff5a3c'; x.fillText(txt, 64, 58);
    return new THREE.CanvasTexture(c);
  }
  function showBubble(av, txt) { av.bubble.material.map = emoteTex(txt); av.bubble.material.opacity = 1; av.bubble.material.needsUpdate = true; av.bubbleT = now(); }

  /* ---------- sounds (tiny WebAudio beeps) ---------- */
  let AC = null;
  function beep(f, d, type, vol) {
    try { AC = AC || new (window.AudioContext || window.webkitAudioContext)(); if (AC.state === 'suspended') AC.resume();
      const o = AC.createOscillator(), g = AC.createGain(); o.type = type || 'square'; o.frequency.value = f; g.gain.value = vol || 0.04;
      o.connect(g); g.connect(AC.destination); o.start(); g.gain.exponentialRampToValueAtTime(0.0001, AC.currentTime + d); o.stop(AC.currentTime + d); } catch {}
  }
  const snd = { jump: () => beep(420, 0.12, 'square', 0.03), coin: () => { beep(1200, 0.08, 'sine', 0.05); setTimeout(() => beep(1600, 0.12, 'sine', 0.05), 70); }, die: () => beep(110, 0.35, 'sawtooth', 0.05), cp: () => { beep(660, 0.1, 'triangle', 0.05); setTimeout(() => beep(990, 0.18, 'triangle', 0.05), 100); }, bounce: () => beep(300, 0.2, 'sine', 0.05), win: () => [0, 120, 240, 360].forEach((t, i) => setTimeout(() => beep([523, 659, 784, 1047][i], 0.25, 'triangle', 0.06), t)) };

  /* ---------- physics ---------- */
  function partBox(p) { return { x0: p.x - p.w / 2, x1: p.x + p.w / 2, y0: p.y, y1: p.y + p.h, z0: p.z - p.d / 2, z1: p.z + p.d / 2 }; }
  function solid(p) { return !p.kill && !p.truss && !p.zone && !p.gone && !(p.blink && !p.on); }
  function overlapXZ(b, pad = 0) { return S.x + PW + pad > b.x0 && S.x - PW - pad < b.x1 && S.z + PW + pad > b.z0 && S.z - PW - pad < b.z1; }
  function respawn() {
    const c = cps[S.cp]; S.x = c[0]; S.y = c[1]; S.z = c[2]; S.vx = S.vy = S.vz = 0; S.ground = null; S.climb = false;
    cam.yaw = Math.PI; cam.lastDrag = 0;
  }
  function die() { S.deaths++; hud(); flash(); burst(S.x, S.y + 1, S.z, 0xff5a3c, 14); snd.die(); send('d', {}); respawn(); }
  function step(dt) {
    simT += dt; const t = simT;
    for (const p of parts) {   // moving / blinking parts
      if (p.move) { const v = Math.sin(t * p.move.speed + p.move.phase) * p.move.amp; const o = p[p.move.axis]; p[p.move.axis] = p[p.move.axis + '0'] + v; p['d' + p.move.axis] = p[p.move.axis] - o; p['v' + p.move.axis] = Math.cos(t * p.move.speed + p.move.phase) * p.move.amp * p.move.speed; p.mesh.position.set(p.x, p.y + p.h / 2, p.z); }
      if (p.blink) { const k = (t + p.blink.phase) % p.blink.period; p.on = k < p.blink.on; p.mesh.material.opacity = p.on ? (k > p.blink.on - 0.5 ? 0.45 : 1) : 0.08; }
      if (p.tex && p.belt) p.tex.offset.y -= p.belt.z * dt * 0.08 || p.belt.x * dt * 0.08;
      if (p.cyc) { const c = p.cyc, len = c.to - c.from; p[c.axis] = c.to - ((t * c.speed + c.phase) % len); p.mesh.position.set(p.x, p.y + p.h / 2, p.z); }
      if (p.fall && p.fallT != null) { const age = t - p.fallT;
        if (age < 0.5) p.mesh.position.x = p.x + Math.sin(age * 70) * 0.08;
        else if (age < 3) { p.gone = true; p.mesh.position.set(p.x, p.y0 + p.h / 2 - (age - 0.5) * 9, p.z); p.mesh.material.opacity = 1; }
        else { p.fallT = null; p.gone = false; p.mesh.position.set(p.x, p.y + p.h / 2, p.z); } }
    }
    for (const s of spinners) { s.a += s.speed * dt; s.mesh.rotation.y = s.a; }
    for (const d of discs) { d.a += d.speed * dt; d.mesh.rotation.y = d.a; }
    // carried by what I'm standing on
    const g = S.ground;
    if (g && g.move) { S.x += g.dx || 0; S.z += g.dz || 0; S.y = g.y + g.h; }   // ride it (snap to its top: no float drift)
    if (g && g.belt) { S.x += g.belt.x * dt; S.z += g.belt.z * dt; }
    if (g && g.disc) { const dx = S.x - g.x, dz = S.z - g.z, a = g.speed * dt; S.x = g.x + dx * Math.cos(a) - dz * Math.sin(a); S.z = g.z + dx * Math.sin(a) + dz * Math.cos(a); }
    // input -> wanted velocity (relative to camera)
    let ix = 0, iz = 0;
    if (keys.w) iz += 1; if (keys.s) iz -= 1; if (keys.a) ix -= 1; if (keys.d) ix += 1;
    if (joy) { ix += joy.x; iz -= joy.y; }
    const il = Math.hypot(ix, iz); if (il > 1) { ix /= il; iz /= il; }
    const fy = cam.yaw, fx = -Math.sin(fy), fz = -Math.cos(fy), rx = Math.cos(fy), rz = -Math.sin(fy);
    const sp = SPEED * (S.sprint ? SPRINT : 1), wx = (fx * iz + rx * ix) * sp, wz = (fz * iz + rz * ix) * sp;
    let gMul = 1;
    for (const z of parts) if (z.zone) { const b = partBox(z); if (overlapXZ(b) && S.y + PH > b.y0 && S.y < b.y1) { if (z.wind) { S.vx += z.wind.x * dt; S.vz += z.wind.z * dt; } if (z.zone === 'lowg') gMul = 0.4; } }
    const acc = S.ground ? (S.ground.ice ? 1.6 : 20) : 7; S.vx += (wx - S.vx) * Math.min(1, acc * dt); S.vz += (wz - S.vz) * Math.min(1, acc * dt);
    S.moving = il > 0.1; if (S.moving) S.yaw = Math.atan2(wx, wz);
    // trusses: hug one and push into it to climb
    S.climb = false;
    for (const p of parts) if (p.truss) { const b = partBox(p); if (overlapXZ(b, 0.35) && S.y + PH > b.y0 && S.y < b.y1 - 0.2) { const toward = (p.z - S.z) * (fz * iz + rz * ix) + (p.x - S.x) * (fx * iz + rx * ix); if (toward > 0.05 || keys.w) { S.climb = true; S.vy = 5.5; S.vx *= 0.5; S.vz *= 0.5; } else if (S.vy < 0) S.vy = -1.5; } }
    // jump: coyote time + jump buffer
    if (S.ground) S.air = 0; else S.air += dt;
    if (jumpQ) { S.jumpBuf = 0.12; jumpQ = false; }
    if (S.jumpBuf > 0) { S.jumpBuf -= dt; if (S.ground || S.air < 0.1 || S.climb) { const wasClimb = S.climb, g0 = S.ground; S.vy = JUMP; if (g0 && g0.move) { S.vx += g0.vx || 0; S.vz += g0.vz || 0; if ((g0.vy || 0) > 0) S.vy += g0.vy; } if (g0 && g0.belt) { S.vx += g0.belt.x; S.vz += g0.belt.z; } S.ground = null; S.air = 1; S.jumpBuf = 0; S.climb = false; snd.jump(); if (wasClimb) { S.vz -= fz * 3; S.vx -= fx * 3; } } }
    if (!S.climb) S.vy -= G * gMul * dt; if (S.vy < -45) S.vy = -45;
    if (S.t0 == null && !S.done && (S.moving || S.vy > 0)) S.t0 = t;
    // move + collide, one axis at a time
    const boxes = parts.filter(solid).map(p => (p.b = partBox(p), p));
    for (const d of discs) { d.b = { x0: d.x - d.r, x1: d.x + d.r, y0: d.y, y1: d.y + d.h, z0: d.z - d.r, z1: d.z + d.r }; d.disc = true; }
    const onDisc = d => Math.hypot(S.x - d.x, S.z - d.z) < d.r + PW * 0.5;
    S.x += S.vx * dt;
    for (const p of boxes) { const b = p.b; if (!overlapXZ(b) || S.y + PH <= b.y0 || S.y >= b.y1 - 0.08) continue; S.x = (S.vx > 0 || (S.vx === 0 && S.x < p.x)) ? b.x0 - PW : b.x1 + PW; S.vx = 0; }
    S.z += S.vz * dt;
    for (const p of boxes) { const b = p.b; if (!overlapXZ(b) || S.y + PH <= b.y0 || S.y >= b.y1 - 0.08) continue; S.z = (S.vz > 0 || (S.vz === 0 && S.z < p.z)) ? b.z0 - PW : b.z1 + PW; S.vz = 0; }
    S.y += S.vy * dt; S.ground = null;
    for (const p of boxes) { const b = p.b; if (!overlapXZ(b) || S.y + PH <= b.y0 || S.y >= b.y1) continue;
      if (S.vy <= 0 && S.y > b.y1 - 0.9) { S.y = b.y1; S.vy = 0; S.ground = p; } else if (S.vy > 0 && S.y + PH < b.y0 + 0.5) { S.y = b.y0 - PH; S.vy = 0; } else { S.y = b.y1; S.vy = 0; S.ground = p; } }
    for (const d of discs) { if (!onDisc(d) || S.y + PH <= d.y || S.y >= d.y + d.h) continue; if (S.vy <= 0 && S.y > d.y + d.h - 0.7) { S.y = d.y + d.h; S.vy = 0; S.ground = d; } }
    if (S.ground && S.ground.fall && S.ground.fallT == null) S.ground.fallT = t;
    if (S.ground && S.ground.tp) { const [tx, ty, tz] = S.ground.tp; burst(S.x, S.y + 1, S.z, 0x4fd1c5, 12); S.x = tx; S.y = ty; S.z = tz; S.vx = S.vz = 0; S.vy = 2; S.ground = null; burst(tx, ty + 1, tz, 0x4fd1c5, 12); snd.cp(); toastLocal('Warped!'); }
    if (S.ground && S.ground.bounce) { S.vy = S.ground.bounce; S.ground.top.scale.y = 0.4; S.ground = null; S.air = 1; snd.bounce(); burst(S.x, S.y, S.z, 0xff8ad8, 8); }
    for (const p of parts) if (p.top && p.top.scale.y < 1) p.top.scale.y = Math.min(1, p.top.scale.y + dt * 3);
    // hazards
    for (const k of killers) { const b = partBox(k); if (overlapXZ(b) && S.y < b.y1 && S.y + PH > b.y0) return die(); }
    for (const s of spinners) {
      const dx = S.x - s.x, dz = S.z - s.z, lx = dx * Math.cos(s.a) - dz * Math.sin(s.a), lz = dx * Math.sin(s.a) + dz * Math.cos(s.a);
      if (Math.abs(lx) < s.len / 2 + PW && Math.abs(lz) < 0.4 + PW && S.y < s.y + 0.8 && S.y + PH > s.y) return die();
    }
    if (S.y < -30) return die();
    // coins
    for (const c of coins) { if (c.got) continue; c.mesh.rotation.y += dt * 3; c.mesh.position.y = c.y + Math.sin(t * 3 + c.x) * 0.15; if (Math.hypot(S.x - c.x, S.z - c.z) < 1 && Math.abs(S.y + 0.9 - c.y) < 1.4) { c.got = true; c.mesh.visible = false; S.coins++; snd.coin(); burst(c.x, c.y, c.z, 0xffd34d, 8); hud(); } }
    // checkpoints + finish
    if (S.ground && S.ground.cp != null && S.ground.cp > S.cp) { S.cp = S.ground.cp; hud(); snd.cp(); toastLocal(`Checkpoint · ${stages[S.cp]}`); burst(S.x, S.y, S.z, 0x58c46a, 10); }
    if (S.ground && S.ground.finish && !S.done) finish(t);
  }
  function finish(t) {
    S.done = true; const secs = S.t0 == null ? 0 : t - S.t0; const prev = S.best;
    if (prev == null || secs < prev) { S.best = secs; try { localStorage.setItem('obby_best', String(secs)); } catch {} }
    hud(); snd.win(); toastLocal(`Finished in ${secs.toFixed(1)}s${prev == null || secs < prev ? ' · new best!' : ''}`);
    for (let i = 0; i < 6; i++) setTimeout(() => burst(S.x + (Math.random() - 0.5) * 6, S.y + 2 + Math.random() * 4, S.z + (Math.random() - 0.5) * 6, [0xff5a3c, 0xffd34d, 0x58c46a, 0x6fd3ff, 0xff7bb0][i % 5], 16, 1.8), i * 220);
    send('fin', { secs: +secs.toFixed(1), deaths: S.deaths });
    onHud.finish && onHud.finish(secs, S.deaths, S.coins);
  }
  function restart() { for (const p of parts) if (p.fall) { p.fallT = null; p.gone = false; p.mesh.position.set(p.x, p.y + p.h / 2, p.z); } S.cp = 0; S.deaths = 0; S.coins = 0; S.t0 = null; S.done = false; for (const c of coins) { c.got = false; c.mesh.visible = true; } respawn(); hud(); }

  /* ---------- effects ---------- */
  const fxGeo = () => new THREE.BoxGeometry(0.22, 0.22, 0.22);
  function burst(x, y, z, color, n, life = 0.8) {
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true });
    for (let i = 0; i < n; i++) { const m = new THREE.Mesh(fxGeo(), mat); m.position.set(x, y, z); scene.add(m);
      fx.push({ m, vx: (Math.random() - 0.5) * 9, vy: 3 + Math.random() * 7, vz: (Math.random() - 0.5) * 9, t: now(), life, mat }); }
  }
  function fxTick(dt) {
    const t = now();
    fx = fx.filter(f => { const k = (t - f.t) / f.life; if (k >= 1) { scene.remove(f.m); return false; } f.vy -= 20 * dt; f.m.position.x += f.vx * dt; f.m.position.y += f.vy * dt; f.m.position.z += f.vz * dt; f.m.rotation.x += dt * 6; f.m.rotation.z += dt * 4; f.mat.opacity = 1 - k; return true; });
  }
  let flashT = 0; function flash() { flashT = now(); }
  function toastLocal(t) { onHud.msg && onHud.msg(t); }
  function hud() { onHud.hud && onHud.hud({ cp: S.cp, stages: stages.length - 1, stage: stages[S.cp], deaths: S.deaths, best: S.best, players: Object.keys(remote).length + 1, coins: S.coins, totalCoins: coins.length }); }

  /* ---------- camera + input ---------- */
  function updateCam(dt) {
    const t = now();
    const tx = S.x, ty = S.y + 1.5, tz = S.z;
    let cx = tx + Math.sin(cam.yaw) * Math.cos(cam.pitch) * cam.dist, cy = ty + Math.sin(cam.pitch) * cam.dist, cz = tz + Math.cos(cam.yaw) * Math.cos(cam.pitch) * cam.dist;
    // keep the camera out of walls: pull it in if a solid part sits between it and the player
    for (const p of parts) { if (!solid(p) || p.h < 1.5) continue; const b = partBox(p); if (cx > b.x0 && cx < b.x1 && cz > b.z0 && cz < b.z1 && cy > b.y0 && cy < b.y1) { cx = tx + (cx - tx) * 0.4; cz = tz + (cz - tz) * 0.4; cy = ty + (cy - ty) * 0.4; } }
    camera.position.set(cx, Math.max(cy, S.y - 2), cz); camera.lookAt(tx, ty, tz);
    const sun = scene.userData.sun; sun.position.set(S.x + 25, S.y + 60, S.z + 15); sun.target.position.set(S.x, S.y, S.z);
  }
  const KEYMAP = { w: 'w', arrowup: 'w', s: 's', arrowdown: 's', a: 'a', arrowleft: 'a', d: 'd', arrowright: 'd' };
  function onKey(e, down) {
    if (!open || /input|textarea|select/i.test(e.target.tagName)) return;
    const k = e.key.toLowerCase();
    if (k === ' ') { e.preventDefault(); if (down && !e.repeat) jumpQ = true; return; }
    if (down && (k === '-' || k === '=' || k === '+')) { zoom(k === '-' ? 1.5 : -1.5); return; }
    if (k === 'shift') { S.sprint = down; return; }
    if (k === 'r' && down) return restart();
    if (down && /^[1-8]$/.test(k) && onHud.emote) return onHud.emote(+k - 1);
    if (KEYMAP[k]) { e.preventDefault(); keys[KEYMAP[k]] = down; }
  }
  function bindInput() {
    window.addEventListener('keydown', e => onKey(e, true)); window.addEventListener('keyup', e => onKey(e, false));
    window.addEventListener('blur', () => { for (const k in keys) keys[k] = false; joy = null; S.sprint = false; });
    const ptr = {};
    canvas.addEventListener('pointerdown', e => {
      try { canvas.setPointerCapture(e.pointerId); } catch {}
      const r = canvas.getBoundingClientRect(), touch = e.pointerType === 'touch';
      if (touch && e.clientX - r.left < r.width * 0.45) { ptr[e.pointerId] = { kind: 'joy', ox: e.clientX, oy: e.clientY }; joy = { x: 0, y: 0 }; showJoy(e.clientX - r.left, e.clientY - r.top, 0, 0); }
      else ptr[e.pointerId] = { kind: 'cam', lx: e.clientX, ly: e.clientY };
    });
    const pinch = { ids: null, d0: 0, dist0: 0 };
    const pinchDist = () => { const [a, b] = pinch.ids.map(id => ptr[id]); return Math.hypot(a.lx - b.lx, a.ly - b.ly); };
    canvas.addEventListener('pointermove', e => {
      const p = ptr[e.pointerId]; if (!p) return;
      if (p.kind === 'cam') { p.lx2 = e.clientX; p.ly2 = e.clientY;
        const cams = Object.keys(ptr).filter(id => ptr[id].kind === 'cam');
        if (cams.length >= 2) {   // two fingers on the view: pinch to zoom
          if (!pinch.ids) { pinch.ids = cams.slice(0, 2); pinch.ids.forEach(id => { ptr[id].lx = ptr[id].lx2 ?? ptr[id].lx; ptr[id].ly = ptr[id].ly2 ?? ptr[id].ly; }); pinch.d0 = pinchDist(); pinch.dist0 = cam.dist; }
          p.lx = e.clientX; p.ly = e.clientY; const d = pinchDist(); if (pinch.d0 > 10 && d > 10) zoom(pinch.dist0 * pinch.d0 / d, true); p.pinched = true; return;
        }
      }
      if (p.kind === 'joy') { const dx = e.clientX - p.ox, dy = e.clientY - p.oy, l = Math.hypot(dx, dy), m = Math.min(1, l / 45); joy = { x: l ? dx / l * m : 0, y: l ? dy / l * m : 0 }; S.sprint = l > 60; const r = canvas.getBoundingClientRect(); showJoy(p.ox - r.left, p.oy - r.top, dx, dy); }
      else { cam.yaw -= (e.clientX - p.lx) * 0.006; cam.pitch = Math.max(-0.3, Math.min(1.25, cam.pitch + (e.clientY - p.ly) * 0.005)); p.lx = e.clientX; p.ly = e.clientY; cam.lastDrag = now(); }
    });
    const end = e => { const p = ptr[e.pointerId]; if (!p) return; delete ptr[e.pointerId]; if (pinch.ids && pinch.ids.includes(String(e.pointerId))) pinch.ids = null; if (p.kind === 'joy') { joy = null; S.sprint = false; hideJoy(); } };
    canvas.addEventListener('pointerup', end); canvas.addEventListener('pointercancel', end);
    canvas.addEventListener('wheel', e => { e.preventDefault(); zoom(cam.dist + e.deltaY * 0.01, true); }, { passive: false });
    for (const [sel, dz] of [['.g3-zin', -1.5], ['.g3-zout', 1.5]]) { const zb = wrap.querySelector(sel); if (zb) zb.addEventListener('click', () => zoom(cam.dist + dz, true)); }
    const jb = wrap.querySelector('.obby-jump'); if (jb) jb.addEventListener('pointerdown', e => { e.preventDefault(); jumpQ = true; });
  }
  function showJoy(x, y, dx, dy) { const j = wrap.querySelector('.obby-joy'); if (!j) return; j.hidden = false; j.style.left = x + 'px'; j.style.top = y + 'px'; const l = Math.hypot(dx, dy), m = Math.min(45, l); j.firstElementChild.style.transform = `translate(${l ? dx / l * m : 0}px,${l ? dy / l * m : 0}px)`; }
  function hideJoy() { const j = wrap.querySelector('.obby-joy'); if (j) j.hidden = true; }

  /* ---------- multiplayer ---------- */
  function send(ev, payload) { if (ch && joined) ch.send({ type: 'broadcast', event: ev, payload: Object.assign({ id: me.id }, payload) }); }
  function connect() {
    ch = sb.channel('obby', { config: { broadcast: { self: false, ack: false }, presence: { key: me.id } } });
    ch.on('broadcast', { event: 'p' }, ({ payload: p }) => {
      const r = remote[p.id] || add(p.id, p.n, p.c); if (!r) return;
      r.tx = p.x; r.ty = p.y; r.tz = p.z; r.tr = p.r; r.m = p.m; r.air = p.j; r.climb = p.k; r.seen = now();
    });
    ch.on('broadcast', { event: 'fin' }, ({ payload: p }) => { const r = remote[p.id]; toastLocal(`${(r && r.name) || 'Someone'} finished in ${p.secs}s`); if (r) for (let i = 0; i < 3; i++) setTimeout(() => burst(r.g.position.x, r.g.position.y + 2, r.g.position.z, 0xffd34d, 12, 1.5), i * 200); });
    ch.on('broadcast', { event: 'd' }, ({ payload: p }) => { const r = remote[p.id]; if (r) burst(r.g.position.x, r.g.position.y + 1, r.g.position.z, 0xff5a3c, 10); });
    ch.on('broadcast', { event: 'e' }, ({ payload: p }) => { const r = remote[p.id]; if (r) showBubble(r, p.t); });
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
    const sig = [S.x.toFixed(1), S.y.toFixed(1), S.z.toFixed(1), S.yaw.toFixed(1), S.moving ? 1 : 0, S.ground ? 0 : 1, S.climb ? 1 : 0].join(',');
    const rate = sig !== lastSig ? 0.08 : 1.5;
    if (t - lastSend >= rate) { lastSend = t; lastSig = sig; send('p', { n: me.name, c: me.color, x: +S.x.toFixed(2), y: +S.y.toFixed(2), z: +S.z.toFixed(2), r: +S.yaw.toFixed(2), m: S.moving ? 1 : 0, j: S.ground ? 0 : 1, k: S.climb ? 1 : 0 }); }
  }
  let lastEmote = 0;
  function emote(txt) { const t = now(); if (t - lastEmote < 1) return; lastEmote = t; showBubble(player, txt); send('e', { t: txt }); }

  /* ---------- loop ---------- */
  let last = 0, simT = 0;
  function frame() {
    if (!open) return; raf = requestAnimationFrame(frame);
    const t = now(), dt = Math.min(0.1, t - (last || t)); last = t;
    const n = Math.max(1, Math.ceil(dt / (1 / 120))); for (let i = 0; i < n; i++) step(dt / n);
    player.g.position.set(S.x, S.y, S.z); player.g.rotation.y = S.yaw; animate(player, S.moving, !S.ground, dt, S.climb);
    for (const id in remote) { const r = remote[id]; const f = 1 - Math.exp(-dt * 14);
      r.g.position.x += (r.tx - r.g.position.x) * f; r.g.position.y += (r.ty - r.g.position.y) * f; r.g.position.z += (r.tz - r.g.position.z) * f;
      let d = r.tr - r.g.rotation.y; d = Math.atan2(Math.sin(d), Math.cos(d)); r.g.rotation.y += d * f; animate(r, !!r.m, !!r.air, dt, !!r.climb);
      if (t - r.seen > 25) drop(id);
    }
    for (const av of [player, ...Object.values(remote)]) if (av.bubbleT && t - av.bubbleT > 2.2) { av.bubble.material.opacity = 0; av.bubbleT = 0; }
    for (const p of parts) if (p.ring) p.ring.rotation.z += dt * (p.cp === S.cp ? 2 : 0.5);
    for (const c of clouds) { c.sp.position.x += c.v * dt; if (c.sp.position.x > 160) c.sp.position.x = -160; }
    fxTick(dt); updateCam(dt); netTick(t);
    if (onHud.timer) onHud.timer(S.done ? null : S.t0 == null ? 0 : simT - S.t0);
    const fl = wrap.querySelector('.obby-flash'); if (fl) fl.style.opacity = Math.max(0, 0.55 - (t - flashT) * 2);
    renderer.render(scene, camera);
  }
  function resize() {
    if (!renderer) return;
    canvas.style.width = '100%'; canvas.style.height = '';   // let the layout settle before measuring (a wide canvas would hold the column open)
    const w = wrap.clientWidth, h = wrap.classList.contains('obby-fs') ? window.innerHeight : Math.max(260, Math.min(Math.round(window.innerHeight * 0.72), Math.round(w * 0.6)));
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
    resize, restart, emote, state: S, stages, parts: () => parts
  };
})();
