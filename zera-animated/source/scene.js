import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';

// ───────────────────────── basics ─────────────────────────
await Promise.all([document.fonts.load('900 40px Nunito'), document.fonts.load('800 40px Nunito'), document.fonts.load('40px Hand')]);
const W = 720, H = 1280;
const SS = parseFloat(new URLSearchParams(location.search).get('ss') || '1');
const canvas = document.getElementById('c');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(SS);
renderer.setSize(W, H, false);
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 0.98;
renderer.outputColorSpace = THREE.SRGBColorSpace;

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x140a06);
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
scene.environmentIntensity = 0.3;
const camera = new THREE.PerspectiveCamera(29, W / H, 0.1, 60);

function rng(seed) { let a = seed >>> 0; return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
const clamp01 = x => Math.min(1, Math.max(0, x));
const lerp = (a, b, t) => a + (b - a) * t;
const prog = (t, a, b) => clamp01((t - a) / (b - a));
const smooth = x => { x = clamp01(x); return x * x * (3 - 2 * x); };
const easeOut = x => 1 - Math.pow(1 - clamp01(x), 3);
const easeIn = x => Math.pow(clamp01(x), 3);
const easeOutBack = x => { x = clamp01(x); const c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.pow(x - 1, 3) + c1 * Math.pow(x - 1, 2); };
const bounceOut = x => { x = clamp01(x); const n = 7.5625, d = 2.75; if (x < 1 / d) return n * x * x; if (x < 2 / d) return n * (x -= 1.5 / d) * x + 0.75; if (x < 2.5 / d) return n * (x -= 2.25 / d) * x + 0.9375; return n * (x -= 2.625 / d) * x + 0.984375; };

function canvasTex(w, h, draw, { repeat = null, srgb = true } = {}) {
  const c = document.createElement('canvas'); c.width = w; c.height = h;
  const g = c.getContext('2d'); draw(g, w, h);
  const t = new THREE.CanvasTexture(c);
  if (srgb) t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  if (repeat) { t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(repeat[0], repeat[1]); }
  return t;
}
const css = (rgb, m = 1) => `rgb(${rgb.map(v => Math.round(Math.min(255, v * m))).join(',')})`;

function woodTex(base, planks, seed, repeat) {
  return canvasTex(1024, 1024, (g, w, h) => {
    const R = rng(seed), pw = w / planks;
    for (let i = 0; i < planks; i++) {
      g.fillStyle = css(base, 1 + (R() - 0.5) * 0.22); g.fillRect(i * pw, 0, pw + 1, h);
      for (let k = 0; k < 60; k++) {
        g.strokeStyle = `rgba(60,25,8,${0.04 + R() * 0.12})`; g.lineWidth = 1 + R() * 3;
        const x = i * pw + R() * pw; g.beginPath(); g.moveTo(x, 0);
        g.bezierCurveTo(x + (R() - 0.5) * 26, h * 0.33, x + (R() - 0.5) * 26, h * 0.66, x + (R() - 0.5) * 16, h); g.stroke();
      }
      for (let k = 0; k < 14; k++) { g.strokeStyle = `rgba(255,220,170,${0.03 + R() * 0.06})`; g.lineWidth = 1 + R() * 2; const x = i * pw + R() * pw; g.beginPath(); g.moveTo(x, 0); g.lineTo(x + (R() - 0.5) * 10, h); g.stroke(); }
      g.fillStyle = 'rgba(30,12,4,0.8)'; g.fillRect(i * pw - 2, 0, 4, h);
      g.fillRect(i * pw, R() * h, pw, 3);
    }
  }, { repeat });
}

// ───────────────────────── fur ─────────────────────────
const furCanvasTex = canvasTex(512, 512, (g, w, h) => {
  g.fillStyle = '#000'; g.fillRect(0, 0, w, h);
  const R = rng(7);
  for (let i = 0; i < 11000; i++) {
    const x = R() * w, y = R() * h, r = 2.4 + R() * 2.6, a = 0.3 + R() * 0.7;
    for (const ox of [0, -w, w]) for (const oy of [0, -h, h]) {
      if (x + ox < -r || x + ox > w + r || y + oy < -r || y + oy > h + r) continue;
      const gr = g.createRadialGradient(x + ox, y + oy, 0, x + ox, y + oy, r);
      gr.addColorStop(0, `rgba(255,255,255,${a})`); gr.addColorStop(1, 'rgba(255,255,255,0)');
      g.fillStyle = gr; g.fillRect(x + ox - r, y + oy - r, 2 * r, 2 * r);
    }
  }
}, { srgb: false });

function furify(geo, { len, shells, root, tip, repeat, vertexColors = false, droop = 0.3, sheen = 0x000000 }) {
  const grp = new THREE.Group();
  const tex = furCanvasTex.clone(); tex.needsUpdate = true;
  tex.wrapS = tex.wrapT = THREE.RepeatWrapping; tex.repeat.set(repeat[0], repeat[1]);
  const cr = new THREE.Color(root), ct = new THREE.Color(tip);
  const base = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color: cr.clone().multiplyScalar(0.85), roughness: 1, vertexColors }));
  base.castShadow = true; base.receiveShadow = true; grp.add(base);
  const P = geo.attributes.position, N = geo.attributes.normal;
  for (let i = 1; i <= shells; i++) {
    const f = i / shells, g2 = geo.clone(), p = g2.attributes.position;
    for (let k = 0; k < p.count; k++) p.setXYZ(k, P.getX(k) + N.getX(k) * len * f, P.getY(k) + N.getY(k) * len * f - droop * len * f * f, P.getZ(k) + N.getZ(k) * len * f);
    const m = new THREE.MeshPhysicalMaterial({ color: cr.clone().lerp(ct, Math.pow(f, 0.55)), roughness: 1, alphaMap: tex, alphaTest: 0.05 + f * 0.82, vertexColors,
      sheen: 1, sheenColor: new THREE.Color(sheen), sheenRoughness: 0.5 });
    const mesh = new THREE.Mesh(g2, m); mesh.receiveShadow = true; grp.add(mesh);
  }
  return grp;
}

// ───────────────────────── room ─────────────────────────
const room = new THREE.Group(); scene.add(room);
{
  const floorT = woodTex([150, 84, 40], 7, 11, [3.2, 3.2]); floorT.rotation = 0.42;
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(16, 14), new THREE.MeshStandardMaterial({ map: floorT, roughness: 0.55, metalness: 0.0 }));
  floor.rotation.x = -Math.PI / 2; floor.position.z = 3; floor.receiveShadow = true; room.add(floor);

  const wallT = canvasTex(512, 512, (g, w, h) => { g.fillStyle = '#8f5f3e'; g.fillRect(0, 0, w, h); const R = rng(3); for (let i = 0; i < 2600; i++) { g.fillStyle = `rgba(${R() < 0.5 ? '255,220,180' : '70,35,15'},${R() * 0.06})`; const s = 6 + R() * 40; g.fillRect(R() * w, R() * h, s, s * (0.3 + R())); } }, { repeat: [3, 2] });
  const wall = new THREE.Mesh(new THREE.PlaneGeometry(16, 9), new THREE.MeshStandardMaterial({ map: wallT, roughness: 0.95 }));
  wall.position.set(0, 4.5, -1.75); wall.receiveShadow = true; room.add(wall);
  const baseB = new THREE.Mesh(new THREE.BoxGeometry(16, 0.22, 0.06), new THREE.MeshStandardMaterial({ color: 0x5a3018, roughness: 0.7 }));
  baseB.position.set(0, 0.11, -1.72); room.add(baseB);

  // chalkboard
  const frameM = new THREE.MeshStandardMaterial({ map: woodTex([120, 66, 30], 3, 21, [1, 1]), roughness: 0.6 });
  const cbFrame = new THREE.Mesh(new RoundedBoxGeometry(3.0, 2.3, 0.1, 3, 0.03), frameM);
  cbFrame.position.set(0.75, 2.95, -1.7); cbFrame.receiveShadow = true; cbFrame.castShadow = true; room.add(cbFrame);
  const cbT = canvasTex(512, 512, (g, w, h) => { g.fillStyle = '#2c4a3b'; g.fillRect(0, 0, w, h); const R = rng(5); for (let i = 0; i < 260; i++) { g.strokeStyle = `rgba(220,240,225,${R() * 0.035})`; g.lineWidth = 8 + R() * 40; g.beginPath(); const x = R() * w, y = R() * h; g.moveTo(x, y); g.lineTo(x + (R() - 0.5) * 300, y + (R() - 0.5) * 60); g.stroke(); } });
  const cb = new THREE.Mesh(new THREE.PlaneGeometry(2.78, 2.08), new THREE.MeshStandardMaterial({ map: cbT, roughness: 0.9 }));
  cb.position.set(0.75, 2.95, -1.645); cb.receiveShadow = true; room.add(cb);

  // shelves + books
  const shelfM = new THREE.MeshStandardMaterial({ color: 0x7a4722, roughness: 0.7 });
  const R = rng(42);
  for (const sy of [2.62, 1.72]) {
    const sh = new THREE.Mesh(new THREE.BoxGeometry(1.5, 0.07, 0.36), shelfM); sh.position.set(-1.55, sy, -1.56); sh.castShadow = true; sh.receiveShadow = true; room.add(sh);
    let x = -2.1; const cols = [0x8c5a3c, 0xd9c9a8, 0x5c3a2a, 0xa9744a, 0x3d4a3a, 0xc9b28a];
    for (let i = 0; i < 9; i++) { const bw = 0.07 + R() * 0.06, bh = 0.32 + R() * 0.16; const b = new THREE.Mesh(new THREE.BoxGeometry(bw, bh, 0.24), new THREE.MeshStandardMaterial({ color: cols[Math.floor(R() * cols.length)], roughness: 0.8 })); b.position.set(x + bw / 2, sy + 0.035 + bh / 2, -1.56); b.rotation.z = (R() - 0.5) * 0.08; b.castShadow = true; room.add(b); x += bw + 0.008; }
  }

  // hanging plant
  const leafG = new THREE.SphereGeometry(1, 12, 8); leafG.scale(0.13, 0.016, 0.085);
  const Rp = rng(9);
  const pot = new THREE.Mesh(new THREE.CylinderGeometry(0.2, 0.15, 0.24, 20), new THREE.MeshStandardMaterial({ color: 0x8a4b2a, roughness: 0.8 })); pot.position.set(-0.28, 4.25, -1.25); room.add(pot);
  for (let v = 0; v < 5; v++) {
    const x0 = -0.28 + (Rp() - 0.5) * 0.5, z0 = -1.25 + (Rp() - 0.5) * 0.3, L = 0.4 + Rp() * 0.7, sway = (Rp() - 0.5) * 0.5;
    for (let s = 0; s < L; s += 0.105) {
      const m = new THREE.Mesh(leafG, new THREE.MeshStandardMaterial({ color: new THREE.Color().setHSL(0.26 + Rp() * 0.05, 0.5, 0.13 + Rp() * 0.10), roughness: 0.6 }));
      m.position.set(x0 + sway * s * s + (Rp() - 0.5) * 0.12, 4.18 - s, z0 + (Rp() - 0.5) * 0.12);
      m.rotation.set((Rp() - 0.5) * 1.6, Rp() * 6.28, (Rp() - 0.5) * 1.6); m.scale.setScalar(0.7 + Rp() * 0.6); m.castShadow = true; room.add(m);
    }
  }

  // lamp
  const lamp = new THREE.Group(); lamp.position.set(-1.02, 3.72, -0.75); lamp.rotation.z = -0.55; room.add(lamp);
  const shadeOut = new THREE.Mesh(new THREE.ConeGeometry(0.36, 0.34, 40, 1, true), new THREE.MeshStandardMaterial({ color: 0x2a1c14, roughness: 0.45, metalness: 0.6 }));
  const shadeIn = new THREE.Mesh(new THREE.ConeGeometry(0.35, 0.335, 40, 1, true), new THREE.MeshBasicMaterial({ color: 0xffb060, side: THREE.BackSide }));
  const capM = new THREE.Mesh(new THREE.CylinderGeometry(0.07, 0.09, 0.12, 20), shadeOut.material); capM.position.y = 0.2;
  const armL = new THREE.Mesh(new THREE.CylinderGeometry(0.025, 0.025, 1.6, 10), shadeOut.material); armL.position.set(0, 1.0, 0);
  const bulb = new THREE.Mesh(new THREE.SphereGeometry(0.11, 20, 14), new THREE.MeshBasicMaterial({ color: 0xfff2cc })); bulb.position.y = -0.1;
  lamp.add(shadeOut, shadeIn, capM, armL, bulb);
  const glowT = canvasTex(256, 256, (g, w, h) => { const gr = g.createRadialGradient(w / 2, h / 2, 0, w / 2, h / 2, w / 2); gr.addColorStop(0, 'rgba(255,214,150,0.9)'); gr.addColorStop(0.25, 'rgba(255,170,80,0.35)'); gr.addColorStop(1, 'rgba(255,140,40,0)'); g.fillStyle = gr; g.fillRect(0, 0, w, h); });
  const glow = new THREE.Sprite(new THREE.SpriteMaterial({ map: glowT, blending: THREE.AdditiveBlending, depthWrite: false, transparent: true, opacity: 0.85 }));
  glow.scale.set(3.4, 3.4, 1); glow.position.set(-0.93, 3.58, -0.7); room.add(glow);
}

// crate
const CRATE_TOP = 0.75, ZX = -0.52;
{
  const crateM = new THREE.MeshStandardMaterial({ map: woodTex([170, 100, 46], 4, 31, [1, 1]), roughness: 0.75 });
  const crate = new THREE.Mesh(new RoundedBoxGeometry(1.22, CRATE_TOP, 1.0, 3, 0.02), crateM);
  crate.position.set(ZX, CRATE_TOP / 2, 0); crate.castShadow = true; crate.receiveShadow = true; scene.add(crate);
  const slatM = new THREE.MeshStandardMaterial({ map: woodTex([184, 112, 54], 1, 33, [1, 1]), roughness: 0.75 });
  const add = (w, h, d, x, y, z) => { const m = new THREE.Mesh(new RoundedBoxGeometry(w, h, d, 2, 0.012), slatM); m.position.set(ZX + x, y, z); m.castShadow = true; m.receiveShadow = true; scene.add(m); };
  for (const sx of [-0.58, 0.58]) add(0.11, CRATE_TOP + 0.02, 0.11, sx, CRATE_TOP / 2, 0.47);
  for (const sy of [0.07, 0.69]) add(1.26, 0.12, 0.05, 0, sy, 0.5);
  add(1.06, 0.03, 0.03, 0, 0.38, 0.505);
  for (const sx of [-0.61, 0.61]) for (const sy of [0.07, 0.69]) { const m = new THREE.Mesh(new RoundedBoxGeometry(0.05, 0.12, 1.02, 2, 0.012), slatM); m.position.set(ZX + sx, sy, 0); m.castShadow = true; scene.add(m); }
}

// pedestal + deploy button
const BTN = new THREE.Vector3(0.42, 0, 0.62);
const btn = {};
{
  const ped = new THREE.Mesh(new RoundedBoxGeometry(0.46, 0.84, 0.46, 3, 0.02), new THREE.MeshStandardMaterial({ map: woodTex([128, 74, 36], 3, 51, [1, 1]), roughness: 0.7 }));
  ped.position.set(BTN.x, 0.42, BTN.z); ped.castShadow = true; ped.receiveShadow = true; scene.add(ped);
  const hazT = canvasTex(512, 64, (g, w, h) => { g.fillStyle = '#ffd21f'; g.fillRect(0, 0, w, h); g.fillStyle = '#16130f'; for (let x = -64; x < w + 64; x += 64) { g.beginPath(); g.moveTo(x, h); g.lineTo(x + 32, h); g.lineTo(x + 64, 0); g.lineTo(x + 32, 0); g.fill(); } });
  const base = new THREE.Mesh(new THREE.CylinderGeometry(0.19, 0.2, 0.09, 40), [new THREE.MeshStandardMaterial({ map: hazT, roughness: 0.5 }), new THREE.MeshStandardMaterial({ color: 0x222026, roughness: 0.5 }), new THREE.MeshStandardMaterial({ color: 0x222026 })]);
  base.position.set(BTN.x, 0.885, BTN.z); base.castShadow = true; scene.add(base);
  btn.mat = new THREE.MeshPhysicalMaterial({ color: 0xe31b23, roughness: 0.18, clearcoat: 1, clearcoatRoughness: 0.1, emissive: 0xff1010, emissiveIntensity: 0.25 });
  btn.dome = new THREE.Mesh(new THREE.SphereGeometry(0.15, 40, 20, 0, Math.PI * 2, 0, Math.PI / 2), btn.mat);
  btn.dome.scale.y = 0.72; btn.dome.position.set(BTN.x, 0.925, BTN.z); btn.dome.castShadow = true; scene.add(btn.dome);
  btn.top = new THREE.Vector3(BTN.x, 1.0, BTN.z);
  const lblT = canvasTex(512, 200, (g, w, h) => { g.fillStyle = '#17141a'; g.fillRect(0, 0, w, h); g.strokeStyle = '#ffd21f'; g.lineWidth = 14; g.strokeRect(10, 10, w - 20, h - 20); g.fillStyle = '#fff'; g.font = '900 104px Nunito'; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText('DEPLOY', w / 2, h / 2 + 6); });
  const lbl = new THREE.Mesh(new THREE.PlaneGeometry(0.38, 0.15), new THREE.MeshStandardMaterial({ map: lblT, roughness: 0.5 }));
  lbl.position.set(BTN.x, 0.69, BTN.z + 0.232); scene.add(lbl);
}

// ───────────────────────── whiteboard ─────────────────────────
const board = new THREE.Group(); board.position.set(0.68, 1.98, -0.34); board.rotation.y = -0.2; scene.add(board);
const BW = 1.12, BH = 1.30, BCW = 880, BCH = 1024;
const bCan = document.createElement('canvas'); bCan.width = BCW; bCan.height = BCH; const bg = bCan.getContext('2d');
const bTex = new THREE.CanvasTexture(bCan); bTex.colorSpace = THREE.SRGBColorSpace; bTex.anisotropy = 8;
const boardMat = new THREE.MeshStandardMaterial({ map: bTex, roughness: 0.35, emissive: 0xffffff, emissiveMap: bTex, emissiveIntensity: 0.22 });
{
  const frame = new THREE.Mesh(new RoundedBoxGeometry(BW + 0.1, BH + 0.1, 0.05, 4, 0.025), new THREE.MeshStandardMaterial({ color: 0xcfcfd4, roughness: 0.35, metalness: 0.6 }));
  frame.castShadow = true; board.add(frame);
  const face = new THREE.Mesh(new THREE.PlaneGeometry(BW, BH), boardMat); face.position.z = 0.027; face.receiveShadow = true; board.add(face);
  const capMat = new THREE.MeshStandardMaterial({ color: 0x4a4a52, roughness: 0.5 });
  for (const sx of [-1, 1]) for (const sy of [-1, 1]) { const c = new THREE.Mesh(new RoundedBoxGeometry(0.13, 0.13, 0.07, 3, 0.03), capMat); c.position.set(sx * (BW / 2), sy * (BH / 2), 0); board.add(c); }
  const tray = new THREE.Mesh(new RoundedBoxGeometry(0.8, 0.035, 0.1, 2, 0.01), frame.material); tray.position.set(0, -BH / 2 - 0.05, 0.06); board.add(tray);
  const legM = new THREE.MeshStandardMaterial({ color: 0xd9cdbb, roughness: 0.4, metalness: 0.3 });
  const leg = (x0, x1, z1) => { const a = new THREE.Vector3(x0, -BH / 2, -0.02), b = new THREE.Vector3(x1, -1.98, z1); const m = new THREE.Mesh(new THREE.CylinderGeometry(0.024, 0.024, a.distanceTo(b), 12), legM); m.position.copy(a).lerp(b, 0.5); m.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), b.clone().sub(a).normalize()); m.castShadow = true; board.add(m); const f = new THREE.Mesh(new THREE.CylinderGeometry(0.04, 0.045, 0.08, 12), capMat); f.position.set(b.x, b.y + 0.04, b.z); board.add(f); };
  leg(-0.42, -0.55, 0.12); leg(0.42, 0.55, 0.12); leg(0, 0, -0.7);
}

function rrect(g, x, y, w, h, r) { g.beginPath(); g.roundRect(x, y, w, h, r); }
function drawBoard(s) {
  const g = bg, w = BCW, h = BCH;
  g.setTransform(1, 0, 0, 1, 0, 0); g.textAlign = 'center'; g.textBaseline = 'alphabetic';
  if (s.state === 'A') {
    g.fillStyle = '#fbfaf5'; g.fillRect(0, 0, w, h);
    g.save(); g.shadowColor = 'rgba(0,0,0,0.22)'; g.shadowBlur = 30; g.shadowOffsetY = 12; g.fillStyle = '#fff'; rrect(g, 170, 96, 540, 520, 38); g.fill(); g.restore();
    g.save(); rrect(g, 170, 96, 540, 520, 38); g.clip(); g.fillStyle = '#e5383b'; g.fillRect(170, 96, 540, 156); g.restore();
    g.fillStyle = '#3a3a44'; for (const x of [300, 580]) { rrect(g, x - 13, 66, 26, 66, 13); g.fill(); }
    g.fillStyle = '#fff'; g.font = '900 104px Nunito'; g.fillText('FRIDAY', 440, 212);
    g.fillStyle = '#1b1b22'; g.font = '900 210px Nunito'; g.fillText('4:59', 440, 470);
    g.fillStyle = '#8a8a95'; g.font = '800 70px Nunito'; g.fillText('PM', 440, 568);
    g.fillStyle = '#2b2140'; g.font = '104px Hand'; g.fillText('deploy to prod?', 440, 770);
    g.save(); g.translate(440, 880); g.rotate(-0.04); g.fillStyle = '#7c3aed'; g.font = '72px Hand'; g.fillText('what could go wrong', 0, 0);
    g.strokeStyle = '#7c3aed'; g.lineWidth = 6; g.lineCap = 'round'; g.beginPath(); for (let x = -250; x <= 250; x += 10) { const y = 24 + Math.sin(x * 0.06) * 6; x === -250 ? g.moveTo(x, y) : g.lineTo(x, y); } g.stroke(); g.restore();
    if (s.circ > 0) { g.save(); g.translate(440, 176); g.rotate(-0.05); g.strokeStyle = '#7c3aed'; g.lineWidth = 14; g.lineCap = 'round'; g.beginPath(); const n = Math.floor(80 * s.circ); for (let i = 0; i <= n; i++) { const a = -2.5 + i / 80 * Math.PI * 2.12, rx = 300 + i * 0.25, ry = 108 + Math.sin(i * 0.3) * 4; const x = Math.cos(a) * rx, y = Math.sin(a) * ry; i === 0 ? g.moveTo(x, y) : g.lineTo(x, y); } g.stroke(); g.restore(); }
  } else if (s.state === 'B') {
    g.fillStyle = '#fff7f5'; g.fillRect(0, 0, w, h);
    g.fillStyle = `rgba(255,40,40,${0.10 + 0.10 * s.pulse})`; g.fillRect(0, 0, w, h);
    g.fillStyle = '#2b2140'; g.font = '104px Hand'; g.fillText('deploying to prod' + '.'.repeat(s.dots), 440, 230);
    g.fillStyle = '#e6dede'; rrect(g, 80, 310, 720, 116, 58); g.fill();
    const gr = g.createLinearGradient(80, 0, 800, 0); gr.addColorStop(0, '#ff3d3d'); gr.addColorStop(1, '#ffb03a');
    g.save(); rrect(g, 80, 310, 720, 116, 58); g.clip(); g.fillStyle = gr; g.fillRect(80, 310, 720 * s.p, 116);
    g.fillStyle = 'rgba(255,255,255,0.28)'; for (let x = -200 + (s.scroll % 80); x < 720 * s.p + 80; x += 80) { g.beginPath(); g.moveTo(80 + x, 426); g.lineTo(80 + x + 40, 426); g.lineTo(80 + x + 90, 310); g.lineTo(80 + x + 50, 310); g.fill(); } g.restore();
    g.strokeStyle = '#3a3a44'; g.lineWidth = 8; rrect(g, 80, 310, 720, 116, 58); g.stroke();
    g.fillStyle = '#d42a2a'; g.font = '900 250px Nunito'; g.fillText(Math.floor(s.p * 100) + '%', 440 + s.jx, 700 + s.jy);
    g.fillStyle = '#2b2140'; g.font = '92px Hand'; g.save(); g.translate(440 + s.jy * 2, 890 + s.jx * 2); g.rotate(s.jx * 0.004); g.fillText('pls pls pls pls', 0, 0); g.restore();
  } else {
    g.fillStyle = '#e9fbea'; g.fillRect(0, 0, w, h);
    g.save(); g.translate(440, 350); g.scale(s.pop, s.pop); g.fillStyle = '#22c55e'; g.beginPath(); g.arc(0, 0, 230, 0, Math.PI * 2); g.fill();
    g.strokeStyle = '#fff'; g.lineWidth = 52; g.lineCap = 'round'; g.lineJoin = 'round'; g.beginPath();
    const pts = [[-112, 6], [-34, 88], [118, -78]], c = clamp01(s.check) * 2; g.moveTo(pts[0][0], pts[0][1]);
    if (c > 0) { const a = Math.min(1, c); g.lineTo(lerp(pts[0][0], pts[1][0], a), lerp(pts[0][1], pts[1][1], a)); }
    if (c > 1) { const a = c - 1; g.lineTo(lerp(pts[1][0], pts[2][0], a), lerp(pts[1][1], pts[2][1], a)); }
    if (c > 0) g.stroke(); g.restore();
    g.fillStyle = '#15803d'; g.font = '900 150px Nunito'; g.fillText('0 errors', 440, 760);
    g.fillStyle = '#2b2140'; g.font = '104px Hand'; g.fillText('on a Friday.', 440, 890);
    g.strokeStyle = '#7c3aed'; g.lineWidth = 8; g.lineCap = 'round'; g.beginPath(); g.moveTo(230, 920); g.quadraticCurveTo(440, 944, 650, 916); g.stroke();
  }
  bTex.needsUpdate = true;
}

// ───────────────────────── Zera ─────────────────────────
const zera = new THREE.Group(); zera.position.set(ZX, CRATE_TOP, 0.02); zera.scale.setScalar(0.92); scene.add(zera);
const squash = new THREE.Group(); zera.add(squash);
const body = new THREE.Group(); body.position.y = 0.42; squash.add(body);
const headPivot = new THREE.Group(); headPivot.position.y = 0.66; squash.add(headPivot);
const head = new THREE.Group(); head.position.y = 0.44; headPivot.add(head);

const HR = { x: 0.66, y: 0.56, z: 0.60 };
function headDeform(v) { const y = v.y, w = 1 + 0.10 * Math.max(-y, 0) - 0.16 * Math.pow(Math.max(y, 0), 2); return new THREE.Vector3(v.x * HR.x * w, y * HR.y * (y < 0 ? 0.92 : 1), v.z * HR.z * w); }
function onHead(dx, dy, dz, lift = 0) { const v = new THREE.Vector3(dx, dy, dz).normalize(), p = headDeform(v); const n = new THREE.Vector3(p.x / HR.x ** 2, p.y / HR.y ** 2, p.z / HR.z ** 2).normalize(); p.addScaledVector(n, lift); return { p, n, q: new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 0, 1), n) }; }
const FUR = 0.05;
{
  const g = new THREE.SphereGeometry(1, 96, 64); g.rotateY(-Math.PI / 2);
  const p = g.attributes.position, col = new Float32Array(p.count * 3), v = new THREE.Vector3();
  const cheeks = [new THREE.Vector3(-0.66, -0.34, 0.67).normalize(), new THREE.Vector3(0.66, -0.34, 0.67).normalize()];
  for (let i = 0; i < p.count; i++) {
    v.fromBufferAttribute(p, i).normalize();
    let b = 0; for (const c of cheeks) b = Math.max(b, 1 - smooth((v.distanceTo(c) - 0.10) / 0.24));
    col[i * 3] = 1; col[i * 3 + 1] = lerp(1, 0.50, b); col[i * 3 + 2] = lerp(1, 0.58, b);
    const d = headDeform(v); p.setXYZ(i, d.x, d.y, d.z);
  }
  g.setAttribute('color', new THREE.BufferAttribute(col, 3)); g.computeVertexNormals();
  head.add(furify(g, { len: FUR, shells: 24, root: 0xb98a68, tip: 0xf3d3b6, repeat: [6.5, 3.1], vertexColors: true, sheen: 0x6a4a36 }));
}
// eyes
const eyeMat = new THREE.MeshPhysicalMaterial({ color: 0x060507, roughness: 0.06, clearcoat: 1, clearcoatRoughness: 0.03 });
const inkMat = new THREE.MeshBasicMaterial({ color: 0x2a1614 });
function stroke(ax, ay, bx, by, r, mat = inkMat) { const len = Math.hypot(bx - ax, by - ay); const m = new THREE.Mesh(new THREE.CapsuleGeometry(r, len, 6, 12), mat); m.position.set((ax + bx) / 2, (ay + by) / 2, 0); m.rotation.z = Math.atan2(by - ay, bx - ax) - Math.PI / 2; return m; }
function makeEye(side) {
  const { p, q } = onHead(side * 0.40, -0.03, 0.92, 0.022); const g = new THREE.Group(); g.position.copy(p); g.quaternion.copy(q);
  const open = new THREE.Group();
  const ball = new THREE.Mesh(new THREE.SphereGeometry(0.122, 48, 32), eyeMat); ball.scale.set(1, 1.08, 0.62);
  const wm = new THREE.MeshBasicMaterial({ color: 0xffffff });
  const h1 = new THREE.Mesh(new THREE.SphereGeometry(0.031, 16, 12), wm); h1.position.set(-0.038, 0.05, 0.062); h1.scale.z = 0.5;
  const h2 = new THREE.Mesh(new THREE.SphereGeometry(0.014, 12, 8), wm); h2.position.set(0.042, -0.04, 0.066); h2.scale.z = 0.5;
  open.add(ball, h1, h2);
  const chev = new THREE.Group(); chev.add(stroke(-side * -0.075, 0.065, -side * 0.065, 0, 0.017), stroke(-side * -0.075, -0.065, -side * 0.065, 0, 0.017)); chev.position.z = 0.07; chev.visible = false;
  g.add(open, chev); head.add(g); return { g, open, chev, h1, h2 };
}
const eyeL = makeEye(-1), eyeR = makeEye(1);
// brows
const browMat = new THREE.MeshBasicMaterial({ color: 0xb98a66 });
function makeBrow(side) { const { p, q } = onHead(side * 0.37, 0.37, 0.86, FUR + 0.006); const g = new THREE.Group(); g.position.copy(p); g.quaternion.copy(q); const m = new THREE.Mesh(new THREE.CapsuleGeometry(0.019, 0.085, 6, 12), browMat); m.rotation.z = Math.PI / 2; g.add(m); head.add(g); return { g, base: p.clone(), q: q.clone() }; }
const browL = makeBrow(-1), browR = makeBrow(1);
// mouth
const mouth = (() => {
  const { p, q } = onHead(0, -0.23, 0.97, FUR + 0.004); const g = new THREE.Group(); g.position.copy(p); g.quaternion.copy(q); head.add(g);
  const dark = new THREE.MeshBasicMaterial({ color: 0x4a1a1e }), pink = new THREE.MeshBasicMaterial({ color: 0xff8a9a });
  const o = new THREE.Group(); const oBg = new THREE.Mesh(new THREE.CircleGeometry(0.05, 32), dark); const oT = new THREE.Mesh(new THREE.CircleGeometry(0.03, 24), pink); oT.position.set(0, -0.022, 0.002); oT.scale.y = 0.7; o.add(oBg, oT);
  const d = new THREE.Group(); const dBg = new THREE.Mesh(new THREE.CircleGeometry(0.105, 40, Math.PI, Math.PI), dark); const dT = new THREE.Mesh(new THREE.CircleGeometry(0.055, 24), pink); dT.position.set(0, -0.07, 0.002); dT.scale.y = 0.6; d.add(dBg, dT); d.position.y = 0.035;
  const arc = new THREE.Mesh(new THREE.TorusGeometry(0.06, 0.011, 8, 24, Math.PI * 0.7), inkMat); arc.rotation.z = Math.PI + Math.PI * 0.15; arc.position.y = 0.04;
  g.add(o, d, arc); return { g, o, oT, d, arc };
})();
// hair swirl
{
  const curve = new THREE.CatmullRomCurve3([[-0.04, 0.30, 0.04], [-0.12, 0.52, 0.05], [-0.06, 0.72, 0.05], [0.12, 0.84, 0.05], [0.31, 0.80, 0.05], [0.39, 0.67, 0.05], [0.32, 0.57, 0.05], [0.24, 0.60, 0.05], [0.25, 0.66, 0.05]].map(a => new THREE.Vector3(...a)));
  const segs = 90, radial = 28, frames = curve.computeFrenetFrames(segs, false);
  const pos = [], uv = [], col = [], idx = [];
  const stops = [[0, new THREE.Color(0xc98ff5)], [0.22, new THREE.Color(0x9a62f5)], [0.45, new THREE.Color(0x4f6dff)], [0.75, new THREE.Color(0x1f8dff)], [1, new THREE.Color(0x3fc4ff)]];
  const colAt = u => { for (let i = 1; i < stops.length; i++) if (u <= stops[i][0]) return stops[i - 1][1].clone().lerp(stops[i][1], (u - stops[i - 1][0]) / (stops[i][0] - stops[i - 1][0])); return stops[stops.length - 1][1].clone(); };
  for (let i = 0; i <= segs; i++) {
    const u = i / segs, P = curve.getPointAt(u), N = frames.normals[i], B = frames.binormals[i], r = 0.30 * (1 - Math.pow(u, 1.5)) + 0.012;
    for (let j = 0; j <= radial; j++) {
      const a = j / radial * Math.PI * 2, cx = Math.cos(a) * r, cy = Math.sin(a) * r; const zs = Math.abs(B.z) > 0.5 ? 0.78 : 1, ns = Math.abs(N.z) > 0.5 ? 0.78 : 1;
      pos.push(P.x + cx * N.x * ns + cy * B.x * zs, P.y + cx * N.y * ns + cy * B.y * zs, P.z + cx * N.z * ns + cy * B.z * zs); uv.push(j / radial, u);
      const c = colAt(clamp01(u + 0.10 * Math.sin(a * 2 + u * 9))); col.push(c.r, c.g, c.b);
    }
  }
  for (let i = 0; i < segs; i++) for (let j = 0; j < radial; j++) { const a = i * (radial + 1) + j, b = a + radial + 1; idx.push(a, b, a + 1, b, b + 1, a + 1); }
  const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2)); g.setAttribute('color', new THREE.Float32BufferAttribute(col, 3)); g.setIndex(idx); g.computeVertexNormals();
  { const k = 10 * (radial + 1), c = curve.getPointAt(10 / segs); const vx = pos[k * 3] - c.x, vy = pos[k * 3 + 1] - c.y, vz = pos[k * 3 + 2] - c.z; const n = g.attributes.normal; if (vx * n.getX(k) + vy * n.getY(k) + vz * n.getZ(k) < 0) { for (let i = 0; i < idx.length; i += 3) { const t = idx[i]; idx[i] = idx[i + 1]; idx[i + 1] = t; } g.setIndex(idx); g.computeVertexNormals(); } }
  const hair = furify(g, { len: 0.03, shells: 12, root: 0x8a8a8a, tip: 0xf2f2f2, repeat: [5, 9], vertexColors: true, droop: 0.0, sheen: 0x33405a });
  head.add(hair);
}
// hoodie
const fabricBump = canvasTex(256, 256, (g, w, h) => { const R = rng(77); const id = g.createImageData(w, h); for (let i = 0; i < w * h; i++) { const v = 110 + R() * 90; id.data[i * 4] = id.data[i * 4 + 1] = id.data[i * 4 + 2] = v; id.data[i * 4 + 3] = 255; } g.putImageData(id, 0, 0); }, { srgb: false, repeat: [6, 4] });
const hoodMat = new THREE.MeshPhysicalMaterial({ color: 0x1d1a22, roughness: 0.9, sheen: 1, sheenColor: new THREE.Color(0x7a7290), sheenRoughness: 0.45, bumpMap: fabricBump, bumpScale: 0.8 });
{
  const prof = new THREE.SplineCurve([[0.001, -0.31], [0.30, -0.315], [0.43, -0.27], [0.475, -0.12], [0.455, 0.03], [0.39, 0.17], [0.28, 0.28], [0.14, 0.33], [0.001, 0.34]].map(a => new THREE.Vector2(...a))).getPoints(48);
  const torso = new THREE.Mesh(new THREE.LatheGeometry(prof, 56), hoodMat); torso.scale.z = 0.92; torso.castShadow = true; torso.receiveShadow = true; body.add(torso);
  const hem = new THREE.Mesh(new THREE.TorusGeometry(0.415, 0.055, 16, 56), hoodMat); hem.rotation.x = Math.PI / 2; hem.position.y = -0.26; hem.scale.y = 0.92; hem.castShadow = true; body.add(hem);
  const collar = new THREE.Mesh(new THREE.TorusGeometry(0.29, 0.085, 16, 48), hoodMat); collar.rotation.x = Math.PI / 2 + 0.12; collar.position.set(0, 0.25, -0.02); body.add(collar);
  const hood = new THREE.Mesh(new THREE.SphereGeometry(1, 32, 20), hoodMat); hood.scale.set(0.38, 0.22, 0.26); hood.position.set(0, 0.2, -0.3); hood.castShadow = true; body.add(hood);
  const strM = new THREE.MeshStandardMaterial({ color: 0x2c2832, roughness: 0.8 }), tipM = new THREE.MeshStandardMaterial({ color: 0xd9d2e6, roughness: 0.5 });
  for (const sx of [-1, 1]) { const s = new THREE.Mesh(new THREE.CapsuleGeometry(0.011, 0.15, 4, 8), strM); s.position.set(sx * 0.085, 0.13, 0.40); s.rotation.set(-0.5, 0, sx * 0.1); body.add(s); const tp = new THREE.Mesh(new THREE.CapsuleGeometry(0.014, 0.03, 4, 8), tipM); tp.position.set(sx * 0.093, 0.045, 0.438); tp.rotation.copy(s.rotation); body.add(tp); }
  const a = 0.105, b = 0.115, t = 0.052, d = 0.08, z = new THREE.Shape();
  [[-a, b], [a, b], [a, b - t], [-a + d, -b + t], [a, -b + t], [a, -b], [-a, -b], [-a, -b + t], [a - d, b - t], [-a, b - t]].forEach((p, i) => i ? z.lineTo(p[0], p[1]) : z.moveTo(p[0], p[1]));
  const zg = new THREE.ExtrudeGeometry(z, { depth: 0.022, bevelEnabled: true, bevelThickness: 0.012, bevelSize: 0.01, bevelSegments: 3 });
  const zm = new THREE.Mesh(zg, new THREE.MeshStandardMaterial({ color: 0x8b45ff, roughness: 0.5, emissive: 0x3a0f99, emissiveIntensity: 0.6 }));
  zm.position.set(0, -0.06, 0.425); zm.rotation.x = 0.06; body.add(zm);
}
// feet
for (const sx of [-1, 1]) { const g = new THREE.SphereGeometry(1, 32, 24); g.scale(0.165, 0.115, 0.2); const f = furify(g, { len: 0.03, shells: 8, root: 0xb98a68, tip: 0xf3d3b6, repeat: [3.4, 1.7], sheen: 0x6a4a36 }); f.position.set(sx * 0.18, 0.10, 0.07); squash.add(f); }
// arms
function qE(x, y, z) { return new THREE.Quaternion().setFromEuler(new THREE.Euler(x, y, z, 'YZX')); }
function makeArm(side) {
  const arm = new THREE.Group(); arm.position.set(side * 0.37, 0.13, 0.05); arm.userData.axis = new THREE.Vector3(side, 0, 0); body.add(arm);
  const sl = new THREE.Mesh(new THREE.CapsuleGeometry(0.108, 0.15, 8, 16), hoodMat); sl.rotation.z = Math.PI / 2; sl.position.x = side * 0.13; sl.castShadow = true; arm.add(sl);
  const cuff = new THREE.Mesh(new THREE.TorusGeometry(0.082, 0.032, 12, 24), hoodMat); cuff.rotation.y = Math.PI / 2; cuff.position.x = side * 0.25; arm.add(cuff);
  const pg = new THREE.SphereGeometry(0.095, 28, 20); const paw = furify(pg, { len: 0.028, shells: 8, root: 0xb98a68, tip: 0xf3d3b6, repeat: [2.4, 1.2], sheen: 0x6a4a36 }); paw.position.x = side * 0.33; arm.add(paw);
  return arm;
}
const armR = makeArm(1), armL = makeArm(-1);
{
  const mk = new THREE.Group(); armR.add(mk);
  const bodyM = new THREE.Mesh(new THREE.CylinderGeometry(0.028, 0.028, 0.64, 20), new THREE.MeshPhysicalMaterial({ color: 0xdcc8f7, roughness: 0.25, clearcoat: 0.6 })); bodyM.rotation.z = Math.PI / 2; bodyM.position.x = 0.54; bodyM.castShadow = true;
  const cap = new THREE.Mesh(new THREE.CylinderGeometry(0.035, 0.035, 0.14, 20), new THREE.MeshPhysicalMaterial({ color: 0x7c2fe6, roughness: 0.25, clearcoat: 0.6 })); cap.rotation.z = Math.PI / 2; cap.position.x = 0.93; cap.castShadow = true;
  const end = new THREE.Mesh(new THREE.SphereGeometry(0.035, 16, 12), cap.material); end.position.x = 1.0; end.scale.x = 0.6;
  mk.add(bodyM, cap, end);
}
// sunglasses
const shades = new THREE.Group(); head.add(shades); shades.visible = false;
{
  const lensM = new THREE.MeshPhysicalMaterial({ color: 0x050506, roughness: 0.05, clearcoat: 1, clearcoatRoughness: 0.02, metalness: 0.2 });
  const glM = new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.85 });
  for (const sx of [-1, 1]) {
    const l = new THREE.Mesh(new RoundedBoxGeometry(0.37, 0.24, 0.04, 4, 0.06), lensM); l.position.set(sx * 0.255, 0, 0); l.rotation.y = sx * 0.22; l.castShadow = true; shades.add(l);
    const gl = new THREE.Mesh(new THREE.PlaneGeometry(0.03, 0.2), glM); gl.position.set(sx * 0.255 - 0.09, 0.02, 0.03); gl.rotation.z = -0.6; gl.rotation.y = sx * 0.22; shades.add(gl);
    const gl2 = new THREE.Mesh(new THREE.PlaneGeometry(0.014, 0.16), glM); gl2.position.set(sx * 0.255 - 0.04, 0.02, 0.03); gl2.rotation.z = -0.6; gl2.rotation.y = sx * 0.22; shades.add(gl2);
    const tm = new THREE.Mesh(new THREE.BoxGeometry(0.03, 0.035, 0.45), lensM); tm.position.set(sx * 0.47, 0.04, -0.24); tm.rotation.y = sx * 0.2; shades.add(tm);
  }
  const br = new THREE.Mesh(new RoundedBoxGeometry(0.2, 0.05, 0.035, 2, 0.015), lensM); br.position.set(0, 0.07, 0.03); shades.add(br);
}
const SHADES_REST = new THREE.Vector3(0, -0.01, 0.68);
// sweat drop
const sweat = new THREE.Mesh(new THREE.SphereGeometry(0.045, 16, 12), new THREE.MeshPhysicalMaterial({ color: 0x8fd4ff, roughness: 0.05, transmission: 0, clearcoat: 1, emissive: 0x2a6fa8, emissiveIntensity: 0.5 }));
sweat.scale.set(0.8, 1.25, 0.8); sweat.visible = false; head.add(sweat);

// ───────────────────────── confetti ─────────────────────────
const NC = 170; const conf = new THREE.InstancedMesh(new THREE.PlaneGeometry(0.075, 0.045), new THREE.MeshBasicMaterial({ side: THREE.DoubleSide }), NC);
conf.frustumCulled = false; scene.add(conf);
const confData = []; { const R = rng(1234), cols = [0xffd23f, 0xff5d8f, 0x5dff8f, 0x5db8ff, 0xb07bff, 0xffffff, 0xff8a3d];
  for (let i = 0; i < NC; i++) { const left = i % 2 === 0; confData.push({ p0: new THREE.Vector3(left ? -1.5 : 1.5, 0.9 + R() * 0.4, 1.0 + R() * 0.8), v0: new THREE.Vector3((left ? 1 : -1) * (0.6 + R() * 2.6), 5.2 + R() * 5.2, (R() - 0.6) * 1.6), w: new THREE.Vector3(R() * 12 - 6, R() * 12 - 6, R() * 12 - 6), ph: R() * 6.28, delay: R() * 0.12, s: 0.8 + R() * 0.9 }); conf.setColorAt(i, new THREE.Color(cols[Math.floor(R() * cols.length)])); } }
const _m4 = new THREE.Matrix4(), _q = new THREE.Quaternion(), _e = new THREE.Euler(), _s = new THREE.Vector3(), _p = new THREE.Vector3();
function updateConfetti(tau) {
  const k = 1.7, vt = 2.3;
  for (let i = 0; i < NC; i++) { const c = confData[i], t = tau - c.delay;
    if (t <= 0) { _m4.makeScale(0, 0, 0); conf.setMatrixAt(i, _m4); continue; }
    const e = (1 - Math.exp(-k * t)) / k;
    _p.set(c.p0.x + c.v0.x * e + 0.09 * Math.sin(t * 5 + c.ph), c.p0.y + (c.v0.y + vt) * e - vt * t, c.p0.z + c.v0.z * e);
    _e.set(c.w.x * t + c.ph, c.w.y * t, c.w.z * t); _q.setFromEuler(_e); _s.setScalar(c.s); _m4.compose(_p, _q, _s); conf.setMatrixAt(i, _m4); }
  conf.instanceMatrix.needsUpdate = true;
}

// ───────────────────────── lights ─────────────────────────
const hemi = new THREE.HemisphereLight(0xffc890, 0x2e160a, 0.6); scene.add(hemi);
const key = new THREE.DirectionalLight(0xffbb7c, 2.5); key.position.set(-3.2, 5.6, 5.5); key.target.position.set(0, 1.2, 0); scene.add(key, key.target);
key.castShadow = true; key.shadow.mapSize.set(2048, 2048); Object.assign(key.shadow.camera, { left: -3.2, right: 3.2, top: 3.6, bottom: -2.6, near: 1, far: 18 }); key.shadow.bias = -0.0004; key.shadow.normalBias = 0.03; key.shadow.radius = 5;
const lampSpot = new THREE.SpotLight(0xff9a3c, 55, 14, 0.75, 0.9, 1.4); lampSpot.position.set(-0.95, 3.6, -0.6); lampSpot.target.position.set(-0.3, 1.2, 0.2); scene.add(lampSpot, lampSpot.target);
const rim = new THREE.DirectionalLight(0xa9b8ff, 1.5); rim.position.set(3.5, 3.5, -4); rim.target.position.set(-0.4, 1.6, 0); scene.add(rim, rim.target);
const fill = new THREE.DirectionalLight(0xffe0c4, 0.35); fill.position.set(2.5, 2, 6); scene.add(fill);
const alarm = new THREE.PointLight(0xff2010, 0, 7, 1.4); alarm.position.set(0.3, 1.5, 1.4); scene.add(alarm);
const greenL = new THREE.PointLight(0x40ff80, 0, 7, 1.4); greenL.position.set(-0.1, 1.9, 1.6); scene.add(greenL);

// ───────────────────────── timeline ─────────────────────────
let TL = { l1s: 0.25, l1e: 1.85, wind: 2.0, slam: 2.45, done: 3.5, l2s: 3.55, l2e: 4.75, shades: 4.45, end: 6.4, cap1: null, cap2: null };
let mouthEnv = null;
window.setTimeline = tl => { Object.assign(TL, tl); };
window.setMouthEnv = e => { mouthEnv = e; };
window.getDuration = () => TL.end;
function talk(t) {
  if (mouthEnv) { const i = Math.max(0, Math.min(mouthEnv.length - 1, Math.round(t * 30))); return mouthEnv[i] || 0; }
  let w = 0; for (const [a, b] of [[TL.l1s, TL.l1e], [TL.l2s, TL.l2e]]) w = Math.max(w, Math.min(prog(t, a, a + 0.08), 1 - prog(t, b - 0.1, b)));
  return w * Math.pow(0.5 + 0.5 * Math.sin(t * 2 * Math.PI * 5.6 + Math.sin(t * 3.1) * 1.3), 1.4);
}

const capEl = document.getElementById('cap'), tintEl = document.getElementById('tint'), sp1 = document.getElementById('sp1'), sp2 = document.getElementById('sp2');
function setCap(html, tau, wob = 0) { if (!html) { capEl.innerHTML = ''; return; } const s = 0.6 + 0.4 * easeOutBack(tau / 0.2); capEl.innerHTML = `<span class="pill" style="transform:scale(${s.toFixed(3)}) rotate(${wob.toFixed(2)}deg);opacity:${clamp01(tau / 0.07).toFixed(2)}">${html}</span>`; }
const BOARD_PT = new THREE.Vector3(0.60, 1.60, 0.60);
const _v = new THREE.Vector3();
function aim(arm, target) { const local = arm.parent.worldToLocal(_v.copy(target)).sub(arm.position).normalize(); return new THREE.Quaternion().setFromUnitVectors(arm.userData.axis, local); }
function eyeSet(e, mode, sy = 1, pop = 1) { e.open.visible = mode === 'open'; e.chev.visible = mode === 'shut'; e.open.scale.set(pop, pop * sy, 1); }

window.renderAt = function (t) {
  const { l1s, l1e, wind, slam, done, l2s, l2e, shades: tSh, end } = TL;
  const a = talk(t);
  const ts = t - slam, td = t - done, tl = t - (tSh + 0.32); // since slam / done / shades landed
  const inC = t >= slam && t < done, inD = t >= done;
  const joy = td - 0.36; // both eyes open, celebration starts

  // ── board
  const tapT = lerp(l1s, l1e, 0.55);
  if (t < slam) drawBoard({ state: 'A', circ: easeOut(prog(t, tapT, tapT + 0.45)) });
  else if (inC) { const u = ts / (done - slam); const p = u < 0.45 ? lerp(0, 0.87, easeOut(u / 0.45)) : u < 0.68 ? lerp(0.87, 0.99, (u - 0.45) / 0.23) : 0.99; drawBoard({ state: 'B', p, pulse: 0.5 + 0.5 * Math.sin(ts * 2 * Math.PI * 3.2), dots: 1 + Math.floor(ts * 5) % 3, scroll: ts * 220, jx: Math.sin(t * 61) * 5, jy: Math.cos(t * 47) * 5 }); }
  else drawBoard({ state: 'C', pop: easeOutBack(td / 0.3), check: prog(td, 0.08, 0.36) });
  const jolt = (inC ? Math.exp(-ts * 9) : 0) + (inD ? Math.exp(-td * 9) : 0);
  board.scale.setScalar(1 + 0.07 * jolt); board.rotation.z = 0.03 * jolt * Math.sin(t * 60);
  boardMat.emissiveIntensity = inD ? 0.34 : 0.22;

  // ── button
  const press = t >= slam ? (0.6 + 0.4 * Math.exp(-ts * 3)) : 0; btn.dome.position.y = 0.925 - 0.04 * press;
  btn.mat.emissiveIntensity = inC ? 1.2 + 1.2 * Math.sin(ts * 2 * Math.PI * 3.2) : inD ? 0.1 : 0.3 + 0.2 * Math.sin(t * 5);
  btn.mat.emissive.set(inD ? 0x10ff40 : 0xff1010); btn.mat.color.set(inD ? 0x22c55e : 0xe31b23);

  // ── body: hop / squash
  let hop = 0, sq = 1 + 0.035 * a + 0.012 * Math.sin(t * 5.6), yaw = 0.16, lean = 0;
  if (t >= wind && t < slam) { const u = (t - wind) / (slam - wind); if (u < 0.3) sq = 1 - 0.16 * Math.sin(u / 0.3 * Math.PI / 2); else { const s = (u - 0.3) / 0.7; hop = 0.46 * 4 * s * (1 - s); sq = 1 + 0.12 * Math.sin(s * Math.PI) - 0.04 * (1 - s); } yaw = lerp(0.16, 0.5, smooth(u)); }
  if (inC) { sq = 1 - 0.24 * Math.exp(-ts * 9) * Math.cos(ts * 24) - 0.06 * smooth(ts / 0.3); yaw = 0.5; lean = -0.07; }
  if (inD) {
    yaw = lerp(0.5, 0.04, smooth(joy / 0.35)); sq = lerp(0.94, 1, smooth(td / 0.3));
    if (joy > 0 && joy < 0.5) { const s = joy / 0.5; hop = 0.34 * 4 * s * (1 - s); sq = 1 + 0.1 * Math.sin(s * Math.PI); }
    if (joy >= 0.5) sq = 1 - 0.14 * Math.exp(-(joy - 0.5) * 9) * Math.cos((joy - 0.5) * 22) + 0.03 * a;
    if (tl > 0) { sq += 0.03 * Math.sin(tl * 2 * Math.PI * 2.2) * smooth(tl / 0.3); lean = 0.05 * Math.sin(tl * 2 * Math.PI * 1.1) * smooth(tl / 0.3); }
  }
  const trem = inC ? smooth(ts / 0.25) : 0;
  zera.position.set(ZX + trem * 0.007 * Math.sin(t * 2 * Math.PI * 17), CRATE_TOP + hop, 0.02);
  zera.rotation.set(0, yaw, lean);
  squash.scale.set(1 / Math.sqrt(sq), sq, 1 / Math.sqrt(sq));

  // ── head
  let hx = 0.04 * a - 0.02, hy = 0, hz = 0.04 * Math.sin(t * 2.3), hpy = 0;
  if (t < wind) hy = 0.22 * smooth(prog(t, tapT - 0.25, tapT)) * (1 - smooth(prog(t, l1e - 0.05, l1e + 0.2)));
  if (t >= wind && t < slam) { hx = -0.15 * smooth((t - wind) / (slam - wind)); }
  if (inC) { hx = 0.16 * smooth(ts / 0.2); hpy = -0.045 * smooth(ts / 0.2); hz = 0.03 * Math.sin(t * 40) * trem; hy = -0.1; }
  if (inD) { const o = smooth(td / 0.25); hx = lerp(0.16, joy > 0 ? -0.14 : 0.02, o); hpy = lerp(-0.045, 0, o); hy = lerp(-0.1, 0, o); if (tl > 0) { const k = smooth(tl / 0.3); hx = lerp(hx, -0.1, k); hz = lerp(0, 0.1 + 0.05 * Math.sin(tl * 2 * Math.PI * 1.1), k); } }
  headPivot.rotation.set(hx, hy, hz); headPivot.position.y = 0.66 + hpy;

  // ── eyes
  const blink = (t0) => { const u = (t - t0) / 0.13; return u > 0 && u < 1 ? 1 - 0.92 * Math.sin(u * Math.PI) : 1; };
  const bl = Math.min(blink(l1s + 0.75), blink(wind - 0.08));
  if (t < slam + 0.05) { eyeSet(eyeL, 'open', bl); eyeSet(eyeR, 'open', bl); }
  else if (td < 0.1) { eyeSet(eyeL, 'shut'); eyeSet(eyeR, 'shut'); }
  else if (joy < 0) { eyeSet(eyeL, 'open', 1, 0.9 + 0.2 * easeOutBack((td - 0.1) / 0.15)); eyeSet(eyeR, 'shut'); }
  else { const pp = 1.0 + 0.22 * easeOutBack(joy / 0.2) - 0.08 * smooth((joy - 0.2) / 0.3); eyeSet(eyeL, 'open', 1, pp); eyeSet(eyeR, 'open', 1, pp); }
  const big = joy > 0 ? 1.5 : 1; for (const e of [eyeL, eyeR]) { e.h1.scale.set(big, big, 0.5); e.h2.scale.set(big, big, 0.5); }

  // ── brows
  let bUp = 0.012 * a, bL = 0.12, bR = -0.12;
  if (t < wind) { const sass = smooth(prog(t, tapT - 0.1, tapT + 0.1)) * (1 - smooth(prog(t, l1e, l1e + 0.2))); bR = -0.12 - 0.3 * sass; }
  if (t >= wind && t < slam) { bL = -0.3; bR = 0.3; }
  if (inC || (inD && joy < 0)) { bL = 0.5; bR = -0.5; bUp = 0.02; }
  if (joy > 0) { bL = 0.1; bR = -0.1; bUp = 0.05; }
  for (const [b, r, sx] of [[browL, bL, -1], [browR, bR, 1]]) { b.g.position.copy(b.base).add(_v.set(0, bUp, 0)); b.g.quaternion.copy(b.q).multiply(_q.setFromAxisAngle(_v.set(0, 0, 1), r)); b.g.visible = !(tl > -0.05); }

  // ── mouth
  mouth.o.visible = mouth.d.visible = mouth.arc.visible = false;
  if (t < slam) { mouth.o.visible = true; const wide = t >= wind ? 1 : 0; mouth.o.scale.set(0.75 + 0.45 * a + 0.3 * wide, 0.28 + 1.25 * a + 0.9 * wide, 1); mouth.oT.visible = a > 0.35 || wide; }
  else if (inC || (inD && joy < 0)) { mouth.o.visible = true; mouth.oT.visible = false; mouth.o.scale.set(1.25 + 0.2 * Math.sin(t * 50), 0.2, 1); if (inD) mouth.o.scale.set(0.55, 0.7, 1); }
  else if (t < l2e + 0.15 || tl < 0) { mouth.d.visible = true; const s = easeOutBack(joy / 0.2); mouth.d.scale.set(s * (0.95 + 0.1 * a), s * (0.55 + 0.6 * a + (t > l2e ? 0.35 : 0)), 1); }
  else { mouth.arc.visible = true; }

  // ── shades
  if (t >= tSh) { shades.visible = true; const u = (t - tSh) / 0.32; shades.position.copy(SHADES_REST); shades.position.y += 2.2 * (1 - easeIn(u)) + (u >= 1 ? 0.035 * Math.exp(-tl * 12) * Math.cos(tl * 30) : 0); shades.rotation.z = (1 - clamp01(u)) * 0.5; shades.rotation.x = 0.06 * (u >= 1 ? Math.exp(-tl * 10) * Math.sin(tl * 30) : 0); } else shades.visible = false;

  // ── sweat
  sweat.visible = inC && ts > 0.2; if (sweat.visible) { const u = prog(ts, 0.2, done - slam); const o = onHead(0.62, 0.42 - u * 0.5, 0.62, FUR + 0.03); sweat.position.copy(o.p); }

  // ── arms (needs current world matrices)
  zera.updateWorldMatrix(true, true);
  const tap = Math.exp(-Math.pow((t - tapT) / 0.07, 2)) + 0.6 * Math.exp(-Math.pow((t - tapT - 0.22) / 0.07, 2));
  const qPoint = aim(armR, _p.copy(BOARD_PT).add(new THREE.Vector3(0.05 * Math.sin(t * 3), 0.03 * Math.sin(t * 4.1) + 0.03 * a, 0)));
  if (tap > 0.01) qPoint.slerp(aim(armR, new THREE.Vector3(0.62, 2.05, 0.42)), 0.85 * tap);
  const qUp = qE(0, -0.9, 0.95), qBtn = aim(armR, btn.top), qCheer = qE(0, -0.5, 0.85), qRest = qE(0, -0.85, 0.6);
  let qr = qPoint.clone();
  if (t >= wind && t < slam) { const u = (t - wind) / (slam - wind); if (u < 0.82) qr.slerp(qUp, easeOut(u / 0.4)); else qr = qUp.clone().slerp(qBtn, easeIn((u - 0.82) / 0.18)); }
  else if (t >= slam && joy < 0.05) qr = qBtn.clone().slerp(qUp, 0.10 * Math.exp(-ts * 8) * Math.abs(Math.cos(ts * 18)));
  else if (joy >= 0.05) { qr = qBtn.clone().slerp(qCheer, easeOutBack((joy - 0.05) / 0.3)); if (tl > 0) qr.slerp(qRest, smooth(tl / 0.4)); const wv = qE(0, 0, 0.12 * Math.sin(t * 2 * Math.PI * 2.2)); qr.multiply(wv); }
  armR.quaternion.copy(qr);
  const qHang = qE(0, 0, 0.95 - 0.3 * a), qBal = qE(0, 0.3, -0.7), qCheek = aim(armL, head.localToWorld(new THREE.Vector3(-0.3, -0.34, 0.75))), qCheerL = qE(0, 0.5, -0.85), qHip = qE(0, 0.55, 0.7);
  let ql = qHang.clone();
  if (t >= wind && t < slam) ql.slerp(qBal, smooth((t - wind) / (slam - wind) / 0.5));
  else if (inC || (inD && joy < 0.05)) ql = qBal.clone().slerp(qCheek, easeOut(ts / 0.25));
  else if (joy >= 0.05) { ql = qCheek.clone().slerp(qCheerL, easeOutBack((joy - 0.05) / 0.3)); if (tl > 0) ql.slerp(qHip, smooth(tl / 0.4)); else ql.multiply(qE(0, 0, 0.12 * Math.sin(t * 2 * Math.PI * 2.2 + 1))); }
  armL.quaternion.copy(ql);

  // ── confetti
  updateConfetti(joy - 0.1);

  // ── lights
  const al = inC ? smooth(ts / 0.15) : 0, gl = inD ? Math.exp(-td * 2.2) : 0, win = inD ? smooth(td / 0.3) : 0;
  hemi.intensity = lerp(0.6, 0.3, al) + 0.15 * win; key.intensity = lerp(2.5, 1.1, al) + 0.35 * win; lampSpot.intensity = lerp(55, 20, al); fill.intensity = lerp(0.35, 0.15, al) + 0.2 * win;
  alarm.intensity = al * (16 + 16 * Math.sin(ts * 2 * Math.PI * 3.2)); greenL.intensity = 9 * Math.exp(-td * 4) * (inD ? 1 : 0);
  tintEl.style.background = inC ? '#ff0000' : '#eaffee';
  tintEl.style.opacity = inC ? (0.06 + 0.06 * (0.5 + 0.5 * Math.sin(ts * 2 * Math.PI * 3.2))) * al + 0.35 * Math.exp(-ts * 14) : inD ? 0.5 * Math.exp(-td * 16) : 0;

  // ── camera
  let cz = 9.0 - 0.3 * (t / slam), cx = 0.03, cy = 1.95, tx = 0.03, ty = 1.66;
  if (t >= wind && t < slam) cy += 0.05 * smooth((t - wind) / (slam - wind));
  if (inC) { const u = ts / (done - slam); cz = lerp(8.55, 7.9, u); tx = lerp(0.03, 0.1, u); ty = lerp(1.66, 1.7, u); }
  if (inD) { const u = smooth(td / 1.5); cz = lerp(8.4, 7.75, u) + 0.5 * Math.exp(-td * 7); cx = lerp(0.03, 0.0, u); tx = lerp(0.1, 0.0, u); ty = lerp(1.7, 1.76, u); if (tl > 0) cz -= 0.12 * Math.exp(-tl * 8) * Math.cos(tl * 20) + 0.1 * smooth(tl / 1.5); }
  const shake = 0.075 * (t >= slam ? Math.exp(-ts * 8) : 0) + 0.03 * (inD ? Math.exp(-td * 9) : 0) + 0.012 * al;
  camera.position.set(cx + shake * Math.sin(t * 71), cy + shake * Math.cos(t * 59), cz);
  camera.lookAt(tx + shake * 0.6 * Math.sin(t * 83), ty + shake * 0.6 * Math.cos(t * 67), 0);
  camera.updateMatrixWorld();

  // ── captions
  const c1 = TL.cap1 || [l1s - 0.05, wind + 0.05], c2 = TL.cap2 || [l2s - 0.05, end + 1];
  if (t >= c1[0] && t < c1[1]) setCap(`It's deploying on a <b class="y">Friday</b>`, t - c1[0]);
  else if (t >= slam + 0.12 && t < done) setCap(`<b class="r">*holds breath*</b>`, ts - 0.12, Math.sin(t * 50) * 1.2);
  else if (t >= c2[0] && t < c2[1]) setCap(`&hellip;and <b class="g">nothing breaks.</b>`, t - c2[0]);
  else setCap(null);

  // ── sparkles on shades landing
  if (tl > 0 && tl < 0.7) { head.updateWorldMatrix(true, false); const pr = (lx, ly, el, d) => { _v.set(lx, ly, 0.75); head.localToWorld(_v).project(camera); const u = clamp01((tl - d) / 0.45); const s = Math.sin(u * Math.PI); el.style.left = ((_v.x * 0.5 + 0.5) * W - 40) + 'px'; el.style.top = ((-_v.y * 0.5 + 0.5) * H - 55) + 'px'; el.style.opacity = s; el.style.transform = `scale(${(0.3 + s * 0.9).toFixed(2)}) rotate(${(u * 90).toFixed(0)}deg)`; }; pr(-0.42, 0.1, sp1, 0); pr(0.44, 0.06, sp2, 0.12); }
  else { sp1.style.opacity = 0; sp2.style.opacity = 0; }

  renderer.render(scene, camera);
};

await Promise.all([document.fonts.load('900 40px Nunito'), document.fonts.load('800 40px Nunito'), document.fonts.load('40px Hand')]);
window.renderAt(0);
window.READY = true;
