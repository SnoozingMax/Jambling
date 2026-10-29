/* Jambling Chameleon: 1v1 hide & seek in a 3D map (three.js). The hider paints themselves to match the map and poses;
   the hunter has a shotgun and a minute to find them. Each player hides once. */
window.Hide = (function () {
  const G = 32, JUMP = 10.5, SPEED = 8, PW = 0.4, PH = 1.8, AMMO = 8, RELOAD = 0.9, RANGE = 32, SPREAD = 0.045, PELLETS = 7;
  let THREE, sb, me, renderer, scene, camera, wrap, canvas, raf = null, open = false, ch = null, joined = false, studTex = null;
  let parts = [], roofs = [], mapMeshes = [], player, opp = null, fx = [], smokes = [], decoys = [], clouds = [], lastSend = 0, lastSig = '';
  const S = { x: 0, y: 0, z: 0, vx: 0, vy: 0, vz: 0, yaw: 0, ground: null, moving: false, air: 0, jumpBuf: 0, frozenUntil: 0, pose: 'stand', color: null, ammo: AMMO, shotAt: 0 };
  const M = { id: null, oppName: '', hider: false, phase: null, round: 0, secs: 0, items: [], used: {}, caughtSent: 0, key: '', tauntAt: 0 };
  let pings = [];
  const cam = { yaw: Math.PI, pitch: 0.3, dist: 7 };
  function zoom(d, abs) { cam.dist = Math.max(2, Math.min(14, abs ? d : cam.dist + d)); }
  const keys = {}; let joy = null, jumpQ = false, fireQ = false;
  const onHud = {};
  const now = () => performance.now() / 1000;
  const ITEMS = { freeze: { name: 'Freeze', icon: '❄️', secs: 4, desc: 'Freezes the hunter in place for 4 seconds' }, smoke: { name: 'Smoke bomb', icon: '💨', secs: 9, desc: 'A cloud nobody can see into for 9 seconds' }, decoy: { name: 'Decoy', icon: '🪆', secs: 0, desc: 'Drops a painted copy of you. Costs the hunter a shell to find out' } };
  const POSES = ['stand', 'crouch', 'prone', 'curl'];
  const POSE_LABEL = { stand: '🧍 Stand', crouch: '🧎 Crouch', prone: '🛌 Lie flat', curl: '🪨 Curl up' };

  /* ---------- map ---------- */
  const C = { grass: 0x6fbf73, grass2: 0x62b066, road: 0x8d93a6, line: 0xe8e2c8, fence: 0x5a6075, roof: 0x4b4f5c, roofR: 0x9b3b32, crate: 0xd9b36c, hedge: 0x3f9a4b, tunnel: 0x6a7086,
    carR: 0xe8453c, carB: 0x3c6fe8, carY: 0xf2c94c, carW: 0xf2f2f2, carG: 0x2f7d4a, glass: 0x9ad8ff, bin: 0x2f7d4a, sign: 0x2a2635, trunk: 0x7a5230, leaf: 0x3fa34d, leaf2: 0x2e8a3d, stone: 0x7f8aa8, water: 0x55c0ff,
    barrel: 0x8a5a2b, barrelB: 0x3a6fb0, flower: 0xff6fa5, flowerY: 0xffd34d, rock: 0x6e6e78, sand: 0xe3cf8f, pipe: 0x3d7a8f, plank: 0xb98a4a, brick: 0xb0533d, court: 0xe08a3c, courtLine: 0xffffff,
    awnR: 0xd94040, awnB: 0x3b6fd1, awnG: 0x2f9e5b, awnY: 0xe6b422, wood: 0x9a6b3c, lamp: 0x3a3548, bleacher: 0x6b7a99, vending: 0xd8393f, vending2: 0x2f7fd8, mailbox: 0x2f5fa8, dog: 0xc9743a,
    h1: 0xf5b86c, h2: 0xf58f6c, h3: 0x9c7ef0, h4: 0x6cc6f5, h5: 0xff7bb0, h6: 0x4fd1c5, h7: 0xf0e68c, h8: 0xb8d8a0 };
  function mapParts() {
    const P = [];
    const box = (x, y, z, w, h, d, color, o = {}) => { const p = Object.assign({ x, y, z, w, h, d, color }, o); P.push(p); return p; };
    const deco = (x, y, z, w, h, d, color, o = {}) => box(x, y, z, w, h, d, color, Object.assign({ plain: true }, o));
    // ground: grass with a cross of roads, dashed center lines, a ring sidewalk around the plaza
    box(0, -1, 0, 80, 1, 80, C.grass, { ground: true });
    [[-26, -26], [26, 26], [-26, 26], [26, -26]].forEach(([x, z]) => box(x, -0.995, z, 22, 1, 22, C.grass2, { ground: true }));
    box(0, -0.98, 0, 8, 1, 80, C.road, { ground: true, plain: true }); box(0, -0.98, 0, 80, 1, 8, C.road, { ground: true, plain: true });
    for (let z = -36; z <= 36; z += 6) if (Math.abs(z) > 6) deco(0, -0.975, z, 0.3, 1, 2.4, C.line, { ground: true });
    for (let x = -36; x <= 36; x += 6) if (Math.abs(x) > 6) deco(x, -0.975, 0, 2.4, 1, 0.3, C.line, { ground: true });
    box(0, -0.97, 0, 14, 1, 14, C.stone, { ground: true, plain: true });
    // fence with pillars
    [[0, -40], [0, 40]].forEach(([x, z]) => box(x, 0, z, 81, 3.5, 1, C.fence)); [[-40, 0], [40, 0]].forEach(([x, z]) => box(x, 0, z, 1, 3.5, 81, C.fence));
    for (let i = -40; i <= 40; i += 10) { box(i, 0, -40, 1.6, 4.2, 1.6, C.stone); box(i, 0, 40, 1.6, 4.2, 1.6, C.stone); box(-40, 0, i, 1.6, 4.2, 1.6, C.stone); box(40, 0, i, 1.6, 4.2, 1.6, C.stone); }
    // plaza: fountain, benches, lamp posts
    box(0, 0, 0, 5, 0.9, 5, C.stone, { plain: true }); deco(0, 0.9, 0, 3.6, 0.25, 3.6, C.water); box(0, 0, 0, 1, 2.6, 1, C.stone, { plain: true });
    [[-5, 0, 0.6, 2.4], [5, 0, 0.6, 2.4], [0, -5, 2.4, 0.6], [0, 5, 2.4, 0.6]].forEach(([x, z, w, d]) => { box(x, 0, z, w, 0.5, d, C.wood); box(x, 0.5, z, w, 0.5, d, C.wood, { plain: true }); });
    [[-6, -6], [6, -6], [-6, 6], [6, 6]].forEach(([x, z]) => { box(x, 0, z, 0.3, 4, 0.3, C.lamp); deco(x, 4, z, 0.8, 0.5, 0.8, C.flowerY); });
    const house = (cx, cz, color, door, roofC) => {   // hollow house: 8x8, 3.2 high walls, door, windows, chimney, flat roof you can stand on
      const w = 8, h = 3.2, t = 0.4;
      const sides = { n: [cx, cz - w / 2, w, t], s: [cx, cz + w / 2, w, t], w: [cx - w / 2, cz, t, w], e: [cx + w / 2, cz, t, w] };
      for (const k in sides) { const [x, z, ww, dd] = sides[k];
        if (k !== door) { box(x, 0, z, ww, h, dd, color);
          if (ww > dd) { deco(x - 2, 1.3, z, 1.3, 1.1, dd + 0.08, C.glass); deco(x + 2, 1.3, z, 1.3, 1.1, dd + 0.08, C.glass); } else { deco(x, 1.3, z - 2, ww + 0.08, 1.1, 1.3, C.glass); deco(x, 1.3, z + 2, ww + 0.08, 1.1, 1.3, C.glass); } }
        else if (ww > dd) { box(x - 2.5, 0, z, 3, h, dd, color); box(x + 2.5, 0, z, 3, h, dd, color); box(x, 2.3, z, 2, h - 2.3, dd, color); }
        else { box(x, 0, z - 2.5, ww, h, 3, color); box(x, 0, z + 2.5, ww, h, 3, color); box(x, 2.3, z, ww, h - 2.3, 2, color); } }
      box(cx, h, cz, w + 0.6, 0.35, w + 0.6, roofC || C.roof, { roof: true });
      box(cx + 2.5, h + 0.35, cz - 2.5, 1, 1.2, 1, C.brick);   // chimney
      box(cx - 2, 0, cz + 2, 2, 1, 1, C.crate); box(cx + 2, 0, cz - 2.4, 1.6, 0.8, 1.2, C.wood);   // furniture inside
    };
    // SW: residential block
    house(-24, -24, C.h1, 'e', C.roofR); house(-24, -12, C.h5, 'e'); house(-12, -26, C.h7, 'n', C.roofR);
    [[-24, -24], [-24, -12]].forEach(([x, z]) => { box(x + 4.8, 0, z, 0.3, 1.2, 5, C.wood); });   // garden fences
    [[-14, -14, C.carB], [-10, -14, C.carY]].forEach(([x, z, c]) => { box(x, 0, z, 2, 1.1, 4, c); deco(x, 1.1, z + 0.3, 1.8, 0.8, 2.4, C.glass); });
    [[-30, -30], [-18, -30], [-32, -18]].forEach(([x, z]) => box(x, 0, z, 1.6, 1.2, 1.6, C.hedge, { plain: true }));
    deco(-18, 0, -20, 3, 0.5, 1.4, C.flower); deco(-30, 0, -6, 1.4, 0.5, 3, C.flowerY);
    box(-18, 0, -8, 1.4, 1.2, 1.6, C.dog); box(-18, 1.2, -8, 1.8, 0.3, 2, C.roofR);   // doghouse
    box(-9, 0, -20, 0.3, 1.3, 0.3, C.lamp); deco(-9, 1.3, -20, 0.7, 0.5, 0.5, C.mailbox);   // mailbox
    // NW: construction site + tunnel
    box(-24, 0, 24, 0.5, 3.4, 10, C.brick); box(-19, 0, 29, 10, 3.4, 0.5, C.brick); box(-14, 0, 24, 0.5, 2, 10, C.brick);   // half-built walls
    [[-22, 18, 0], [-20.6, 18, 0], [-21.3, 18, 1]].forEach(([x, z, l]) => box(x, l * 1.4, z, 1.4, 1.4, 1.4, C.crate));
    box(-30, 0, 30, 4, 1.6, 4, C.sand, { plain: true }); box(-30, 1.6, 30, 2.4, 0.8, 2.4, C.sand, { plain: true });   // sand pile
    box(-33, 0, 20, 1.2, 1.2, 8, C.pipe, { plain: true }); box(-33, 1.2, 20, 1.2, 1.2, 8, C.pipe, { plain: true }); box(-31.6, 0, 20, 1.2, 1.2, 8, C.pipe, { plain: true });
    box(-14, 0, 34, 6, 0.3, 2, C.plank); box(-14, 0.3, 34.6, 6, 0.3, 0.8, C.plank); box(-10, 0, 30, 0.8, 0.3, 6, C.plank);
    box(-28, 0, 12, 1.6, 6, 1.6, C.lamp); box(-28, 6, 15, 1, 0.6, 10, C.awnY);   // crane
    box(-30, 0, 36.5, 3, 1.6, 1.8, C.bin); box(-26, 0, 36.5, 3, 1.6, 1.8, C.bin);
    box(-8, 0, 24, 0.4, 2.3, 12, C.tunnel); box(-11.6, 0, 24, 0.4, 2.3, 12, C.tunnel); box(-9.8, 2.3, 24, 4, 0.4, 12, C.tunnel, { roof: true });
    [[-36, 30], [-36, 34]].forEach(([x, z]) => box(x, 0, z, 1, 1.2, 1, C.barrel, { plain: true })); box(-36, 1.2, 32, 1, 1.2, 1, C.barrelB, { plain: true }); box(-36, 0, 32, 1, 1.2, 1, C.barrelB, { plain: true });
    // NE: park with pond, hedge maze, picnic tables, playground
    deco(26, -0.97, 10, 10, 1, 7, C.water, { ground: true }); box(26, 0, 6.3, 10.6, 0.3, 0.6, C.stone); box(26, 0, 13.7, 10.6, 0.3, 0.6, C.stone); box(20.7, 0, 10, 0.6, 0.3, 7.4, C.stone); box(31.3, 0, 10, 0.6, 0.3, 7.4, C.stone);
    const hedge = (x, z, w, d) => box(x, 0, z, w, 2.2, d, C.hedge);
    hedge(22, 22, 20, 1); hedge(16, 26, 8, 1); hedge(28, 26, 8, 1); hedge(12.5, 24, 1, 5); hedge(31.5, 24, 1, 5);
    hedge(18, 29, 1, 5); hedge(26, 29, 1, 5); hedge(22, 31, 6, 1); hedge(14, 19, 8, 1); hedge(30, 19, 8, 1); hedge(22, 18, 1, 7); hedge(10, 27, 1, 10); hedge(34, 27, 1, 10);
    [[12, 10], [12, 14]].forEach(([x, z]) => { box(x, 0, z, 2.4, 0.8, 1.2, C.wood); box(x, 0, z - 1, 2.4, 0.4, 0.5, C.wood); box(x, 0, z + 1, 2.4, 0.4, 0.5, C.wood); });   // picnic tables
    box(10, 0, 34, 0.3, 2.4, 0.3, C.lamp); box(14, 0, 34, 0.3, 2.4, 0.3, C.lamp); box(12, 2.4, 34, 4.6, 0.3, 0.3, C.lamp); box(11, 1, 34, 0.6, 0.15, 0.4, C.awnR); box(13, 1, 34, 0.6, 0.15, 0.4, C.awnB);   // swings
    box(18, 0, 36, 1.4, 2, 1.4, C.awnB); box(20.5, 0.9, 36, 3.6, 0.3, 1, C.awnY); box(22.2, 0.45, 36, 0.8, 0.3, 1, C.awnY); box(23, 0, 36, 0.8, 0.3, 1, C.awnY);   // slide
    [[36, 20], [36, 36], [8, 8], [8, 36], [30, 4]].forEach(([x, z]) => box(x, 0, z, 1.8, 1.4, 1.8, C.hedge, { plain: true }));
    [[16, 6, 1], [36, 8, 0], [34, 14, 2]].forEach(([x, z, i]) => deco(x, 0, z, 1.6 + i * 0.4, 1 + i * 0.3, 1.4, C.rock));
    // SE: market stalls, basketball court, bleachers, bus stop, vending machines
    const stall = (x, z, c) => { box(x, 0, z, 3, 1, 1.2, C.wood); box(x - 1.3, 0, z + 1, 0.2, 2.4, 0.2, C.lamp); box(x + 1.3, 0, z + 1, 0.2, 2.4, 0.2, C.lamp); box(x - 1.3, 0, z - 1, 0.2, 2.4, 0.2, C.lamp); box(x + 1.3, 0, z - 1, 0.2, 2.4, 0.2, C.lamp); box(x, 2.4, z, 3.6, 0.25, 2.8, c, { roof: true }); deco(x, 1, z, 2.6, 0.5, 1, c); };
    stall(14, -14, C.awnR); stall(14, -20, C.awnB); stall(14, -26, C.awnG); stall(22, -14, C.awnY); stall(22, -20, C.awnR);
    deco(30, -0.96, -26, 14, 1, 10, C.court, { ground: true }); deco(30, -0.955, -26, 0.25, 1, 10, C.courtLine, { ground: true }); deco(23.2, -0.955, -26, 0.25, 1, 10, C.courtLine, { ground: true }); deco(36.8, -0.955, -26, 0.25, 1, 10, C.courtLine, { ground: true });
    box(23.6, 0, -26, 0.3, 3.2, 0.3, C.lamp); box(23.6, 3, -26, 0.2, 1.1, 1.8, C.carW); box(36.4, 0, -26, 0.3, 3.2, 0.3, C.lamp); box(36.4, 3, -26, 0.2, 1.1, 1.8, C.carW);
    for (let i = 0; i < 4; i++) box(30, i * 0.6, -33.5 - i * 1, 12, 0.6, 1, C.bleacher);   // bleachers
    box(30, 0, -12, 4, 0.3, 1.5, C.road); box(30, 2.4, -12, 5, 0.3, 3, C.roof, { roof: true }); box(28.2, 0, -10.8, 0.3, 2.4, 0.3, C.road); box(31.8, 0, -10.8, 0.3, 2.4, 0.3, C.road);
    deco(37, 0, -14, 1.2, 2, 1, C.vending); deco(37, 0, -16, 1.2, 2, 1, C.vending2); box(37, 0, -8, 3, 1.6, 1.8, C.bin);
    [[10, -34, C.carR], [14, -34, C.carW], [18, -34, C.carG], [22, -34, C.carB]].forEach(([x, z, c]) => { box(x, 0, z, 2, 1.1, 4, c); deco(x, 1.1, z + 0.3, 1.8, 0.8, 2.4, C.glass); });
    // E road: parked cars + billboard; trees everywhere
    [[8, -8, C.carR], [8, -2, C.carW]].forEach(([x, z, c]) => { box(x, 0, z, 2, 1.1, 4, c); deco(x, 1.1, z + 0.3, 1.8, 0.8, 2.4, C.glass); });
    box(-8, 0, 8, 2, 1.1, 4, C.carB); deco(-8, 1.1, 8.3, 1.8, 0.8, 2.4, C.glass);
    box(0, 2.5, -36, 9, 4, 0.4, C.sign); box(-3.5, 0, -36, 0.4, 2.5, 0.4, C.fence); box(3.5, 0, -36, 0.4, 2.5, 0.4, C.fence); deco(0, 3.2, -35.7, 7.5, 2.4, 0.1, C.awnY);
    [[-6, -36, 0], [6, -36, 0], [-36, -6, 1], [36, 6, 0], [-6, 36, 1], [36, -8, 0], [-36, 8, 1], [16, 2, 0], [-16, -2, 1], [26, 34, 0], [-18, 14, 1], [6, 20, 0], [-6, -14, 1], [-36, -36, 0], [36, 36, 1], [-30, 2, 0]].forEach(([x, z, k]) => box(x, 0, z, 0.7, 4.2, 0.7, C.trunk, { tree: true, leafC: k ? C.leaf2 : C.leaf }));
    return P;
  }

  /* ---------- scene ---------- */
  function studTexture() {
    const c = document.createElement('canvas'); c.width = c.height = 64; const x = c.getContext('2d');
    x.fillStyle = '#fff'; x.fillRect(0, 0, 64, 64); x.fillStyle = 'rgba(0,0,0,.09)'; x.beginPath(); x.arc(32, 32, 12, 0, Math.PI * 2); x.fill();
    x.fillStyle = 'rgba(255,255,255,.35)'; x.beginPath(); x.arc(30, 30, 9, 0, Math.PI * 2); x.fill(); x.strokeStyle = 'rgba(0,0,0,.08)'; x.lineWidth = 2; x.strokeRect(1, 1, 62, 62);
    const t = new THREE.CanvasTexture(c); t.wrapS = t.wrapT = THREE.RepeatWrapping; t.anisotropy = 4; return t;
  }
  function discTex(r, g, b) {
    const c = document.createElement('canvas'); c.width = c.height = 128; const x = c.getContext('2d');
    const gr = x.createRadialGradient(64, 64, 10, 64, 64, 64); gr.addColorStop(0, `rgba(${r},${g},${b},1)`); gr.addColorStop(0.6, `rgba(${r},${g},${b},.6)`); gr.addColorStop(1, `rgba(${r},${g},${b},0)`);
    x.fillStyle = gr; x.fillRect(0, 0, 128, 128); return new THREE.CanvasTexture(c);
  }
  // all the map's boxes in ONE mesh (studs or plain): one draw call instead of ~300, and one object for the shotgun rays
  function mergedBoxes(list, textured) {
    const pos = [], nor = [], uv = [], col = [], idx = []; let off = 0; const c = new THREE.Color();
    for (const p of list) {
      const g = new THREE.BoxGeometry(p.w, p.h, p.d), pa = g.attributes.position, na = g.attributes.normal, ua = g.attributes.uv, ia = g.index;
      c.setHex(p.color);
      for (let i = 0; i < pa.count; i++) {
        pos.push(pa.getX(i) + p.x, pa.getY(i) + p.y + p.h / 2, pa.getZ(i) + p.z); nor.push(na.getX(i), na.getY(i), na.getZ(i)); col.push(c.r, c.g, c.b);
        const f = Math.floor(i / 4), su = f < 2 ? p.d : p.w, sv = f < 2 ? p.h : f < 4 ? p.d : p.h;   // faces: +x -x +y -y +z -z
        uv.push(ua.getX(i) * (textured ? Math.max(1, Math.round(su)) : 1), ua.getY(i) * (textured ? Math.max(1, Math.round(sv)) : 1));
      }
      for (let i = 0; i < ia.count; i++) idx.push(ia.getX(i) + off); off += pa.count; g.dispose();
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); geo.setAttribute('normal', new THREE.Float32BufferAttribute(nor, 3));
    geo.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2)); geo.setAttribute('color', new THREE.Float32BufferAttribute(col, 3)); geo.setIndex(idx);
    const m = new THREE.Mesh(geo, new THREE.MeshLambertMaterial({ vertexColors: true, map: textured ? studTex : null })); m.castShadow = m.receiveShadow = true; return m;
  }
  function build() {
    scene = new THREE.Scene(); scene.background = new THREE.Color(0x87c7ff); scene.fog = new THREE.Fog(0xa5d4ff, 70, 170);
    camera = new THREE.PerspectiveCamera(65, 1, 0.1, 400);
    scene.add(new THREE.HemisphereLight(0xdfefff, 0x5f6b7d, 0.6));
    const sun = new THREE.DirectionalLight(0xfff4de, 0.85); sun.castShadow = true; sun.shadow.mapSize.set(1024, 1024);
    Object.assign(sun.shadow.camera, { left: -48, right: 48, top: 48, bottom: -48, near: 1, far: 200 }); sun.shadow.bias = -0.0008; sun.shadow.normalBias = 0.03;
    sun.position.set(30, 60, 20); scene.add(sun, sun.target);
    studTex = studTexture(); parts = mapParts();
    for (const p of parts) { p.b = partBox(p); if (p.roof) roofs.push(p); }
    const studded = mergedBoxes(parts.filter(p => !p.plain), true), plain = mergedBoxes(parts.filter(p => p.plain), false);
    scene.add(studded, plain); mapMeshes.push(studded, plain);
    const leafGeo = new THREE.SphereGeometry(2.3, 10, 8), leafA = new THREE.MeshLambertMaterial({ color: C.leaf }), leafB = new THREE.MeshLambertMaterial({ color: C.leaf2 });
    for (const p of parts) if (p.tree) { const c = new THREE.Mesh(leafGeo, p.leafC === C.leaf2 ? leafB : leafA); c.position.set(p.x, 4.8, p.z); c.castShadow = true; scene.add(c); mapMeshes.push(c); }
    const cloudMat = new THREE.SpriteMaterial({ map: discTex(255, 255, 255), transparent: true, opacity: 0.85, depthWrite: false });
    for (let i = 0; i < 18; i++) { const sp = new THREE.Sprite(cloudMat); const s = 14 + Math.random() * 20; sp.scale.set(s * 1.7, s, 1); sp.position.set((Math.random() - 0.5) * 220, 35 + Math.random() * 30, (Math.random() - 0.5) * 220); scene.add(sp); clouds.push({ sp, v: 0.5 + Math.random() }); }
    player = avatar(me.color, me.name); scene.add(player.g);
  }
  function avatar(color, name) {
    const g = new THREE.Group(), pose = new THREE.Group(); g.add(pose);
    const skin = new THREE.MeshLambertMaterial({ color: 0xf1c27d }), body = new THREE.MeshLambertMaterial({ color }), pants = new THREE.MeshLambertMaterial({ color: 0x2c3e66 }), hatM = new THREE.MeshLambertMaterial({ color: (color ^ 0x7f7f7f) & 0xffffff });
    const meshes = [];
    const mk = (w, h, d, mat, x, y, z) => { const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat); m.position.set(x, y, z); m.castShadow = true; pose.add(m); meshes.push(m); return m; };
    mk(0.7, 0.7, 0.7, skin, 0, 1.45, 0); mk(0.8, 0.7, 0.4, body, 0, 0.8, 0);
    const la = mk(0.3, 0.7, 0.3, body, -0.55, 0.8, 0), ra = mk(0.3, 0.7, 0.3, body, 0.55, 0.8, 0);
    const ll = mk(0.35, 0.7, 0.35, pants, -0.2, 0.1, 0), rl = mk(0.35, 0.7, 0.35, pants, 0.2, 0.1, 0);
    [la, ra, ll, rl].forEach(m => { m.geometry.translate(0, -0.35, 0); m.position.y += 0.35; });
    mk(0.8, 0.18, 0.8, hatM, 0, 1.86, 0); mk(0.5, 0.3, 0.5, hatM, 0, 2.05, 0);
    const eye = new THREE.MeshBasicMaterial({ color: 0x222222 });
    [-0.15, 0.15].forEach(x => { const e = new THREE.Mesh(new THREE.BoxGeometry(0.08, 0.1, 0.02), eye); e.position.set(x, 1.5, 0.36); pose.add(e); });
    const smile = new THREE.Mesh(new THREE.BoxGeometry(0.26, 0.05, 0.02), eye); smile.position.set(0, 1.32, 0.36); pose.add(smile);
    const gun = new THREE.Mesh(new THREE.BoxGeometry(0.16, 0.16, 1.3), new THREE.MeshLambertMaterial({ color: 0x2a2635 })); gun.position.set(0.55, 0.95, 0.5); gun.visible = false; pose.add(gun);
    const tag = new THREE.Sprite(new THREE.SpriteMaterial({ map: tagTex(name, ''), depthTest: false })); tag.scale.set(2.6, 0.65, 1); tag.position.y = 2.6; g.add(tag);
    const bubble = new THREE.Sprite(new THREE.SpriteMaterial({ transparent: true, depthTest: false, opacity: 0 })); bubble.scale.set(1.3, 1.3, 1); bubble.position.y = 3.4; g.add(bubble);
    return { g, pose, meshes, mats: { skin, body, pants, hatM }, base: { skin: 0xf1c27d, body: color, pants: 0x2c3e66, hat: (color ^ 0x7f7f7f) & 0xffffff }, la, ra, ll, rl, gun, tag, bubble, walk: 0, tx: 0, ty: 0, tz: 0, tr: 0, m: 0, poseName: 'stand', color: null };
  }
  function tagTex(name, role) {
    const c = document.createElement('canvas'); c.width = 256; c.height = 64; const x = c.getContext('2d');
    x.fillStyle = role === 'seeker' ? 'rgba(200,40,40,.75)' : role === 'hider' ? 'rgba(40,120,220,.75)' : 'rgba(0,0,0,.45)'; x.fillRect(0, 8, 256, 48);
    x.font = '700 30px Inter, Arial'; x.textAlign = 'center'; x.fillStyle = '#fff'; x.fillText((role ? (role === 'seeker' ? '🔫 ' : '🦎 ') : '') + name.slice(0, 14), 128, 43);
    return new THREE.CanvasTexture(c);
  }
  function setRole(av, name, role) { av.tag.material.map = tagTex(name, role); av.tag.material.needsUpdate = true; av.gun.visible = role === 'seeker'; }
  // camouflage: one color over the whole body, no cast shadow so it reads flat against the surface
  function paint(av, color) {
    av.color = color;
    const c = color == null ? null : color;
    av.mats.skin.color.set(c == null ? av.base.skin : c); av.mats.body.color.set(c == null ? av.base.body : c); av.mats.pants.color.set(c == null ? av.base.pants : c); av.mats.hatM.color.set(c == null ? av.base.hat : c);
    for (const m of av.meshes) m.castShadow = c == null;
  }
  function setPose(av, p) {
    av.poseName = p; const g = av.pose; g.rotation.set(0, 0, 0); g.scale.set(1, 1, 1); g.position.set(0, 0, 0);
    if (p === 'crouch') { g.scale.set(1, 0.6, 1); }
    if (p === 'prone') { g.rotation.x = Math.PI / 2; g.position.y = 0.32; }
    if (p === 'curl') { g.scale.set(0.8, 0.45, 0.8); g.rotation.x = 0.5; g.position.y = 0.05; }
    av.tag.position.y = p === 'stand' ? 2.6 : p === 'crouch' ? 1.9 : 1.2;
  }
  function animate(av, moving, air, dt) {
    if (av.poseName !== 'stand') { av.la.rotation.x = av.ra.rotation.x = av.ll.rotation.x = av.rl.rotation.x = 0; return; }
    if (moving && !air) av.walk += dt * 11; else av.walk += (0 - (av.walk % (Math.PI * 2))) * Math.min(1, dt * 12);
    const s = Math.sin(av.walk) * (moving && !air ? 0.8 : 0), a = air ? -2.6 : 0;
    av.la.rotation.x = a || -s; av.ra.rotation.x = av.gun.visible ? -1.4 : (a || s); av.ll.rotation.x = air ? 0.5 : s; av.rl.rotation.x = air ? -0.3 : -s;
  }
  function emoteTex(txt) {
    const c = document.createElement('canvas'); c.width = c.height = 128; const x = c.getContext('2d');
    x.fillStyle = '#fff'; x.beginPath(); x.roundRect ? x.roundRect(8, 8, 112, 96, 24) : x.rect(8, 8, 112, 96); x.fill(); x.beginPath(); x.moveTo(52, 102); x.lineTo(76, 102); x.lineTo(64, 122); x.fill();
    x.font = '72px system-ui, "Apple Color Emoji", "Segoe UI Emoji"'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.fillStyle = '#ff5a3c'; x.fillText(txt, 64, 58);
    return new THREE.CanvasTexture(c);
  }
  function showBubble(av, txt) { av.bubble.material.map = emoteTex(txt); av.bubble.material.opacity = 1; av.bubble.material.needsUpdate = true; av.bubbleT = now(); }

  /* ---------- sounds ---------- */
  let AC = null;
  function beep(f, d, type, vol) {
    try { AC = AC || new (window.AudioContext || window.webkitAudioContext)(); if (AC.state === 'suspended') AC.resume();
      const o = AC.createOscillator(), g = AC.createGain(); o.type = type || 'square'; o.frequency.value = f; g.gain.value = vol || 0.04;
      o.connect(g); g.connect(AC.destination); o.start(); g.gain.exponentialRampToValueAtTime(0.0001, AC.currentTime + d); o.stop(AC.currentTime + d); } catch {}
  }
  function noise(d, vol) {
    try { AC = AC || new (window.AudioContext || window.webkitAudioContext)(); if (AC.state === 'suspended') AC.resume();
      const b = AC.createBuffer(1, AC.sampleRate * d, AC.sampleRate), ch0 = b.getChannelData(0); for (let i = 0; i < ch0.length; i++) ch0[i] = (Math.random() * 2 - 1) * (1 - i / ch0.length) ** 2;
      const s = AC.createBufferSource(), g = AC.createGain(), f = AC.createBiquadFilter(); s.buffer = b; f.type = 'lowpass'; f.frequency.value = 900; g.gain.value = vol || 0.2; s.connect(f); f.connect(g); g.connect(AC.destination); s.start(); } catch {}
  }
  const snd = { whistle: () => [0, 90, 180].forEach((t, i) => setTimeout(() => beep([1400, 1800, 2300][i], 0.12, 'sine', 0.06), t)), jump: () => beep(420, 0.12, 'square', 0.03), shot: () => { noise(0.35, 0.35); beep(90, 0.2, 'sawtooth', 0.08); }, caught: () => [0, 150].forEach((t, i) => setTimeout(() => beep([700, 380][i], 0.3, 'sawtooth', 0.06), t)), go: () => [0, 120, 240].forEach((t, i) => setTimeout(() => beep([523, 659, 880][i], 0.2, 'triangle', 0.06), t)), item: () => beep(900, 0.15, 'sine', 0.05), paint: () => beep(1300, 0.08, 'sine', 0.04), click: () => beep(200, 0.06, 'square', 0.03) };

  /* ---------- physics ---------- */
  function partBox(p) { return { x0: p.x - p.w / 2, x1: p.x + p.w / 2, y0: p.y, y1: p.y + p.h, z0: p.z - p.d / 2, z1: p.z + p.d / 2 }; }
  function overlapXZ(b, pad = 0) { return S.x + PW + pad > b.x0 && S.x - PW - pad < b.x1 && S.z + PW + pad > b.z0 && S.z - PW - pad < b.z1; }
  function spawn() { S.x = M.hider ? -3 : 3; S.y = 0; S.z = 5; S.vx = S.vy = S.vz = 0; S.ground = null; S.yaw = 0; cam.yaw = Math.PI; cam.pitch = 0.3; S.ammo = AMMO; S.shotAt = 0; setMyPose('stand'); setMyPaint(null); }
  const canMove = () => M.phase === 'seek' || (M.phase === 'hide' && M.hider);
  function step(dt) {
    const t = now(), frozen = t < S.frozenUntil;
    let ix = 0, iz = 0;
    if (canMove() && !frozen) { if (keys.w) iz += 1; if (keys.s) iz -= 1; if (keys.a) ix -= 1; if (keys.d) ix += 1; if (joy) { ix += joy.x; iz -= joy.y; } }
    const il = Math.hypot(ix, iz); if (il > 1) { ix /= il; iz /= il; }
    if (il > 0.1 && S.pose !== 'stand' && S.pose !== 'crouch') setMyPose('stand');   // moving breaks a lying pose
    const fy = cam.yaw, fx = -Math.sin(fy), fz = -Math.cos(fy), rx = Math.cos(fy), rz = -Math.sin(fy);
    const sp = SPEED * (S.pose === 'crouch' ? 0.45 : 1), wx = (fx * iz + rx * ix) * sp, wz = (fz * iz + rz * ix) * sp;
    const acc = S.ground ? 20 : 7; S.vx += (wx - S.vx) * Math.min(1, acc * dt); S.vz += (wz - S.vz) * Math.min(1, acc * dt);
    S.moving = il > 0.1; if (S.moving) S.yaw = Math.atan2(wx, wz);
    if (S.ground) S.air = 0; else S.air += dt;
    if (jumpQ) { S.jumpBuf = 0.12; jumpQ = false; }
    if (S.jumpBuf > 0 && canMove() && !frozen) { S.jumpBuf -= dt; if (S.ground || S.air < 0.1) { if (S.pose !== 'stand') setMyPose('stand'); S.vy = JUMP; S.ground = null; S.air = 1; S.jumpBuf = 0; snd.jump(); } }
    S.vy -= G * dt; if (S.vy < -45) S.vy = -45;
    const boxes = parts;
    S.x += S.vx * dt;
    for (const p of boxes) { const b = p.b; if (!overlapXZ(b) || S.y + PH <= b.y0 || S.y >= b.y1 - 0.08) continue; S.x = (S.vx > 0 || (S.vx === 0 && S.x < p.x)) ? b.x0 - PW : b.x1 + PW; S.vx = 0; }
    S.z += S.vz * dt;
    for (const p of boxes) { const b = p.b; if (!overlapXZ(b) || S.y + PH <= b.y0 || S.y >= b.y1 - 0.08) continue; S.z = (S.vz > 0 || (S.vz === 0 && S.z < p.z)) ? b.z0 - PW : b.z1 + PW; S.vz = 0; }
    S.y += S.vy * dt; S.ground = null;
    for (const p of boxes) { const b = p.b; if (!overlapXZ(b) || S.y + PH <= b.y0 || S.y >= b.y1) continue;
      if (S.vy <= 0 && S.y > b.y1 - 0.9) { S.y = b.y1; S.vy = 0; S.ground = p; } else if (S.vy > 0 && S.y + PH < b.y0 + 0.5) { S.y = b.y0 - PH; S.vy = 0; } else { S.y = b.y1; S.vy = 0; S.ground = p; } }
    if (S.y < -20) spawn();
    if (fireQ) { fireQ = false; shoot(); }
    if (M.hider && opp) for (const dc of decoys) if (!dc.gone && Math.hypot(opp.g.position.x - dc.g.position.x, opp.g.position.z - dc.g.position.z) < 1.2) popDecoy(dc);
  }
  function popDecoy(dc, shot) { dc.gone = true; scene.remove(dc.g); burst(dc.g.position.x, dc.g.position.y + 1, dc.g.position.z, 0xffffff, 14); if (!M.hider) toastLocal('Just a decoy!'); }

  /* ---------- the hunter's shotgun ---------- */
  function shoot() {
    const t = now();
    if (M.hider || M.phase !== 'seek' || t < S.frozenUntil || S.ammo <= 0 || t - S.shotAt < RELOAD) { if (!M.hider && M.phase === 'seek' && S.ammo <= 0) snd.click(); return; }
    S.ammo--; S.shotAt = t; snd.shot(); hud();
    const dir = new THREE.Vector3(); camera.getWorldDirection(dir);
    const origin = camera.position.clone(); const ray = new THREE.Raycaster(); ray.far = RANGE + cam.dist;
    const targets = []; if (opp && opp.g.visible) targets.push(...opp.meshes); for (const d of decoys) if (!d.gone) targets.push(...d.meshes);
    let hitOpp = false, hitDecoy = null, impacts = [];
    for (let i = 0; i < PELLETS; i++) {
      const d = dir.clone(); d.x += (Math.random() - 0.5) * 2 * SPREAD; d.y += (Math.random() - 0.5) * 2 * SPREAD; d.z += (Math.random() - 0.5) * 2 * SPREAD; d.normalize();
      ray.set(origin, d);
      const hits = ray.intersectObjects([...targets, ...mapMeshes], false).filter(h => h.distance > cam.dist * 0.8);   // skip things between the camera and my own back
      if (!hits.length) continue;
      const h = hits[0]; impacts.push(h.point);
      if (opp && opp.meshes.includes(h.object)) hitOpp = true;
      else for (const dc of decoys) if (!dc.gone && dc.meshes.includes(h.object)) hitDecoy = dc;
    }
    for (const p of impacts.slice(0, 4)) burst(p.x, p.y, p.z, 0xffe08a, 3, 0.4);
    flashAt(S.x, S.y + 1.2, S.z);
    send('sh', { x: +S.x.toFixed(2), y: +S.y.toFixed(2), z: +S.z.toFixed(2), hit: hitOpp ? 1 : 0, pts: impacts.slice(0, 3).map(p => [+p.x.toFixed(1), +p.y.toFixed(1), +p.z.toFixed(1)]) });
    if (hitDecoy) popDecoy(hitDecoy, true);
    if (hitOpp && t - M.caughtSent > 3) { M.caughtSent = t; toastLocal('Got them!'); onHud.caught && onHud.caught(); }
  }
  function flashAt(x, y, z) { const l = new THREE.PointLight(0xffd080, 3, 12); l.position.set(x, y, z); scene.add(l); setTimeout(() => scene.remove(l), 70); }

  /* ---------- paint + pose ---------- */
  function setMyPose(p) { if (!POSES.includes(p)) return; S.pose = p; setPose(player, p); hud(); lastSig = ''; }
  function setMyPaint(c) { S.color = c; paint(player, c); hud(); lastSig = ''; }
  function nearestColor() {   // the color of the surface you're up against (walls, crates...) or whatever you're standing on
    let best = null, bd = 0.9;
    for (const p of parts) { if (p.ground) continue; const b = p.b; if (S.y + PH <= b.y0 || S.y >= b.y1) continue;
      const dx = Math.max(b.x0 - S.x, 0, S.x - b.x1), dz = Math.max(b.z0 - S.z, 0, S.z - b.z1), d = Math.hypot(dx, dz); if (d < bd) { bd = d; best = p; } }
    if (best) return best.color;
    return S.ground ? S.ground.color : C.grass;
  }
  function palette() { const seen = new Set(), out = []; for (const p of parts) if (!seen.has(p.color)) { seen.add(p.color); out.push(p.color); } return out; }

  /* ---------- gadgets ---------- */
  function useItem(k) {
    if (!M.hider || !ITEMS[k] || !M.items.includes(k) || M.used[k] || !(M.phase === 'seek' || M.phase === 'hide')) return false;
    M.used[k] = true; snd.item(); applyItem(k, S.x, S.y, S.z, true, S.color, S.pose); send('it', { k, x: +S.x.toFixed(2), y: +S.y.toFixed(2), z: +S.z.toFixed(2), c: S.color, p: S.pose, r: +S.yaw.toFixed(2) }); hud(); return true;
  }
  function applyItem(k, x, y, z, mine, color, pose, rot) {
    if (k === 'freeze') { if (!mine) { S.frozenUntil = now() + ITEMS.freeze.secs; S.vx = S.vz = 0; toastLocal('❄️ Frozen!'); } else if (opp) showBubble(opp, '❄️'); }
    if (k === 'smoke') { const m = new THREE.Mesh(new THREE.SphereGeometry(6, 24, 16), new THREE.MeshBasicMaterial({ color: 0x9a9aa6, transparent: true, opacity: mine ? 0.3 : 0.96, side: THREE.DoubleSide, depthWrite: false })); m.position.set(x, y + 1, z); scene.add(m); smokes.push({ m, x, y: y + 1, z, r: 6, t: now(), life: ITEMS.smoke.secs }); if (!mine) toastLocal('💨 Smoke!'); }
    if (k === 'decoy') { const av = avatar(mine ? me.color : (opp ? opp.color : 0x9b5cf6), mine ? me.name : M.oppName); av.g.position.set(x, y, z); av.g.rotation.y = rot != null ? rot : (mine ? S.yaw : 0); paint(av, color); setPose(av, pose || 'stand'); av.tag.visible = false; scene.add(av.g); decoys.push(av); }
  }
  function clearRound() { for (const s of smokes) scene.remove(s.m); smokes = []; for (const d of decoys) scene.remove(d.g); decoys = []; for (const pg of pings) scene.remove(pg.g); pings = []; M.used = {}; S.frozenUntil = 0; M.tauntAt = 0; }
  /* ---------- taunt: ping your spot to the hunter for points ---------- */
  function taunt() {
    const t = now();
    if (!M.hider || M.phase !== 'seek' || t - M.tauntAt < 10) return false;
    M.tauntAt = t; showBubble(player, '📣'); snd.whistle(); showPing(S.x, S.y, S.z);
    send('ta', { x: +S.x.toFixed(2), y: +S.y.toFixed(2), z: +S.z.toFixed(2) }); onHud.taunt && onHud.taunt(); hud(); return true;
  }
  function showPing(x, y, z) {
    const g = new THREE.Group();
    const ring = new THREE.Mesh(new THREE.TorusGeometry(1.6, 0.12, 8, 32), new THREE.MeshBasicMaterial({ color: 0xff5a3c, transparent: true })); ring.rotation.x = Math.PI / 2; ring.position.y = 0.1; g.add(ring);
    const beam = new THREE.Mesh(new THREE.CylinderGeometry(0.25, 0.25, 14, 10, 1, true), new THREE.MeshBasicMaterial({ color: 0xff5a3c, transparent: true, opacity: 0.35, side: THREE.DoubleSide, depthWrite: false })); beam.position.y = 7; g.add(beam);
    const ic = new THREE.Sprite(new THREE.SpriteMaterial({ map: emoteTex('📣'), transparent: true, depthTest: false })); ic.scale.set(2, 2, 1); ic.position.y = 4; g.add(ic);
    g.position.set(x, y, z); scene.add(g); pings.push({ g, ring, t: now(), life: 5 });
  }

  /* ---------- effects ---------- */
  function burst(x, y, z, color, n, life = 0.8) {
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true });
    for (let i = 0; i < n; i++) { const m = new THREE.Mesh(new THREE.BoxGeometry(0.18, 0.18, 0.18), mat); m.position.set(x, y, z); scene.add(m); fx.push({ m, vx: (Math.random() - 0.5) * 9, vy: 3 + Math.random() * 7, vz: (Math.random() - 0.5) * 9, t: now(), life, mat }); }
  }
  function fxTick(dt) {
    const t = now();
    fx = fx.filter(f => { const k = (t - f.t) / f.life; if (k >= 1) { scene.remove(f.m); return false; } f.vy -= 20 * dt; f.m.position.x += f.vx * dt; f.m.position.y += f.vy * dt; f.m.position.z += f.vz * dt; f.m.rotation.x += dt * 6; f.mat.opacity = 1 - k; return true; });
    pings = pings.filter(pg => { const k = (t - pg.t) / pg.life; if (k >= 1) { scene.remove(pg.g); return false; } const sc = 1 + Math.sin(t * 6) * 0.15; pg.ring.scale.set(sc, sc, 1); pg.g.children.forEach(c => { if (c.material) c.material.opacity = (c === pg.ring ? 1 : c.isSprite ? 1 : 0.35) * (k > 0.7 ? (1 - k) / 0.3 : 1); }); return true; });
    smokes = smokes.filter(s => { const k = (t - s.t) / s.life; if (k >= 1) { scene.remove(s.m); return false; } s.m.material.opacity = (M.hider ? 0.3 : 0.96) * (k > 0.8 ? (1 - k) * 5 : 1); s.m.scale.setScalar(Math.min(1, 0.3 + k * 4)); return true; });
  }
  function toastLocal(t) { onHud.msg && onHud.msg(t); }
  function hud() { onHud.hud && onHud.hud({ items: M.items, used: M.used, hider: M.hider, phase: M.phase, ammo: S.ammo, pose: S.pose, color: S.color, frozen: Math.max(0, S.frozenUntil - now()), tauntIn: Math.max(0, 10 - (now() - M.tauntAt)) }); }

  /* ---------- camera + input ---------- */
  function updateCam() {
    const hunting = !M.hider && M.phase === 'seek', side = hunting ? 0.9 : 0;   // the hunter aims over the shoulder so the crosshair isn't on their own back
    const tx = S.x + Math.cos(cam.yaw) * side, ty = S.y + (S.pose === 'stand' ? 1.5 : S.pose === 'crouch' ? 1.1 : 0.7), tz = S.z - Math.sin(cam.yaw) * side;
    let dist = hunting ? Math.min(cam.dist, 5) : cam.dist, pitch = cam.pitch;
    let roofY = null; for (const r of roofs) { const b = r.b; if (overlapXZ(b, 0.5) && b.y0 > S.y + 1.2 && b.y0 < S.y + 6) roofY = roofY == null ? b.y0 : Math.min(roofY, b.y0); }
    if (roofY != null) { dist = Math.min(dist, 3.2); pitch = Math.min(pitch, Math.max(-0.2, Math.asin(Math.max(-1, Math.min(1, (roofY - 0.4 - ty) / dist))))); }
    let cx = tx + Math.sin(cam.yaw) * Math.cos(pitch) * dist, cy = ty + Math.sin(pitch) * dist, cz = tz + Math.cos(cam.yaw) * Math.cos(pitch) * dist;
    for (let i = 0; i < 3; i++) { let hit = false; for (const p of parts) { if (p.ground || p.h < 1.5) continue; const b = p.b; if (cx > b.x0 - 0.3 && cx < b.x1 + 0.3 && cz > b.z0 - 0.3 && cz < b.z1 + 0.3 && cy > b.y0 && cy < b.y1 + 0.3) { hit = true; break; } }
      if (!hit) break; cx = tx + (cx - tx) * 0.55; cz = tz + (cz - tz) * 0.55; cy = ty + (cy - ty) * 0.55; }
    camera.position.set(cx, Math.max(cy, 0.4), cz); camera.lookAt(tx, ty, tz);
  }
  const KEYMAP = { w: 'w', arrowup: 'w', s: 's', arrowdown: 's', a: 'a', arrowleft: 'a', d: 'd', arrowright: 'd' };
  function onKey(e, down) {
    if (!open || /input|textarea|select/i.test(e.target.tagName)) return;
    const k = e.key.toLowerCase();
    if (k === ' ') { e.preventDefault(); if (down && !e.repeat) jumpQ = true; return; }
    if (down && (k === '-' || k === '=' || k === '+')) { zoom(k === '-' ? 1.5 : -1.5); return; }
    if (down && !e.repeat) {
      if ({ 1: 'freeze', 2: 'smoke', 3: 'decoy' }[k]) return useItem({ 1: 'freeze', 2: 'smoke', 3: 'decoy' }[k]);
      if (k === 'r' && M.hider) return setMyPose(POSES[(POSES.indexOf(S.pose) + 1) % POSES.length]);
      if (k === 'c' && M.hider) return setMyPose(S.pose === 'crouch' ? 'stand' : 'crouch');
      if (k === 'f' && M.hider) { setMyPaint(nearestColor()); snd.paint(); return; }
      if (k === 'g' && M.hider) return setMyPaint(null);
      if (k === 't' && M.hider) return taunt();
    }
    if (KEYMAP[k]) { e.preventDefault(); keys[KEYMAP[k]] = down; }
  }
  function bindInput() {
    window.addEventListener('keydown', e => onKey(e, true)); window.addEventListener('keyup', e => onKey(e, false));
    window.addEventListener('blur', () => { for (const k in keys) keys[k] = false; joy = null; });
    const ptr = {};
    canvas.addEventListener('contextmenu', e => e.preventDefault());
    canvas.addEventListener('pointerdown', e => {
      try { canvas.setPointerCapture(e.pointerId); } catch {}
      const r = canvas.getBoundingClientRect(), touch = e.pointerType === 'touch';
      if (touch && e.clientX - r.left < r.width * 0.45) { ptr[e.pointerId] = { kind: 'joy', ox: e.clientX, oy: e.clientY }; joy = { x: 0, y: 0 }; showJoy(e.clientX - r.left, e.clientY - r.top, 0, 0); }
      else ptr[e.pointerId] = { kind: 'cam', lx: e.clientX, ly: e.clientY, sx: e.clientX, sy: e.clientY, t: now(), touch };
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
      if (p.kind === 'joy') { const dx = e.clientX - p.ox, dy = e.clientY - p.oy, l = Math.hypot(dx, dy), m = Math.min(1, l / 45); joy = { x: l ? dx / l * m : 0, y: l ? dy / l * m : 0 }; const r = canvas.getBoundingClientRect(); showJoy(p.ox - r.left, p.oy - r.top, dx, dy); }
      else { cam.yaw -= (e.clientX - p.lx) * 0.006; cam.pitch = Math.max(-0.35, Math.min(1.25, cam.pitch + (e.clientY - p.ly) * 0.005)); p.lx = e.clientX; p.ly = e.clientY; }
    });
    const end = e => { const p = ptr[e.pointerId]; if (!p) return; delete ptr[e.pointerId]; if (pinch.ids && pinch.ids.includes(String(e.pointerId))) pinch.ids = null;
      if (p.kind === 'joy') { joy = null; hideJoy(); }
      else if (!p.touch && !p.pinched && Math.hypot(e.clientX - p.sx, e.clientY - p.sy) < 6 && now() - p.t < 0.35) fireQ = true;   // a click (not a drag) fires
    };
    canvas.addEventListener('pointerup', end); canvas.addEventListener('pointercancel', end);
    canvas.addEventListener('wheel', e => { e.preventDefault(); zoom(cam.dist + e.deltaY * 0.01, true); }, { passive: false });
    for (const [sel, dz] of [['.g3-zin', -1.5], ['.g3-zout', 1.5]]) { const zb = wrap.querySelector(sel); if (zb) zb.addEventListener('click', () => zoom(cam.dist + dz, true)); }
    const jb = wrap.querySelector('.obby-jump'); if (jb) jb.addEventListener('pointerdown', e => { e.preventDefault(); jumpQ = true; });
    const fb = wrap.querySelector('.hs-fire'); if (fb) fb.addEventListener('pointerdown', e => { e.preventDefault(); fireQ = true; });
  }
  function showJoy(x, y, dx, dy) { const j = wrap.querySelector('.obby-joy'); if (!j) return; j.hidden = false; j.style.left = x + 'px'; j.style.top = y + 'px'; const l = Math.hypot(dx, dy), m = Math.min(45, l); j.firstElementChild.style.transform = `translate(${l ? dx / l * m : 0}px,${l ? dy / l * m : 0}px)`; }
  function hideJoy() { const j = wrap.querySelector('.obby-joy'); if (j) j.hidden = true; }

  /* ---------- multiplayer (one channel per match, like Archers) ---------- */
  function send(ev, payload) { if (ch && joined) ch.send({ type: 'broadcast', event: ev, payload }); }
  async function connect(id) {
    if (ch) { const c = ch; ch = null; joined = false; try { await sb.removeChannel(c); } catch {} }
    if (!open || M.id !== id) return;
    const c = sb.channel('hide-' + id, { config: { broadcast: { self: false, ack: false } } }); ch = c;
    c.on('broadcast', { event: 's' }, ({ payload: p }) => { if (ch !== c || !opp) return; opp.tx = p.x; opp.ty = p.y; opp.tz = p.z; opp.tr = p.r; opp.m = p.m; opp.air = p.j; opp.seen = now();
      if (p.p !== opp.poseName) setPose(opp, p.p || 'stand'); if ((p.c == null ? null : p.c) !== opp.color) paint(opp, p.c == null ? null : p.c);
      if (!opp.placed) { opp.placed = true; opp.g.position.set(p.x, p.y, p.z); } });
    c.on('broadcast', { event: 'it' }, ({ payload: p }) => { if (ch !== c) return; applyItem(p.k, p.x, p.y, p.z, false, p.c, p.p, p.r); });
    c.on('broadcast', { event: 'sh' }, ({ payload: p }) => { if (ch !== c) return; snd.shot(); flashAt(p.x, p.y + 1.2, p.z); for (const q of p.pts || []) burst(q[0], q[1], q[2], 0xffe08a, 3, 0.4); if (p.hit) toastLocal('💥 You got hit!'); });
    c.on('broadcast', { event: 'ta' }, ({ payload: p }) => { if (ch !== c) return; showPing(p.x, p.y, p.z); snd.whistle(); toastLocal('📣 ' + M.oppName + ' taunted you! +8 for them'); });
    c.on('broadcast', { event: 'e' }, ({ payload: p }) => { if (ch === c && opp) showBubble(opp, p.t); });
    c.subscribe(status => {
      if (ch !== c) return; joined = status === 'SUBSCRIBED'; if (joined) lastSig = '';
      if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') setTimeout(() => { if (open && ch === c) connect(id); }, 1500);
    });
  }
  function netTick(t) {
    const sig = [S.x.toFixed(1), S.y.toFixed(1), S.z.toFixed(1), S.yaw.toFixed(1), S.moving ? 1 : 0, S.ground ? 0 : 1, S.pose, S.color].join(',');
    const rate = sig !== lastSig ? 0.07 : 1.0;
    if (t - lastSend >= rate) { lastSend = t; lastSig = sig; send('s', { x: +S.x.toFixed(2), y: +S.y.toFixed(2), z: +S.z.toFixed(2), r: +S.yaw.toFixed(2), m: S.moving ? 1 : 0, j: S.ground ? 0 : 1, p: S.pose, c: S.color }); }
  }
  let lastEmote = 0;
  function emote(txt) { const t = now(); if (t - lastEmote < 1) return; lastEmote = t; showBubble(player, txt); send('e', { t: txt }); }

  /* ---------- loop ---------- */
  let last = 0;
  function frame() {
    if (!open) return; raf = requestAnimationFrame(frame);
    const t = now(), dt = Math.min(0.1, t - (last || t)); last = t;
    const n = Math.max(1, Math.ceil(dt / (1 / 120))); for (let i = 0; i < n; i++) step(dt / n);
    player.g.position.set(S.x, S.y, S.z); player.g.rotation.y = S.yaw; animate(player, S.moving, !S.ground, dt);
    player.tag.visible = !(M.hider && (M.phase === 'hide' || M.phase === 'seek'));
    if (opp) { const f = 1 - Math.exp(-dt * 14);
      opp.g.position.x += (opp.tx - opp.g.position.x) * f; opp.g.position.y += (opp.ty - opp.g.position.y) * f; opp.g.position.z += (opp.tz - opp.g.position.z) * f;
      let d = opp.tr - opp.g.rotation.y; d = Math.atan2(Math.sin(d), Math.cos(d)); opp.g.rotation.y += d * f; animate(opp, !!opp.m, !!opp.air, dt);
      let inSmoke = false; for (const s of smokes) if (Math.hypot(opp.g.position.x - s.x, opp.g.position.z - s.z) < s.r * s.m.scale.x) inSmoke = true;
      const hunting = !M.hider && (M.phase === 'hide' || M.phase === 'seek');
      opp.g.visible = !(inSmoke && !M.hider) && !(M.phase === 'hide' && !M.hider);
      opp.tag.visible = !hunting;   // the hunter gets no name tag over the hider
      opp.bubble.visible = !hunting;
    }
    for (const av of [player, opp]) if (av && av.bubbleT && t - av.bubbleT > 2.2) { av.bubble.material.opacity = 0; av.bubbleT = 0; }
    for (const c of clouds) { c.sp.position.x += c.v * dt; if (c.sp.position.x > 110) c.sp.position.x = -110; }
    fxTick(dt); updateCam(); netTick(t);
    if (t < S.frozenUntil) onHud.freeze && onHud.freeze(S.frozenUntil - t); else if (S.frozenUntil && t - S.frozenUntil < 0.5) { onHud.freeze && onHud.freeze(0); S.frozenUntil = 0; }
    renderer.render(scene, camera);
  }
  function resize() {
    if (!renderer) return;
    canvas.style.width = '100%'; canvas.style.height = '';   // let the layout settle before measuring (a wide canvas would hold the column open)
    const w = wrap.clientWidth, h = wrap.classList.contains('obby-fs') ? window.innerHeight : Math.max(240, Math.min(Math.round(window.innerHeight * 0.7), Math.round(w * 0.6)));
    renderer.setSize(w, h, false); canvas.style.width = w + 'px'; canvas.style.height = h + 'px'; camera.aspect = w / h; camera.updateProjectionMatrix();
  }

  /* ---------- public ---------- */
  async function init(opts) {
    sb = opts.sb; me = opts.me; wrap = opts.wrap; canvas = opts.canvas; Object.assign(onHud, opts.on || {});
    if (!window.THREE) await new Promise((res, rej) => { const s = document.createElement('script'); s.src = 'https://cdn.jsdelivr.net/npm/three@0.150.1/build/three.min.js'; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
    THREE = window.THREE;
    renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5)); renderer.shadowMap.enabled = true; renderer.shadowMap.type = THREE.PCFShadowMap;
    build(); bindInput(); window.addEventListener('resize', resize);
  }
  // m = the match from pvp_state: { id, opp, challenger, hs: { round, hider, phase, secs, t1, t2 }, my_time, opp_time, my_items, status, outcome }
  function update(m) {
    const live = m.status === 'live', hs = m.hs || {};
    const key = m.id + ':' + (hs.round || 0) + ':' + (hs.phase || m.status);
    if (M.id !== m.id) {
      M.id = m.id; M.oppName = m.opp; M.caughtSent = 0; clearRound();
      if (opp) scene.remove(opp.g); opp = avatar(nameColor(m.opp), m.opp); opp.color = null; opp.baseColor = nameColor(m.opp); opp.placed = false; opp.g.position.set(3, 0, 5); scene.add(opp.g);
      if (live) connect(m.id);
    }
    M.items = m.my_items || M.items;
    const hider = hs.hider === me.id;
    if (key !== M.key) {
      const prevPhase = M.phase, prevRound = M.round;
      M.key = key; M.phase = live ? hs.phase : 'done'; M.round = hs.round || 0; M.hider = hider;
      if (live && hs.round !== prevRound) { clearRound(); spawn(); M.caughtSent = 0; setRole(player, me.name, hider ? 'hider' : 'seeker'); if (opp) { setRole(opp, m.opp, hider ? 'seeker' : 'hider'); paint(opp, null); setPose(opp, 'stand'); } }
      if (live && hs.phase === 'seek' && prevPhase === 'hide') { snd.go(); toastLocal(hider ? 'The hunter is coming. Stay still!' : `GO! Find ${m.opp}. ${AMMO} shells`); }
      if (live && hs.phase === 'hide') toastLocal(hider ? 'Hide, paint yourself (F) and pose (R). 25 seconds' : m.opp + ' is hiding…');
      if (live && hs.phase === 'pause') { snd.caught(); const mine = hs.round === 1 ? m.challenger : !m.challenger; const tm = mine ? m.my_time : m.opp_time; toastLocal((mine ? (tm >= 60 ? 'You survived the round!' : `You got shot after ${tm}s`) : (tm >= 60 ? `${m.opp} survived` : `You found them in ${tm}s`)) + (hs.round === 1 ? ' · swapping roles' : '')); }
      if (!live && M.phase === 'done' && opp) { opp.tag.visible = true; opp.g.visible = true; }
      hud();
    }
    M.secs = hs.secs || 0;
    if (!live && ch) { const c = ch; ch = null; joined = false; sb.removeChannel(c).catch(() => {}); }
  }
  function nameColor(n) { let h = 0; for (const c of n || '') h = (h * 31 + c.charCodeAt(0)) >>> 0; const hue = h % 360, s = 0.65, l = 0.55; const f = k => { const kk = (k + hue / 30) % 12, c = s * Math.min(l, 1 - l); return Math.round((l - c * Math.max(-1, Math.min(kk - 3, 9 - kk, 1))) * 255); }; return (f(0) << 16) | (f(8) << 8) | f(4); }
  return {
    async start(opts) { if (!renderer) await init(opts); open = true; last = 0; resize(); if (!raf) frame(); },
    update,
    stop() { open = false; if (raf) cancelAnimationFrame(raf); raf = null; if (ch) { const c = ch; ch = null; joined = false; sb.removeChannel(c).catch(() => {}); } M.id = null; M.key = ''; },
    isOpen: () => open, zoom, cam, _opp: () => opp, _cam3: () => camera, taunt, resize, emote, useItem, setPose: setMyPose, paint: setMyPaint, matchColor: () => { setMyPaint(nearestColor()); snd.paint(); }, palette, fire: () => { fireQ = true; }, ITEMS, POSES, POSE_LABEL, state: S, match: M
  };
})();
