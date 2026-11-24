/* Signal kit: the shared pieces every live demo on this page is drawn with.
   A browser port of docs/design/signal (tokens, index tiles, chips, input block, Zera, wings).
   Everything returns markup strings; text that comes from a visitor goes through esc() first. */
(() => {
  'use strict';

  const I = {
    home: '<path d="M2.5 7.5 8 3l5.5 4.5V13a.5.5 0 0 1-.5.5H9.75V10h-3.5v3.5H3a.5.5 0 0 1-.5-.5z"/>',
    term: '<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2.5"/><path d="m4.5 6.5 2 1.75-2 1.75M8.5 10.25h3"/>',
    pr: '<circle cx="4.5" cy="3.5" r="1.5"/><circle cx="4.5" cy="12.5" r="1.5"/><circle cx="11.5" cy="5.5" r="1.5"/><path d="M4.5 5v6m7-4c0 2.6-3.2 2.4-7 3.6"/>',
    bell: '<path d="M4 11V7.5a4 4 0 0 1 8 0V11l1.25 1.5H2.75zM6.5 13.75a1.5 1.5 0 0 0 3 0"/>',
    clip: '<rect x="3.5" y="3" width="9" height="11" rx="2"/><path d="M6 3V2.25h4V3M6 7.5h4M6 10.5h2.5"/>',
    tray: '<path d="M2.25 9.5 4 3.75h8l1.75 5.75v2.5a1 1 0 0 1-1 1h-9.5a1 1 0 0 1-1-1zM2.5 9.5h3.25l.75 1.5h3l.75-1.5h3.25"/>',
    tasks: '<rect x="2.25" y="2.75" width="3.5" height="3.5" rx="1"/><rect x="2.25" y="9.75" width="3.5" height="3.5" rx="1"/><path d="M8.5 4.5h5.25M8.5 11.5h5.25"/>',
    cal: '<rect x="2.25" y="3.25" width="11.5" height="10.5" rx="2.5"/><path d="M2.5 6.75h11M5.5 2v2.25M10.5 2v2.25"/>',
    lines: '<path d="M2.5 4h11M2.5 8h7.5M2.5 12h9.5"/>',
    target: '<circle cx="8" cy="8" r="5"/><circle cx="8" cy="8" r="1.25"/><path d="M8 1.5V3M8 13v1.5M1.5 8H3M13 8h1.5"/>',
    gear: '<circle cx="8" cy="8" r="2"/><path d="M8 1.75v1.75M8 12.5v1.75M1.75 8H3.5M12.5 8h1.75M3.6 3.6l1.25 1.25M11.15 11.15l1.25 1.25M3.6 12.4l1.25-1.25M11.15 4.85l1.25-1.25"/>',
    x: '<path d="m4.5 4.5 7 7m0-7-7 7"/>', plus: '<path d="M8 3v10M3 8h10"/>', minus: '<path d="M4 8h8"/>',
    search: '<circle cx="7" cy="7" r="4.25"/><path d="M10.2 10.2 14 14"/>',
    ok: '<path d="m3 8.5 3.2 3.2L13 4.8"/>', chev: '<path d="m6 3.5 4.5 4.5L6 12.5"/>', chevd: '<path d="m3.5 6 4.5 4.5L12.5 6"/>', chevl: '<path d="M10 3.5 5.5 8l4.5 4.5"/>',
    play: '<path d="M5 3.5v9l7-4.5z"/>', pause: '<path d="M5.5 3.5v9M10.5 3.5v9"/>',
    copy: '<rect x="5.25" y="5.25" width="8" height="8" rx="2"/><path d="M10.75 5V4.25a1.5 1.5 0 0 0-1.5-1.5h-5a1.5 1.5 0 0 0-1.5 1.5v5a1.5 1.5 0 0 0 1.5 1.5H5"/>',
    pin: '<path d="M6 2.5h4l-.75 4 2 2.25h-6.5l2-2.25zM8 8.75v5"/>',
    more: '<circle cx="3.5" cy="8" r=".6"/><circle cx="8" cy="8" r=".6"/><circle cx="12.5" cy="8" r=".6"/>',
    file: '<path d="M4 2.25h5l3 3v8a.5.5 0 0 1-.5.5h-7.5a.5.5 0 0 1-.5-.5v-10.5a.5.5 0 0 1 .5-.5zM9 2.5V5.5h3"/>',
    link: '<path d="M6.75 9.25a2.5 2.5 0 0 0 3.5 0l2.25-2.25a2.5 2.5 0 0 0-3.5-3.5l-.75.75M9.25 6.75a2.5 2.5 0 0 0-3.5 0L3.5 9a2.5 2.5 0 0 0 3.5 3.5l.75-.75"/>',
    clock: '<circle cx="8" cy="8" r="5.5"/><path d="M8 5v3.25l2 1.25"/>',
    mic: '<rect x="6" y="2" width="4" height="7.5" rx="2"/><path d="M3.75 8a4.25 4.25 0 0 0 8.5 0M8 12.25v2"/>',
    phone: '<rect x="4.5" y="1.75" width="7" height="12.5" rx="2"/><path d="M7.25 12h1.5"/>',
    eye: '<path d="M1.5 8S4 3.75 8 3.75 14.5 8 14.5 8 12 12.25 8 12.25 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="1.75"/>',
    warn: '<path d="M8 2.5 14 13H2zM8 6.5v3M8 11.25v.01"/>',
    refresh: '<path d="M13 8a5 5 0 1 1-1.6-3.65M13 2.5v2.5h-2.5"/>',
    down: '<path d="M8 3v9.5M4 8.75l4 4 4-4"/>', open: '<path d="M5 11 11 5M6 5h5v5"/>',
    trash: '<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.5 8.5h6l.5-8.5"/>',
    dir: '<path d="M1.75 4.5A1.5 1.5 0 0 1 3.25 3h3l1.5 1.75h5a1.5 1.5 0 0 1 1.5 1.5v5.5a1.5 1.5 0 0 1-1.5 1.5h-9.5a1.5 1.5 0 0 1-1.5-1.5z"/>',
    video: '<rect x="1.75" y="4" width="8.5" height="8" rx="2"/><path d="m10.25 7 4-2v6l-4-2"/>',
    moon: '<path d="M13 9.5A5.5 5.5 0 0 1 6.5 3 5.5 5.5 0 1 0 13 9.5z"/>',
    photo: '<rect x="1.75" y="3" width="12.5" height="10" rx="2"/><circle cx="5.5" cy="6.5" r="1.1"/><path d="m2.25 11.5 3.5-3 2.5 2 2-1.75 3.5 3"/>',
    bolt: '<path d="M9 1.75 3.5 9H8l-1 5.25L12.5 7H8z"/>',
    cam: '<path d="M2 5.5V3.5A1.5 1.5 0 0 1 3.5 2h2M10.5 2h2A1.5 1.5 0 0 1 14 3.5v2M14 10.5v2a1.5 1.5 0 0 1-1.5 1.5h-2M5.5 14h-2A1.5 1.5 0 0 1 2 12.5v-2"/><circle cx="8" cy="8" r="2"/>',
    note: '<path d="M3 2.75h10v7L9.75 13.25H3zM13 9.75H9.75v3.5"/>',
    cup: '<path d="M3 5.5h8v4a3.5 3.5 0 0 1-3.5 3.5h-1A3.5 3.5 0 0 1 3 9.5zM11 6.5h1a1.75 1.75 0 0 1 0 3.5h-1M5.5 1.75v1.5M8.5 1.75v1.5"/>',
    star: '<path d="M8 2v12M2 8h12M3.75 3.75l8.5 8.5M12.25 3.75l-8.5 8.5"/>',
    exp: '<path d="M8 10V2.5M5 5l3-3 3 3M3 9.5v3a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-3"/>',
    standup: '<path d="M2.5 4h8M2.5 8h8M2.5 12h5M11.5 10.75l1.25 1.25 2-2.5"/>',
    key: '<rect x="1.75" y="4" width="12.5" height="8" rx="2"/><path d="M4.5 7h.01M7 7h.01M9.5 7h.01M12 7h.01M5 9.75h6"/>',
    swatch: '<circle cx="8" cy="8" r="5.5"/><path d="M8 2.5v11"/>',
    plug: '<path d="M6 2v3M10 2v3M4.5 5h7v2.5a3.5 3.5 0 0 1-7 0zM8 11v3"/>',
    jira: '<path d="M8 2 2.5 8 8 14l5.5-6zM8 5.5 5.75 8 8 10.5 10.25 8z"/>',
    globe: '<circle cx="8" cy="8" r="5.5"/><path d="M2.5 8h11M8 2.5c2 2 2 9 0 11M8 2.5c-2 2-2 9 0 11"/>',
    reset: '<path d="M3 8a5 5 0 1 0 1.6-3.65M3 2.5V5h2.5"/>',
    lock: '<rect x="3.5" y="7" width="9" height="6.5" rx="1.75"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/>',
    wifi: '<path d="M2 6.25a8.5 8.5 0 0 1 12 0M4.25 8.75a5.25 5.25 0 0 1 7.5 0M6.5 11.1a2.1 2.1 0 0 1 3 0"/>',
    code: '<path d="m5.5 4.5-3.5 3.5 3.5 3.5M10.5 4.5 14 8l-3.5 3.5"/>'
  };

  const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const ic = (n, c = 'i') => `<svg class="${c}" viewBox="0 0 16 16" aria-hidden="true">${I[n] || ''}</svg>`;
  const CAR = '<svg class="car" viewBox="0 0 9 12" aria-hidden="true"><path d="m2 1.5 5 4.5-5 4.5"/></svg>';
  const BARS = '<span class="bars" aria-hidden="true"><i style="height:4px"></i><i style="height:8px"></i><i style="height:6px"></i><i style="height:10px"></i></span>';
  const cns = '<i class="cn tl"></i><i class="cn tr"></i><i class="cn bl"></i><i class="cn br"></i>';
  const at = o => o ? Object.entries(o).map(([k, v]) => ` data-${k}="${esc(v)}"`).join('') : '';

  const kbd = (k, hi) => `<span class="kbd${hi ? ' hi' : ''}">${k}</span>`;
  const chip = (t, k = '', icn, dot) => `<span class="chip ${k}">${dot ? `<i class="${dot === 'p' ? 'p' : ''}"></i>` : ''}${icn ? ic(icn) : ''}${t}</span>`;
  const ix = (t, c, cls = '') => `<span class="ix ${cls}"${c ? ` style="--c:${c}"` : ''}>${t}</span>`;
  /* A button is a real <button> when it does something on this page (act), a plain label otherwise. */
  const btn = (t, cls = '', icn, k, act, data) => {
    const inner = `${icn ? ic(icn) : ''}${t}${k ? kbd(k) : ''}`;
    return act ? `<button type="button" class="b ${cls}" data-act="${act}"${at(data)}>${inner}</button>` : `<span class="b ${cls}">${inner}</span>`;
  };
  const ibtn = (icn, act, label, data, cls = '') => `<button type="button" class="ib ${cls}" data-act="${act}" aria-label="${esc(label)}"${at(data)}>${ic(icn)}</button>`;
  const ibs = (...a) => a.map(i => `<span class="ib">${ic(i)}</span>`).join('');
  const seg = (items, on = 0, cls = '', name) => `<span class="sg ${cls}"${name ? ' role="group"' : ''}>${items.map((x, i) => {
    const [t, n, icn] = [].concat(x);
    const inner = `${icn ? ic(icn) : ''}${t}${n != null ? `<b class="ct">${n}</b>` : ''}`;
    return name
      ? `<button type="button" class="${i === on ? 'on' : ''}" data-act="seg" data-seg="${name}" data-i="${i}" aria-pressed="${i === on}">${inner}</button>`
      : `<span class="${i === on ? 'on' : ''}">${inner}</span>`;
  }).join('')}</span>`;
  const lbl = (t, n, right = '') => `<div class="lbl"><span>${t}</span>${n != null ? `<b>${n}</b>` : ''}<span class="sp"></span>${right}</div>`;
  const r = o => `<div class="r ${o.cls || ''}"${o.st ? ` style="${o.st}"` : ''}${o.act ? ` data-act="${o.act}" role="button" tabindex="0"` : ''}${at(o.data)}>${o.l || ''}<span class="m"><span class="t">${o.t}</span>${o.s ? `<span class="s">${o.s}</span>` : ''}</span>${o.r || ''}</div>`;
  const tog = (on, act, data, label = 'Toggle') => act
    ? `<button type="button" class="tog${on ? ' on' : ''}" role="switch" aria-checked="${!!on}" aria-label="${esc(label)}" data-act="${act}"${at(data)}></button>`
    : `<span class="tog${on ? ' on' : ''}"></span>`;
  const sel = t => `<span class="sel">${t}${ic('chevd')}</span>`;
  const fld = (ph, icn = 'search', right = '') => `<span class="fld">${ic(icn)}<span>${ph}</span><span class="sp"></span>${right}</span>`;
  const mini = s => `<span class="d mini">${s}</span>`;
  const bar = (p, c, live) => `<span class="bar"><i${live ? ` data-live="${live}"` : ''} style="width:${p}%${c ? `;background:${c};box-shadow:0 0 8px ${c}` : ''}"></i></span>`;

  /* The bracketed input block. With `name` it holds a real text field the visitor can type into. */
  const inp = (label, sub, o = {}) => `<div class="in${o.name ? ' live' : ''}">${cns}<div class="l1">${BARS}${label}${sub ? `<span>${sub}</span>` : ''}</div><div class="l2">${CAR}${o.name
    ? `<input type="text" data-input="${o.name}" placeholder="${esc(o.ph || '')}" aria-label="${esc(o.aria || label)}" autocomplete="off" autocapitalize="off" spellcheck="false" maxlength="120"><span class="chips" data-chips="${o.name}"></span>`
    : `${o.text ? `<span>${o.text}</span>` : ''}<i class="cur"></i>${o.ph ? `<span class="ph2">&nbsp;${o.ph}</span>` : ''}`}<span class="hint">${(o.hints || []).map(h => `<span>${h}</span>`).join('')}</span></div></div>`;

  function series(seed, n) {
    let v = 1.1, s = seed * 9301; const pts = [];
    const rnd = () => (s = (s * 9301 + 49297) % 233280) / 233280;
    for (let i = 0; i < n; i++) { v = Math.max(.3, Math.min(2.4, v + (rnd() - .5) * .6)); pts.push(v); }
    return pts;
  }
  const sparkPoints = pts => { const lo = Math.min(...pts), hi = Math.max(...pts) + .001, n = pts.length; return pts.map((p, i) => `${(i / (n - 1) * 80).toFixed(1)},${(16 - (p - lo) / (hi - lo) * 14).toFixed(1)}`).join(' '); };
  const spark = (seed = 1, c, live) => `<svg class="spark" viewBox="0 0 80 18" preserveAspectRatio="none" aria-hidden="true"><polyline${live ? ` data-live="${live}"` : ''}${c ? ` style="stroke:${c}"` : ''} points="${sparkPoints(series(seed, 28))}"/></svg>`;
  const cols = (n, seed, live) => { let s = seed * 77, o = ''; for (let i = 0; i < n; i++) { s = (s * 9301 + 49297) % 233280; o += `<i style="height:${20 + s / 233280 * 80}%;opacity:${.45 + s / 233280 * .55}"></i>`; } return `<span class="cols"${live ? ` data-live="${live}"` : ''}>${o}</span>`; };
  const tile = (k, k2, v, small, viz, live) => `<div class="tele"><div class="k"><span>${k}</span><span>${k2}</span></div><div class="v"><span${live ? ` data-live="${live}"` : ''}>${v}</span><small>${small}</small></div>${viz}</div>`;

  /* Focus ring with a 60-tick bezel. */
  const ticks = (n, r1, r2, cx = 100, cy = 100) => Array.from({ length: n }, (_, i) => { const a = i / n * Math.PI * 2, s = Math.sin(a), c = -Math.cos(a), l = i % 5 === 0 ? r1 - 3 : r1; return `<path d="M${(cx + s * l).toFixed(1)} ${(cy + c * l).toFixed(1)}L${(cx + s * r2).toFixed(1)} ${(cy + c * r2).toFixed(1)}"/>`; }).join('');
  const RING_C = 2 * Math.PI * 78;
  const ring = (size, time, sub, pct = .25) => `<svg class="ring" viewBox="0 0 200 200" width="${size}" height="${size}" role="img" aria-label="Focus timer"><g stroke="var(--faint)" stroke-width="1" opacity=".8">${ticks(60, 92, 96)}</g><circle cx="100" cy="100" r="78" fill="none" stroke="var(--line2)" stroke-width="3"/><circle data-live="ring" cx="100" cy="100" r="78" fill="none" stroke="var(--sig)" stroke-width="3" stroke-linecap="round" stroke-dasharray="${(RING_C * pct).toFixed(1)} ${RING_C.toFixed(1)}" transform="rotate(-90 100 100)"/><text data-live="ring-time" x="100" y="${sub ? 104 : 110}" text-anchor="middle" font-size="${size > 150 ? 34 : 30}" font-weight="600" fill="var(--fg)">${time}</text>${sub ? `<text data-live="ring-sub" x="100" y="124" text-anchor="middle" font-size="10.5" fill="var(--dim)">${sub}</text>` : ''}</svg>`;

  /* ───── Zera: dark glass body, rim and cursor-block eyes in the mood colour ───── */
  const ZB = 'M13 56C12 28 29 12 50 12s38 16 37 44c0 22-16 33-37 33S13 78 13 56Z';
  const MOOD = { idle: 'var(--sig)', think: 'var(--info)', ok: 'var(--ok)', warn: 'var(--warn)', err: 'var(--err)', sleep: 'var(--mute)' };
  function zera({ m = 'idle', s = 64, wave = false } = {}) {
    const eye = (x, h = 15, y = 44) => `<rect class="zb" x="${x}" y="${y}" width="7.5" height="${h}" rx="2.2"/>`;
    let eyes = eye(35.5) + eye(57), mouth = '<path d="M44 66q6 5 12 0" class="zs"/>', extra = '';
    if (m === 'ok') { eyes = '<path d="M33 53q5.5-8 11 0M56 53q5.5-8 11 0" class="zs"/>'; mouth = '<path d="M42 64q8 8 16 0" class="zs"/>'; }
    if (m === 'think') { eyes = eye(38, 9, 47) + eye(59.5, 9, 47); mouth = '<path d="M45 67h10" class="zs"/>'; extra = '<g class="zdots"><circle cx="80" cy="14" r="2.2"/><circle cx="89" cy="8" r="1.7"/><circle cx="96" cy="3" r="1.2"/></g>'; }
    if (m === 'warn') { eyes = eye(35, 19, 40) + eye(57.5, 19, 40); mouth = '<ellipse cx="50" cy="69" rx="3.2" ry="3.8" class="zf"/>'; }
    if (m === 'err') { eyes = '<path d="M33 46l10-4M67 46l-10-4" class="zs"/>' + eye(36, 9, 50) + eye(57, 9, 50); mouth = '<path d="M43 71q7-6 14 0" class="zs"/>'; }
    if (m === 'sleep') { eyes = '<path d="M33 52h10M57 52h10" class="zs"/>'; mouth = '<path d="M46 66h8" class="zs"/>'; extra = '<text x="80" y="16" font-size="13" font-weight="700" class="zf">z</text>'; }
    const armR = wave ? '<g class="zwave"><path class="za" d="M85 56q11-6 9-21"/><circle class="zh" cx="94" cy="32" r="5"/></g>' : '<path class="za" d="M85 62q8 5 6 13"/><circle class="zh" cx="91" cy="77" r="4.5"/>';
    const armL = '<path class="za" d="M15 62q-8 5-6 13"/><circle class="zh" cx="9" cy="77" r="4.5"/>';
    const body = `<path class="body" d="${ZB}" fill="url(#zgA)" stroke="currentColor" stroke-width="1.8"/><path d="${ZB}" fill="url(#zgGlow)" opacity=".5"/><path d="M24 34c5-9 13-14 22-15" fill="none" stroke="rgba(255,255,255,.28)" stroke-width="1.6" stroke-linecap="round"/>`;
    return `<svg class="zera" viewBox="-6 -6 112 106" width="${s}" height="${s}" style="color:${MOOD[m] || MOOD.idle}" aria-hidden="true">${armL}${armR}${body}<g class="face">${eyes}${mouth}</g>${extra}</svg>`;
  }
  const ZDEFS = `<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
<radialGradient id="zgA" cx=".34" cy=".22" r=".95"><stop offset="0" stop-color="#22343f"/><stop offset=".5" stop-color="#0c151c"/><stop offset="1" stop-color="#05090d"/></radialGradient>
<radialGradient id="zgGlow" cx=".5" cy="1.05" r=".6"><stop offset="0" stop-color="currentColor" stop-opacity=".7"/><stop offset="1" stop-color="currentColor" stop-opacity="0"/></radialGradient>
</defs></svg>`;

  /* ───── Wings: the app's own silhouette, a pill that tapers into Zera ───── */
  let WID = 0;
  function wings({ lw = 300, rw = 300, col = 'var(--sig)', L = '', R = '', mood = 'think', wave = false }) {
    const H = 60, rr = 30, m = 30, cx = lw + 70, X0 = lw + 140, X1 = X0 + rw, tl = cx - 14, tr = cx + 14, id = ++WID;
    const el = `M${rr},0L${lw},0C${lw + 28},0 ${tl - 20},${m - 3} ${tl - 3},${m - 3}`, er = `M${X1 - rr},0L${X0},0C${X0 - 28},0 ${tr + 20},${m - 3} ${tr + 3},${m - 3}`;
    const dl = `${el}A3 3 0 0 1 ${tl - 3},${m + 3}C${tl - 20},${m + 3} ${lw + 28},${H} ${lw},${H}L${rr},${H}A${rr} ${rr} 0 0 1 ${rr},0Z`;
    const dr = `${er}A3 3 0 0 0 ${tr + 3},${m + 3}C${tr + 20},${m + 3} ${X0 - 28},${H} ${X0},${H}L${X1 - rr},${H}A${rr} ${rr} 0 0 0 ${X1 - rr},0Z`;
    const grad = (n, a, b, s0, s1) => `<linearGradient id="${n}${id}" gradientUnits="userSpaceOnUse" x1="${a}" x2="${b}" y1="0" y2="0">${s0}${s1}</linearGradient>`;
    const k = o => `<stop offset="${o[0]}" style="stop-color:${o[1]};stop-opacity:${o[2]}"/>`;
    return `<div class="wg" style="width:${X1}px;margin-left:${-cx}px;--k:${col}">
<svg width="${X1}" height="${H}" viewBox="0 0 ${X1} ${H}" aria-hidden="true"><defs><filter id="wsh${id}" x="-20%" y="-80%" width="140%" height="300%"><feGaussianBlur stdDeviation="11"/></filter></defs>
<g filter="url(#wsh${id})"><path d="${dl}" fill="#000" opacity=".55" transform="translate(0 8)"/><path d="${dr}" fill="#000" opacity=".55" transform="translate(0 8)"/><path d="${dl}" style="fill:${col}" opacity=".22"/><path d="${dr}" style="fill:${col}" opacity=".22"/></g></svg>
<i class="wgb" style="left:0;width:${lw}px;border-radius:${rr}px 0 0 ${rr}px"></i><i class="wgb" style="left:${X0}px;width:${rw}px;border-radius:0 ${rr}px ${rr}px 0"></i>
<svg width="${X1}" height="${H}" viewBox="0 0 ${X1} ${H}" aria-hidden="true"><defs>
${grad('sl', lw - 10, tl, k([0, col, 0]), k([1, col, .38]))}${grad('sr', X0 + 10, tr, k([0, col, 0]), k([1, col, .38]))}
<linearGradient id="wv${id}" gradientUnits="userSpaceOnUse" x1="0" x2="0" y1="0" y2="${H}"><stop offset="0" stop-color="#0b151d"/><stop offset="1" stop-color="#05080b"/></linearGradient>
${grad('el', lw - 130, tl, k([0, '#fff', .16]), k([.8, col, .8]))}${grad('er', X0 + 130, tr, k([0, '#fff', .16]), k([.8, col, .8]))}</defs>
<path d="M${lw},0C${lw + 28},0 ${tl - 20},${m - 3} ${tl - 3},${m - 3}A3 3 0 0 1 ${tl - 3},${m + 3}C${tl - 20},${m + 3} ${lw + 28},${H} ${lw},${H}Z" fill="url(#wv${id})"/><path d="M${X0},0C${X0 - 28},0 ${tr + 20},${m - 3} ${tr + 3},${m - 3}A3 3 0 0 0 ${tr + 3},${m + 3}C${tr + 20},${m + 3} ${X0 - 28},${H} ${X0},${H}Z" fill="url(#wv${id})"/>
<path d="${dl}" fill="url(#sl${id})"/><path d="${dr}" fill="url(#sr${id})"/>
<path d="${dl}" fill="none" stroke="url(#el${id})" stroke-width="1.3"/><path d="${dr}" fill="none" stroke="url(#er${id})" stroke-width="1.3"/>
<path class="we" d="${el}"/><path class="we" d="${er}"/></svg>
<div class="wgc lf" style="left:0;width:${lw}px">${L}</div><div class="wgc rt" style="left:${X0}px;width:${rw}px">${R}</div>
<div class="wgz" style="left:${cx - 27}px">${zera({ s: 54, m: mood, wave })}</div></div>`;
  }

  /* Shows a fixed-size design at whatever width its box has. The box keeps the scaled height. */
  function fit(box, max = 1) {
    const inner = box.firstElementChild;
    if (!inner) return 1;
    const k = Math.min(max, box.clientWidth / inner.offsetWidth) || 1;
    inner.style.transform = `scale(${k})`;
    box.style.height = Math.ceil(inner.offsetHeight * k) + 'px';
    box.dataset.k = k;
    return k;
  }
  function autofit(box, max, after) {
    const run = () => { fit(box, max); if (after) after(); };
    if ('ResizeObserver' in window) new ResizeObserver(run).observe(box.parentElement || box);
    else addEventListener('resize', run);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(run);
    run();
    return run;
  }

  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const clock = () => new Date().toTimeString().slice(0, 5);

  window.Sig = { I, MOOD, esc, ic, CAR, BARS, cns, kbd, chip, ix, btn, ibtn, ibs, seg, lbl, r, tog, sel, fld, mini, bar, inp, series, sparkPoints, spark, cols, tile, ring, RING_C, zera, ZDEFS, wings, fit, autofit, reduce, clock };
})();
