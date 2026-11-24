/* The live demos: the desktop in the hero (notch island, wings, Daily Shelf, Clipboard deck, launcher)
   and the smaller vignettes further down. Everything is fictional sample data drawn in the browser;
   nothing is fetched, stored or sent. Visitor text is escaped before it is shown. */
(() => {
  'use strict';
  const S = window.Sig;
  if (!S) return;
  const { ic, esc, kbd, chip, ix, btn, ibtn, ibs, seg, lbl, r, tog, sel, fld, mini, bar, inp, spark, cols, tile, ring, zera, wings, cns, CAR } = S;
  const $ = (s, el = document) => el.querySelector(s), $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const still = () => S.reduce.matches;
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const mmss = s => `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
  const VIOLET = '#9b8df9', ROSE = '#ee7991', AMBER = '#ffc35a', BLUE = '#5ab8ff';

  /* Runs `fn` while the element is on screen and the tab is visible; pauses otherwise. */
  function whileSeen(el, start, stop, threshold = .35) {
    let seen = false, on = false;
    const sync = () => { const want = seen && !document.hidden; if (want !== on) { on = want; (on ? start : stop)(); } };
    new IntersectionObserver(e => { seen = e[0].isIntersecting; sync(); }, { threshold }).observe(el);
    document.addEventListener('visibilitychange', sync);
  }
  /* Types text into a field the way a person would, then calls back. */
  function typeInto(input, text, done, speed = 46) {
    let i = 0; input.value = '';
    const id = setInterval(() => {
      input.value = text.slice(0, ++i);
      input.dispatchEvent(new Event('input', { bubbles: true }));
      if (i >= text.length) { clearInterval(id); if (done) setTimeout(done, 380); }
    }, still() ? 0 : speed);
    return () => clearInterval(id);
  }

  /* ═════ Clipboard deck ═════ */
  function Deck(root, opt = {}) {
    const TINT = { text: '#7BE1C2', code: '#9B8DF9', link: '#5AB8FF', image: '#EE7991', files: '#FFC35A' };
    const GROUP = { text: 'text', code: 'text', link: 'text', color: 'text', image: 'images', files: 'files' };
    const KIND = { text: 'TEXT', code: 'CODE', link: 'LINK', color: 'COLOUR', image: 'IMAGE', files: 'FILE' };
    const ICON = {
      text: '<path d="M2 3h8M2 6h8M2 9h5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>',
      code: '<path d="M4 3 1.5 6 4 9M8 3l2.5 3L8 9" stroke="currentColor" stroke-width="1.4" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
      link: '<path d="M5 7 7 5M4.2 5.2 3 6.4a1.9 1.9 0 0 0 2.6 2.6l1.2-1.2M7.8 6.8 9 5.6A1.9 1.9 0 0 0 6.4 3L5.2 4.2" stroke="currentColor" stroke-width="1.3" fill="none" stroke-linecap="round"/>',
      color: '<circle cx="6" cy="6" r="4.2" stroke="currentColor" stroke-width="1.4" fill="none"/><circle cx="6" cy="6" r="1.6" fill="currentColor"/>',
      image: '<rect x="1.5" y="2.5" width="9" height="7" rx="1.5" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="m3 8 2.2-2.2L7 7.5l1-1L9.5 8" stroke="currentColor" stroke-width="1.1" fill="none"/>',
      files: '<path d="M3 1.5h4l2.5 2.5v6.5H3z" stroke="currentColor" stroke-width="1.3" fill="none" stroke-linejoin="round"/>'
    };
    const items = [
      { kind: 'code', app: 'Xcode', ago: 'just now', pinned: true, title: 'func greet(_ name: String) -> String {…', code: ['func greet(_ name: String) -> String {', '    let hello = "Hello, \\(name)"', '    return hello', '}'] },
      { kind: 'text', app: 'Notes', ago: '2 min ago', title: 'Review the first-run checklist', text: 'Review the first-run checklist' },
      { kind: 'link', app: 'Safari', ago: '6 min ago', title: 'https://example.com/aurora/releases?tag=v2', host: 'example.com', rest: '/aurora/releases?tag=v2' },
      { kind: 'color', app: 'Figma', ago: '14 min ago', title: '#7BE1C2', hex: '#7BE1C2', rgb: 'RGB 123 225 194' },
      { kind: 'image', app: 'Preview', ago: '31 min ago', title: 'Image 1600 × 1000', fact: '1600×1000' },
      { kind: 'files', app: 'Finder', ago: '1 h ago', title: 'Release checklist.md', path: '~/Projects/aurora/docs', fact: 'MD' },
      { kind: 'text', app: 'Mail', ago: '2 h ago', title: 'Zera keeps what you copy on this Mac. Open the clip…', text: 'Zera keeps what you copy on this Mac. Open the clip with your shortcut, flip to the copy you want and press Return. Nothing leaves the machine.' },
      { kind: 'link', app: 'Safari', ago: 'yesterday', pinned: true, title: 'https://example.org/docs/shortcuts', host: 'example.org', rest: '/docs/shortcuts' }
    ];
    items.forEach((it, i) => { it.id = i; it.tint = it.kind === 'color' ? it.hex : TINT[it.kind]; });
    const FILTERS = ['all', 'text', 'images', 'files', 'pinned'];
    const H = 242, TOP = 58, STEP = 30, PEEKS = 3;
    const state = { sel: 0, filter: 0, query: '', said: '' };
    let saidTimer = null;

    root.classList.add('cd');
    root.tabIndex = -1;
    root.setAttribute('role', 'group');
    root.setAttribute('aria-label', 'Clipboard deck demo. Arrow keys flip cards, Return copies.');
    root.innerHTML = `<svg class="cd-wire" viewBox="0 0 404 440" aria-hidden="true"></svg><div class="cd-deck"></div>
<div class="cd-pane"><div class="scanh"><div class="scan"></div></div><b></b><b></b><b></b><b></b></div>
<div class="cd-prompt"><b></b><b></b><b></b><b></b><span class="cd-caret" aria-hidden="true">›</span>
<input type="text" placeholder="search clips…" autocomplete="off" spellcheck="false" maxlength="60" aria-label="Search clipboard history">
<button class="cd-chip" type="button" aria-label="Filter">ALL</button><button class="cd-open" type="button" aria-label="Open the full Clipboard">↗</button></div>
<div class="cd-status" aria-live="polite"></div>`;
    const deck = $('.cd-deck', root), wire = $('.cd-wire', root), pane = $('.cd-pane', root), scan = $('.scan', pane);
    const q = $('input', root), chipEl = $('.cd-chip', root), status = $('.cd-status', root);
    const ico = k => `<svg class="cd-ico" viewBox="0 0 12 12" aria-hidden="true">${ICON[k]}</svg>`;
    const body = it => ({
      text: () => `<div class="${it.text.length <= 46 ? 'cd-short' : 'cd-long'}">${esc(it.text)}</div>`,
      code: () => `<div class="cd-code">${it.code.map((l, i) => `<b>${i + 1}</b>${esc(l)}`).join('\n')}</div>`,
      link: () => `<div class="cd-host">${esc(it.host)}</div><div class="cd-rest">${esc(it.rest)}</div><div class="cd-orb">↗</div>`,
      color: () => `<div class="cd-hex">${it.hex}</div><div class="cd-rgb">${it.rgb}</div>`,
      image: () => '',
      files: () => `<div class="cd-ftile"><svg viewBox="0 0 12 12">${ICON.files}</svg></div><div class="cd-fname">${esc(it.title)}</div><div class="cd-fpath">${esc(it.path)}</div>`
    }[it.kind]());
    const fact = it => it.fact || (it.kind === 'text' ? it.text.length + ' chars' : it.kind === 'code' ? it.code.length + ' lines' : '');
    items.forEach(it => {
      const el = document.createElement('div');
      el.className = `cd-card ${it.kind}${it.kind === 'color' || it.kind === 'image' ? ' bleed' : ''}`;
      el.style.setProperty('--tint', it.tint);
      el.innerHTML = `${it.kind === 'image' ? '<div class="cd-pic"></div>' : ''}<div class="cd-head"><i></i>${KIND[it.kind]}<span>${it.pinned ? '<em>▲ pinned</em>  ' : ''}${fact(it)}</span></div><div class="cd-body">${body(it)}</div>
<div class="cd-foot"><div class="fr"><span class="t">${it.app} · ${it.ago}</span>copy <span class="cd-kc lit">↵</span></div><div class="pk">${ico(it.kind)}<span class="t">${esc(it.title)}</span><span class="cd-kc key"></span></div></div><div class="cd-shade"></div><div class="cd-stamp">COPIED</div>`;
      el.addEventListener('click', () => clickCard(it));
      deck.appendChild(el); it.el = el;
    });
    const none = document.createElement('div');
    none.className = 'cd-card gone';
    none.style.setProperty('--tint', '#5d7282');
    none.innerHTML = '<div class="cd-none"><b>No matching copies</b><span>Try fewer letters, or press ⇥ for another filter.</span></div>';
    deck.appendChild(none);

    function list() {
      const f = FILTERS[state.filter], s = state.query.trim().toLowerCase();
      return items.filter(i => i.pinned).concat(items.filter(i => !i.pinned)).filter(it => {
        if (f === 'pinned' ? !it.pinned : (f !== 'all' && GROUP[it.kind] !== f)) return false;
        return !s || `${it.title} ${it.text || ''} ${it.app}`.toLowerCase().includes(s);
      });
    }
    function slot(d) {
      if (d < 0) return { y: TOP - 4, s: 1, a: 66, o: 0, shade: 0 };
      const k = Math.min(d, PEEKS), s = 1 - .045 * k, out = { y: TOP + H + STEP * k - H * s, s, a: 0, o: 1, shade: .17 * k };
      if (d > PEEKS) { out.y += 8; out.s -= .03; out.o = 0; }
      return out;
    }
    function put(el, sl, z, front) {
      el.style.transform = `translateY(${sl.y}px) scale(${sl.s})${sl.a ? ` rotateX(${sl.a}deg)` : ''}`;
      el.style.opacity = sl.o; el.style.zIndex = z;
      el.classList.toggle('front', front); el.classList.toggle('gone', sl.o === 0);
      const shade = $('.cd-shade', el); if (shade) shade.style.opacity = sl.shade;
    }
    function drawWire(l, empty) {
      const gx = 14, py = TOP + 12.5; let out = '';
      if (!empty) {
        const d = `M48 27 H${gx + 6} Q${gx} 27 ${gx} 33 V${py - 6} Q${gx} ${py} ${gx + 6} ${py} H22`;
        out += `<path class="tb0" d="${d}"/><path class="tb1" d="${d}"/><path class="tb2" d="${d}"/><circle class="pt0" cx="22" cy="${py}" r="3.5"/>`;
        const n = Math.min(PEEKS, l.length - 1 - state.sel);
        for (let k = 1; k <= n; k++) {
          const y = TOP + H + STEP * (k - 1) + STEP / 2 + 1, x = 202 - 180 * slot(k).s, prev = k === 1 ? py + 6 : TOP + H + STEP * (k - 2) + STEP / 2 + 1;
          out += `<path class="rl" d="M${gx} ${prev} V${y - 5} Q${gx} ${y} ${gx + 5} ${y} H${x - 4}"/>`;
          if (k < n) out += `<path class="rl" d="M${gx} ${y - 5} V${y}"/>`;
          out += `<circle cx="${x - 1}" cy="${y}" r="2.4" fill="${l[state.sel + k].tint}"/>`;
        }
      }
      wire.innerHTML = out;
    }
    function sweep() { scan.classList.remove('go'); void scan.offsetWidth; scan.classList.add('go'); }
    function render(doSweep) {
      const l = list();
      state.sel = clamp(state.sel, 0, Math.max(0, l.length - 1));
      items.forEach(it => {
        const i = l.indexOf(it);
        if (i < 0) { put(it.el, { y: slot(1).y, s: .9, a: 0, o: 0, shade: 0 }, 0, false); return; }
        const d = i - state.sel;
        put(it.el, slot(d < 0 ? -1 : d), d < 0 ? 20 : 10 - Math.min(d, 9), d === 0);
        const key = $('.key', it.el);
        key.textContent = i < 9 ? '⌘' + (i + 1) : ''; key.style.display = i < 9 ? '' : 'none';
      });
      const empty = l.length === 0;
      put(none, empty ? slot(0) : { y: slot(0).y, s: .95, a: 0, o: 0, shade: 0 }, 10, false);
      const tint = empty ? '#5d7282' : l[state.sel].tint;
      root.style.setProperty('--tint', tint);
      drawWire(l, empty);
      if (doSweep) sweep();
      const f = FILTERS[state.filter].toUpperCase();
      chipEl.textContent = f; chipEl.classList.toggle('on', state.filter !== 0);
      status.innerHTML = `<i></i><span class="wh">CLIP ${empty ? '0/0' : `${state.sel + 1}/${l.length}`}</span><span>${f}</span>${state.said ? `<span class="said">${state.said}</span>` : ''}<span class="sp"></span><span class="cd-kc">↑↓</span><span>flip</span><span class="cd-kc">↵</span><span>copy</span><span class="cd-kc">⇥</span><span>filter</span>`;
    }
    function step(n) {
      const l = list(), next = clamp(state.sel + n, 0, l.length - 1);
      if (next === state.sel) return false;
      state.sel = next; render(true); return true;
    }
    function copy(it) {
      const l = list(); it = it || l[state.sel];
      if (!it) return;
      const i = l.indexOf(it);
      if (i >= 0 && i !== state.sel) { state.sel = i; render(true); }
      const stamp = $('.cd-stamp', it.el);
      stamp.classList.remove('on'); void stamp.offsetWidth; stamp.classList.add('on');
      state.said = 'COPIED · ⌘V TO PASTE'; render(false);
      root.style.setProperty('--tint', '#9be36b'); sweep();
      clearTimeout(saidTimer);
      saidTimer = setTimeout(() => { stamp.classList.remove('on'); state.said = ''; render(false); if (opt.onCopied) opt.onCopied(it); }, 1300);
      if (opt.onCopy) opt.onCopy(it);
    }
    function clickCard(it) {
      const l = list(), i = l.indexOf(it);
      if (i < 0) return;
      if (i === state.sel) copy(it); else { state.sel = i; render(true); }
      q.focus({ preventScroll: true });
    }
    function cycle(n) { state.filter = (state.filter + n + FILTERS.length) % FILTERS.length; state.sel = 0; render(true); }
    function reset() { q.value = ''; state.query = ''; state.sel = 0; state.filter = 0; state.said = ''; render(false); }

    q.addEventListener('input', () => { state.query = q.value; state.sel = 0; render(true); });
    chipEl.addEventListener('click', () => { cycle(1); q.focus({ preventScroll: true }); });
    $('.cd-open', root).addEventListener('click', () => {
      if (opt.onOpenFull) return opt.onOpenFull();
      state.said = 'OPENS THE FULL CLIPBOARD'; render(false);
      clearTimeout(saidTimer); saidTimer = setTimeout(() => { state.said = ''; render(false); }, 1300);
    });
    root.addEventListener('keydown', e => {
      if (e.key === 'ArrowDown') { step(1); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { step(-1); e.preventDefault(); }
      else if (e.key === 'Enter') { copy(); e.preventDefault(); }
      else if (e.key === 'Tab' && document.activeElement === q) { cycle(e.shiftKey ? -1 : 1); e.preventDefault(); }
      else if (e.key === 'Escape') { if (opt.onEscape) opt.onEscape(); else reset(); e.stopPropagation(); }
      else if ((e.metaKey || e.ctrlKey) && /^[1-9]$/.test(e.key)) { const it = list()[+e.key - 1]; if (it) copy(it); e.preventDefault(); }
    });
    let acc = 0;
    root.addEventListener('wheel', e => {
      if (document.activeElement !== q) return;   // only take the wheel once the visitor is using the deck
      e.preventDefault(); acc += e.deltaY;
      if (Math.abs(acc) >= 40) { step(acc > 0 ? 1 : -1); acc = 0; }
    }, { passive: false });
    root.addEventListener('mousedown', e => { if (e.target !== q && !e.target.closest('button')) { e.preventDefault(); q.focus({ preventScroll: true }); } });
    render(false);
    return { step, copy, cycle, reset, focus: () => q.focus({ preventScroll: true }), count: () => list().length, at: () => state.sel };
  }

  /* ═════ App opener: four looks, one set of sample apps ═════ */
  const OP_C = ['#7BE1C2', VIOLET, ROSE, BLUE, AMBER, '#9be36b'];
  const OP_DATA = {
    apps: [
      { n: 'Ghostty X', m: 'Gx', run: 1, pin: 1, ver: '1.4.2', opened: '128×', cat: 'Developer Tools' }, { n: 'Safari', m: 'Sa', run: 1, pin: 1, ver: '27.0.1', opened: '46×', cat: 'Productivity' },
      { n: 'Xcode', m: 'Xc', run: 1, ver: '26.1', opened: '31×', cat: 'Developer Tools' }, { n: 'Finder', m: 'Fi', run: 1, ver: '26.1', opened: '22×', cat: 'Utilities' },
      { n: 'Notes', m: 'No', ver: '4.12', opened: '9×', cat: 'Productivity' }, { n: 'Calendar', m: 'Ca', ver: '15.0', opened: '6×', cat: 'Productivity' }, { n: 'System Settings', m: 'Se', ver: '26.1', opened: '4×', cat: 'Utilities' }
    ],
    commands: [{ n: 'Quit all apps', i: 'x', k: 'runs a command' }, { n: 'Ports in use', i: 'plug', k: 'lists listeners' }, { n: 'Empty the Trash', i: 'trash', k: 'asks first' }, { n: 'Toggle dark mode', i: 'moon', k: 'system' }],
    actions: [{ n: 'New task', i: 'tasks', go: 'tasks' }, { n: 'Start a focus session', i: 'target', go: 'focus' }, { n: 'Open Daily Shelf', i: 'tray', go: 'dshelf' }, { n: 'Open the Clipboard deck', i: 'clip', go: 'deck' },
      { n: 'Add a reminder', i: 'cal', go: 'rem' }, { n: 'Open Agents', i: 'term', go: 'agents' }, { n: 'Roll the teleprompter', i: 'lines', go: 'tele' }, { n: 'Take a screenshot', i: 'cam' }]
  };
  const OP_TABS = ['apps', 'commands', 'actions'];
  const opFound = (t, q) => OP_DATA[t].filter(x => !q || x.n.toLowerCase().includes(q));
  const opVerb = (t, x) => t === 'apps' ? (x.run ? 'FOCUSED' : 'OPENED') : 'RAN';
  const opFacts = (t, x) => t === 'apps'
    ? [['Status', x.run ? 'Running' : 'Not running'], ['Version', x.ver], ['Opened from Zera', x.opened], ['Where', '/Applications']]
    : [['Kind', t === 'commands' ? 'Command' : 'Zera action'], ['Does', x.k || 'opens it in the notch']];

  /* ───── Launcher (the default): risen from the bottom edge. Apps over a search field; ">" turns the
     list into commands, and ">wallpaper " into a strip of pictures the desktop follows. ───── */
  function Launcher(root, opt = {}) {
    const CMDS = [
      { key: 'wallpaper', n: 'Wallpaper', k: 'Change the desktop picture', i: 'photo', list: 1 },
      { key: 'folders', n: 'Wallpaper Folders', k: 'Choose the folders >wallpaper shows pictures from', i: 'dir' },
      { key: 'theme', n: 'Theme', k: 'Change Zera’s colours', i: 'swatch' },
      { key: 'lock', n: 'Lock', k: 'Turn the display off', i: 'lock' },
      { key: 'sleep', n: 'Sleep', k: 'Put the Mac to sleep', i: 'moon' },
      { key: 'quit', n: 'Quit All Apps', k: 'Quit every open app for a clean desk', i: 'x' },
      { key: 'kill', n: 'Kill Process', k: 'Stop a running process by name', i: 'bolt' },
      { key: 'port', n: 'Kill Port', k: 'Free a port by stopping what listens on it', i: 'plug' },
      { key: 'clipboard', n: 'Clipboard History', k: 'Everything you copied', i: 'clip', go: 'deck' },
      { key: 'shelf', n: 'Open Daily Shelf', k: 'Today’s links at the edge of the screen', i: 'tray', go: 'dshelf' },
      { key: 'task', n: 'New Task', k: 'Add a task from anywhere', i: 'tasks', go: 'tasks' },
      { key: 'focus', n: 'Start a Focus Session', k: 'One task at a time', i: 'target', go: 'focus' }
    ];
    /* Fictional pictures drawn in CSS, so the demo ships no one's wallpaper. */
    const WALLS = [
      { n: 'signal', bg: '#0e3b3d url(assets/v3/wallpaper.webp) center/cover' },
      { n: 'dusk', bg: 'linear-gradient(160deg,#2b1f4d 0%,#7a3b6b 46%,#f08a6b 100%)' },
      { n: 'ink', bg: 'radial-gradient(120% 90% at 70% 18%,#f1ecdd 0%,#d5cfbd 42%,#77736a 100%)' },
      { n: 'neon-room', bg: 'linear-gradient(200deg,#0b1d3a 0%,#124a6c 38%,#c2338b 100%)' },
      { n: 'moss', bg: 'linear-gradient(170deg,#0c2a22 0%,#1f5a45 55%,#9fd19a 100%)' },
      { n: 'ember', bg: 'radial-gradient(90% 80% at 30% 82%,#ff7a3d 0%,#7a1f1f 46%,#16090b 100%)' },
      { n: 'horizon', bg: 'linear-gradient(180deg,#31405f 0%,#8d6a8c 55%,#e9a27c 100%)' }
    ];
    const ROWS = 6;
    const wallHost = opt.wall || null;
    const state = { sel: 0, w: 0, set: 0, mode: 'apps', said: '', list: [], walls: WALLS };
    let saidTimer;
    root.classList.add('lc');
    root.innerHTML = `<div class="lc-card"><div class="lc-list" role="listbox" aria-label="Results"></div><div class="lc-strip" role="listbox" aria-label="Wallpapers" hidden></div>
<div class="lc-field">${ic('search')}<input type="text" placeholder="Type &quot;&gt;&quot; for commands" autocomplete="off" spellcheck="false" maxlength="40" aria-label="Search apps, or type &gt; for commands"><span class="lc-said" role="status"></span><button type="button" class="lc-x" data-clear aria-label="Clear" hidden>${ic('x')}</button></div></div>`;
    const q = $('input', root), listEl = $('.lc-list', root), strip = $('.lc-strip', root), saidEl = $('.lc-said', root), clear = $('[data-clear]', root);
    const paint = i => { if (wallHost) wallHost.style.background = i === 0 ? '' : WALLS[i].bg; };
    function parse() {
      const text = q.value;
      if (!text.startsWith('>')) return { mode: 'apps', f: text.trim().toLowerCase() };
      const rest = text.slice(1).replace(/^ +/, ''), m = /^wallpaper\s(.*)$/i.exec(rest);
      return m ? { mode: 'walls', f: m[1].trim().toLowerCase() } : { mode: 'cmds', f: rest.trim().toLowerCase() };
    }
    function say(text) {
      state.said = text; saidEl.textContent = text;
      clearTimeout(saidTimer);
      saidTimer = setTimeout(() => { state.said = ''; saidEl.textContent = ''; }, 1600);
    }
    function placeTiles() {
      $$('.lc-wt', strip).forEach((el, i) => {
        const k = i - state.w, far = Math.abs(k);
        el.style.transform = `translateX(${k * 168 + (k ? Math.sign(k) * 12 : 0)}px) scale(${k ? 1 : 1.16})`;
        el.style.opacity = far > 2 ? 0 : far === 2 ? .55 : far === 1 ? .9 : 1;
        el.classList.toggle('on', !k); el.setAttribute('aria-selected', !k); el.tabIndex = -1;
      });
    }
    function render(keep) {
      const p = parse(), was = state.mode;
      state.mode = p.mode;
      clear.hidden = !q.value;
      root.classList.toggle('wall', p.mode === 'walls');
      listEl.hidden = p.mode === 'walls'; strip.hidden = p.mode !== 'walls';
      if (p.mode === 'walls') {
        state.walls = WALLS.filter(w => !p.f || w.n.includes(p.f));
        if (!state.walls.length) { state.mode = 'cmds'; root.classList.remove('wall'); listEl.hidden = false; strip.hidden = true; state.list = []; listEl.innerHTML = `<div class="lc-none">No picture called “${esc(p.f)}”.</div>`; return; }
        if (was !== 'walls') state.w = Math.max(0, state.walls.indexOf(WALLS[state.set]));
        state.w = clamp(state.w, 0, state.walls.length - 1);
        strip.innerHTML = state.walls.map((w, i) => `<button type="button" role="option" class="lc-wt" data-w="${i}"><i style="background:${w.bg}"></i><small>${w.n}</small></button>`).join('');
        placeTiles();
        if (was === 'walls') paint(WALLS.indexOf(state.walls[state.w]));
        return;
      }
      if (was === 'walls') paint(state.set);
      state.list = p.mode === 'apps' ? OP_DATA.apps.filter(a => !p.f || a.n.toLowerCase().includes(p.f)) : CMDS.filter(c => !p.f || c.n.toLowerCase().includes(p.f) || c.key.startsWith(p.f));
      if (!keep) state.sel = 0;
      state.sel = clamp(state.sel, 0, Math.max(0, state.list.length - 1));
      const first = clamp(state.sel - ROWS + 1, 0, Math.max(0, state.list.length - ROWS));
      listEl.innerHTML = state.list.length ? state.list.slice(first, first + ROWS).map((x, j) => {
        const i = first + j, on = i === state.sel, c = OP_C[i % OP_C.length];
        const icon = p.mode === 'apps' ? `<span class="lc-ic app" style="--c:${c}">${x.m}</span>` : `<span class="lc-ic">${ic(x.i)}</span>`;
        const sub = p.mode === 'apps' ? `${x.run ? 'Running · ' : ''}${x.cat}` : x.k;
        return `<button type="button" role="option" aria-selected="${on}" class="lc-row${on ? ' on' : ''}" data-i="${i}">${icon}<span class="lc-tx"><b>${x.n}</b><small>${sub}</small></span>${p.mode === 'cmds' ? `<span class="lc-key">&gt;${x.key}</span>` : ''}</button>`;
      }).join('') : `<div class="lc-none">${p.mode === 'apps' ? `Nothing on this Mac is called “${esc(p.f)}”.` : `No command called “${esc(p.f)}”.`}</div>`;
    }
    const setText = text => { q.value = text; render(); };
    function run() {
      if (state.mode === 'walls') {
        const w = state.walls[state.w];
        state.set = WALLS.indexOf(w); paint(state.set);
        say(`WALLPAPER · ${w.n.toUpperCase()}`);
        if (opt.onWall) opt.onWall(w); else setText('');
        return;
      }
      const x = state.list[state.sel];
      if (!x) return;
      if (x.list) { setText(`>${x.key} `); return; }
      const row = $('.lc-row.on', listEl);
      if (row) { row.classList.remove('go'); void row.offsetWidth; row.classList.add('go'); }
      say(`${state.mode === 'apps' ? (x.run ? 'FOCUSED' : 'OPENED') : 'RAN'} · ${x.n.toUpperCase()}`);
      if (opt.onRun) opt.onRun(x);
    }
    function move(n) {
      if (state.mode === 'walls') {
        const next = clamp(state.w + n, 0, state.walls.length - 1);
        if (next === state.w) return;
        state.w = next; placeTiles(); paint(WALLS.indexOf(state.walls[state.w]));
      } else { state.sel = clamp(state.sel + n, 0, Math.max(0, state.list.length - 1)); render(true); }
    }
    q.addEventListener('input', () => render());
    root.addEventListener('keydown', e => {
      const wall = state.mode === 'walls';
      if (e.key === 'ArrowDown' && !wall) { move(1); e.preventDefault(); }
      else if (e.key === 'ArrowUp' && !wall) { move(-1); e.preventDefault(); }
      else if (e.key === 'ArrowRight' && wall) { move(1); e.preventDefault(); }
      else if (e.key === 'ArrowLeft' && wall) { move(-1); e.preventDefault(); }
      else if (e.key === 'Tab' && document.activeElement === q) { const x = state.list[state.sel]; if (state.mode === 'cmds' && x) setText(`>${x.key}${x.list ? ' ' : ''}`); e.preventDefault(); }
      else if (e.key === 'Enter') { run(); e.preventDefault(); }
      else if (e.key === 'Escape') { if (opt.onEscape) opt.onEscape(); else setText(''); e.stopPropagation(); }
      else return;
      if (wall || e.key !== 'Escape') e.stopPropagation();
    });
    root.addEventListener('click', e => {
      const row = e.target.closest('.lc-row'), tile = e.target.closest('.lc-wt');
      if (e.target.closest('[data-clear]')) setText('');
      else if (row) { const i = +row.dataset.i; if (i === state.sel) run(); else { state.sel = i; render(true); } }
      else if (tile) { const i = +tile.dataset.w; if (i === state.w) run(); else move(i - state.w); }
      q.focus({ preventScroll: true });
    });
    strip.addEventListener('wheel', e => { e.preventDefault(); const d = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY; if (Math.abs(d) > 8) move(d > 0 ? 1 : -1); }, { passive: false });
    render();
    return {
      input: q, move, run, focus: () => q.focus({ preventScroll: true }),
      reset: () => { q.value = ''; state.said = ''; saidEl.textContent = ''; render(); },
      script: [['saf', o => o.run()], ['>', o => { o.move(1); o.move(1); }], ['>wallpaper ', o => { o.move(1); setTimeout(() => o.move(1), 700); setTimeout(() => o.run(), 1500); }], ['>po', o => o.run()]]
    };
  }

  /* ───── Minimal: a centred palette with branch tabs and a one-line inspector ───── */
  function OpenerMinimal(root, opt = {}) {
    const C = OP_C, DATA = OP_DATA, TABS = OP_TABS;
    const state = { tab: 0, sel: 0, q: '', said: '' };
    let saidTimer;
    root.classList.add('op');
    root.innerHTML = `<div class="op-z sgn">${zera({ s: 48 })}</div><div class="op-pane">${cns}
<div class="op-head"><div class="op-input">${cns}<span aria-hidden="true">&gt;</span><input type="text" placeholder="open an app, run a command…" autocomplete="off" spellcheck="false" maxlength="40" aria-label="Search apps, commands and actions"><span class="op-count"></span></div></div>
<div class="op-tabs" role="tablist"></div><div class="op-rule"></div><div class="op-list" role="listbox" aria-label="Results"></div><div class="op-insp"></div>
<div class="op-status"></div></div>`;
    const q = $('input', root), tabs = $('.op-tabs', root), listEl = $('.op-list', root), insp = $('.op-insp', root), status = $('.op-status', root), count = $('.op-count', root);
    const found = t => DATA[t].filter(x => !state.q || x.n.toLowerCase().includes(state.q));
    function render() {
      const l = found(TABS[state.tab]);
      state.sel = clamp(state.sel, 0, Math.max(0, l.length - 1));
      count.textContent = `${l.length} FOUND`;
      tabs.innerHTML = TABS.map((t, i) => `<button type="button" role="tab" aria-selected="${i === state.tab}" class="op-tab${i === state.tab ? ' on' : ''}" data-tab="${i}">${t.toUpperCase()}<b>${found(t).length}</b></button>`).join('');
      const first = clamp(state.sel - 4, 0, Math.max(0, l.length - 5));
      listEl.innerHTML = l.length ? l.slice(first, first + 5).map((x, j) => {
        const i = first + j, c = C[i % C.length], on = i === state.sel;
        return `<button type="button" role="option" aria-selected="${on}" class="op-row${on ? ' on' : ''}" data-i="${i}"><span class="op-idx" style="--c:${c}">${String(i + 1).padStart(2, '0')}</span><span class="op-ic" style="--c:${c}">${x.m || ic(x.i)}</span><span class="op-name">${x.n}</span><span class="op-meta">${x.run ? '<span class="op-dot"></span>' : ''}${x.pin ? 'pinned · ' : ''}${x.run ? 'running' : x.k || ''}${on ? '<span class="op-key">↵</span>' : `<span class="op-key">⌘${i + 1}</span>`}</span></button>`;
      }).join('') : '<div class="op-none">Nothing matches. Try another tab with ⇥.</div>';
      const x = l[state.sel], cell = (k, v) => `<div><div class="k">${k}</div><div class="v">${v}</div></div>`;
      insp.innerHTML = !x ? cell('STATUS', 'no selection')
        : state.tab === 0 ? cell('STATUS', x.run ? 'Running' : 'Not running') + cell('VERSION', x.ver) + cell('OPENED', x.opened) + cell('WHERE', '/Applications') + `<div class="op-btn"><span class="op-b">Pin <span class="op-key">⇧⌘P</span></span><button type="button" class="op-b p" data-run>${x.run ? 'Focus' : 'Open'} <span class="op-key">↵</span></button></div>`
          : cell('KIND', state.tab === 1 ? 'Command' : 'Zera action') + cell('DOES', x.k || 'opens it in the notch') + `<div class="op-btn"><button type="button" class="op-b p" data-run>Run <span class="op-key">↵</span></button></div>`;
      status.innerHTML = `<span class="op-live">LIVE</span><span>OPENER</span>${state.said ? `<span class="op-said">${state.said}</span>` : ''}<span class="op-hints"><span><span class="op-key">↑↓</span>choose</span><span><span class="op-key">⇥</span>tab</span><span><span class="op-key">↵</span>open</span><span><span class="op-key">esc</span>close</span></span>`;
    }
    function run() {
      const x = found(TABS[state.tab])[state.sel];
      if (!x) return;
      const row = $('.op-row.on', listEl);
      if (row) { row.classList.remove('go'); void row.offsetWidth; row.classList.add('go'); }
      state.said = `${opVerb(TABS[state.tab], x)} · ${x.n.toUpperCase()}`;
      status.querySelector('.op-said')?.remove();
      status.querySelector('span:nth-child(2)').insertAdjacentHTML('afterend', `<span class="op-said">${state.said}</span>`);
      clearTimeout(saidTimer);
      saidTimer = setTimeout(() => { state.said = ''; render(); }, 1500);
      if (opt.onRun) opt.onRun(x);
    }
    const move = n => { state.sel = clamp(state.sel + n, 0, Math.max(0, found(TABS[state.tab]).length - 1)); render(); };
    const tab = n => { state.tab = (state.tab + n + TABS.length) % TABS.length; state.sel = 0; render(); };
    q.addEventListener('input', () => { state.q = q.value.trim().toLowerCase(); state.sel = 0; render(); });
    root.addEventListener('keydown', e => {
      if (e.key === 'ArrowDown') { move(1); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { move(-1); e.preventDefault(); }
      else if (e.key === 'Tab' && document.activeElement === q) { tab(e.shiftKey ? -1 : 1); e.preventDefault(); }
      else if (e.key === 'Enter') { run(); e.preventDefault(); }
      else if (e.key === 'Escape') { if (opt.onEscape) opt.onEscape(); else { q.value = ''; state.q = ''; render(); } e.stopPropagation(); }
      else if ((e.metaKey || e.ctrlKey) && /^[1-9]$/.test(e.key)) { state.sel = +e.key - 1; render(); run(); e.preventDefault(); }
    });
    root.addEventListener('click', e => {
      const t = e.target.closest('[data-tab]'), row = e.target.closest('.op-row');
      if (t) { state.tab = +t.dataset.tab; state.sel = 0; render(); q.focus({ preventScroll: true }); }
      else if (row) { const i = +row.dataset.i; if (i === state.sel) run(); else { state.sel = i; render(); } q.focus({ preventScroll: true }); }
      else if (e.target.closest('[data-run]')) run();
    });
    render();
    return {
      input: q, move, tab, run, focus: () => q.focus({ preventScroll: true }),
      reset: () => { q.value = ''; state.q = ''; state.tab = 0; state.sel = 0; state.said = ''; render(); },
      script: [['saf', o => o.run()], ['', o => { o.tab(1); o.tab(1); o.move(1); o.move(1); }], ['fo', o => { o.tab(1); o.tab(1); o.run(); }]]
    };
  }

  /* ───── Tree (classic): a window Zera holds on a lit line. The search is the root; branches fold
     open under it and the chosen item's facts sit on the right. ───── */
  function OpenerTree(root, opt = {}) {
    const state = { branch: 0, sel: 0, q: '', said: '' };
    let saidTimer, flat = [];
    root.classList.add('ot');
    root.innerHTML = `<div class="ot-rope"></div><div class="ot-z sgn">${zera({ s: 56 })}</div><div class="ot-pane">${cns}
<div class="ot-head"><span class="ot-root">${ic('search')}</span><div class="op-input">${cns}<input type="text" placeholder="Open an app…" autocomplete="off" spellcheck="false" maxlength="40" aria-label="Search apps, commands and actions"><span class="op-count"></span></div></div>
<div class="ot-body"><div class="ot-tree" role="listbox" aria-label="Results"></div><div class="ot-detail"></div></div>
<div class="op-status"></div></div>`;
    const q = $('input', root), tree = $('.ot-tree', root), detail = $('.ot-detail', root), status = $('.op-status', root), count = $('.op-count', root);
    function render() {
      const typing = !!state.q;
      flat = [];
      let html = '';
      OP_TABS.forEach((t, b) => {
        const all = opFound(t, state.q), open = typing ? all.length > 0 : b === state.branch;
        if (typing && !all.length) return;
        html += `<button type="button" class="ot-group${open ? ' open' : ''}" data-branch="${b}"><i></i>${t === 'apps' ? (typing ? 'APPS' : 'YOUR USUAL') : t.toUpperCase()}<b>${all.length}</b></button>`;
        if (!open) return;
        const start = flat.length, shown = all.slice(0, typing ? 3 : 5);
        shown.forEach(x => flat.push({ t, x }));
        html += `<div class="ot-kids">${shown.map((x, j) => { const i = start + j; return `<button type="button" role="option" class="ot-row" data-i="${i}"><span class="op-ic" style="--c:${OP_C[i % OP_C.length]}">${x.m || ic(x.i)}</span><span class="op-name">${x.n}</span><span class="op-meta">${x.pin ? 'Pinned' : x.run ? '<span class="op-dot"></span>running' : ''}</span></button>`; }).join('')}</div>`;
      });
      state.sel = clamp(state.sel, 0, Math.max(0, flat.length - 1));
      tree.innerHTML = html || '<div class="op-none">Nothing called that. ↵ would search the web.</div>';
      $$('.ot-row', tree).forEach((el, i) => { el.classList.toggle('on', i === state.sel); el.setAttribute('aria-selected', i === state.sel); });
      count.textContent = typing ? (flat.length ? `${flat.length} FOUND` : 'NO MATCHES') : '';
      const cur = flat[state.sel];
      detail.innerHTML = !cur ? '<div class="ot-empty">Choose something on the left.</div>'
        : `<span class="ot-big" style="--c:${OP_C[state.sel % OP_C.length]}">${cur.x.m || ic(cur.x.i)}</span><b class="ot-name">${cur.x.n}</b><small class="ot-kind">${cur.t === 'apps' ? 'Application' : cur.t === 'commands' ? 'Command' : 'Zera action'}</small>
<div class="ot-facts">${opFacts(cur.t, cur.x).map(([k, v]) => `<div><span>${k}</span><b>${v}</b></div>`).join('')}</div>
<button type="button" class="op-b p ot-go" data-run>${cur.t === 'apps' ? (cur.x.run ? 'Focus' : 'Open') : 'Run'} ${cur.x.n} <span class="op-key">↵</span></button>`;
      status.innerHTML = `<span class="op-live">LIVE</span><span>TREE</span>${state.said ? `<span class="op-said">${state.said}</span>` : ''}<span class="op-hints"><span><span class="op-key">↑↓</span>choose</span><span><span class="op-key">⇥</span>next branch</span><span><span class="op-key">↵</span>open</span><span><span class="op-key">esc</span>close</span></span>`;
    }
    function run() {
      const cur = flat[state.sel];
      if (!cur) return;
      const row = $('.ot-row.on', tree);
      if (row) { row.classList.remove('go'); void row.offsetWidth; row.classList.add('go'); }
      state.said = `${opVerb(cur.t, cur.x)} · ${cur.x.n.toUpperCase()}`;
      clearTimeout(saidTimer);
      saidTimer = setTimeout(() => { state.said = ''; render(); }, 1500);
      const keep = row ? row.className : '';
      render();
      if (keep) { const again = $('.ot-row.on', tree); if (again) again.classList.add('go'); }
      if (opt.onRun) opt.onRun(cur.x);
    }
    const move = n => { state.sel = clamp(state.sel + n, 0, Math.max(0, flat.length - 1)); render(); };
    const tab = n => { state.branch = (state.branch + n + OP_TABS.length) % OP_TABS.length; state.sel = 0; render(); };
    q.addEventListener('input', () => { state.q = q.value.trim().toLowerCase(); state.sel = 0; render(); });
    root.addEventListener('keydown', e => {
      if (e.key === 'ArrowDown') { move(1); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { move(-1); e.preventDefault(); }
      else if (e.key === 'Tab' && document.activeElement === q) { tab(e.shiftKey ? -1 : 1); e.preventDefault(); }
      else if (e.key === 'Enter') { run(); e.preventDefault(); }
      else if (e.key === 'Escape') { if (opt.onEscape) opt.onEscape(); else { q.value = ''; state.q = ''; render(); } e.stopPropagation(); }
    });
    root.addEventListener('click', e => {
      const g = e.target.closest('[data-branch]'), row = e.target.closest('.ot-row');
      if (g) { state.branch = +g.dataset.branch; state.sel = 0; render(); }
      else if (row) { const i = +row.dataset.i; if (i === state.sel) run(); else { state.sel = i; render(); } }
      else if (e.target.closest('[data-run]')) run();
      q.focus({ preventScroll: true });
    });
    render();
    return {
      input: q, move, tab, run, focus: () => q.focus({ preventScroll: true }),
      reset: () => { q.value = ''; state.q = ''; state.branch = 0; state.sel = 0; state.said = ''; render(); },
      script: [['', o => { o.move(1); o.move(1); }], ['saf', o => o.run()], ['', o => { o.tab(1); o.move(1); }], ['fo', o => o.run()]]
    };
  }

  /* ───── Orbit: the search in the middle of a dimmed screen, the results on an arc under it ───── */
  function OpenerOrbit(root, opt = {}) {
    const NAMES = ['YOUR USUAL', 'COMMANDS', 'ACTIONS'];
    const state = { tab: 0, sel: 0, q: '', said: '' };
    let saidTimer, list = [];
    root.classList.add('oo');
    root.innerHTML = `<div class="oo-z sgn">${zera({ s: 44 })}</div>
<div class="oo-search">${ic('search')}<input type="text" placeholder="Search apps, commands, or actions…" autocomplete="off" spellcheck="false" maxlength="40" aria-label="Search apps, commands and actions"></div>
<div class="oo-tabs" role="tablist"></div><div class="oo-arc" role="listbox" aria-label="Results"></div><div class="oo-card"></div>
<div class="oo-hints"><span><span class="op-key">←</span><span class="op-key">→</span>navigate</span><span><span class="op-key">⇥</span>switch tab</span><span><span class="op-key">↵</span>open</span><span><span class="op-key">esc</span>close</span></div>`;
    const q = $('input', root), tabs = $('.oo-tabs', root), arc = $('.oo-arc', root), card = $('.oo-card', root);
    function place() {
      $$('.oo-tile', arc).forEach((el, i) => {
        const k = i - state.sel, far = Math.abs(k);
        el.style.transform = `translate(${k * 96}px,${k * k * 3.2}px) scale(${k === 0 ? 1.25 : far === 1 ? 1 : .875})`;
        el.style.opacity = far > 3 ? 0 : 1;
        el.style.pointerEvents = far > 3 ? 'none' : '';
        el.classList.toggle('on', !k); el.setAttribute('aria-selected', !k);
      });
      const t = OP_TABS[state.tab], x = list[state.sel];
      card.innerHTML = !x ? '<span class="oo-none">Nothing matches. Try another tab with ⇥.</span>'
        : `<span class="op-ic" style="--c:${OP_C[state.sel % OP_C.length]}">${x.m || ic(x.i)}</span><span class="oo-what"><b>${x.n}</b><small>${opFacts(t, x).slice(0, 3).map(f => f[1]).join(' · ')}</small></span>${state.said ? `<span class="op-said">${state.said}</span>` : ''}<button type="button" class="op-b p" data-run>${t === 'apps' ? (x.run ? 'Focus app' : 'Open app') : 'Run'} <span class="op-key">↵</span></button>`;
    }
    function render() {
      list = opFound(OP_TABS[state.tab], state.q);
      state.sel = clamp(state.sel, 0, Math.max(0, list.length - 1));
      tabs.innerHTML = OP_TABS.map((t, i) => `<button type="button" role="tab" aria-selected="${i === state.tab}" class="oo-tab${i === state.tab ? ' on' : ''}" data-tab="${i}">${NAMES[i]}<b>${opFound(t, state.q).length}</b></button>`).join('');
      arc.innerHTML = list.map((x, i) => `<button type="button" role="option" class="oo-tile" data-i="${i}"><span class="oo-ic" style="--c:${OP_C[i % OP_C.length]}">${x.m || ic(x.i)}</span>${x.run ? '<i class="oo-run"></i>' : ''}<small>${x.n}</small></button>`).join('');
      place();
    }
    function run() {
      const x = list[state.sel];
      if (!x) return;
      const tile = $('.oo-tile.on', arc);
      if (tile) { tile.classList.remove('go'); void tile.offsetWidth; tile.classList.add('go'); }
      state.said = `${opVerb(OP_TABS[state.tab], x)} · ${x.n.toUpperCase()}`;
      clearTimeout(saidTimer);
      saidTimer = setTimeout(() => { state.said = ''; place(); }, 1500);
      place();
      if (opt.onRun) opt.onRun(x);
    }
    const move = n => { const next = clamp(state.sel + n, 0, Math.max(0, list.length - 1)); if (next !== state.sel) { state.sel = next; place(); } };
    const tab = n => { state.tab = (state.tab + n + OP_TABS.length) % OP_TABS.length; state.sel = Math.min(2, Math.max(0, opFound(OP_TABS[state.tab], state.q).length - 1)); render(); };
    q.addEventListener('input', () => { state.q = q.value.trim().toLowerCase(); state.sel = 0; render(); });
    root.addEventListener('keydown', e => {
      const typing = document.activeElement === q && q.value;
      if (e.key === 'ArrowRight' && !typing) { move(1); e.preventDefault(); }
      else if (e.key === 'ArrowLeft' && !typing) { move(-1); e.preventDefault(); }
      else if (e.key === 'ArrowDown') { move(1); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { move(-1); e.preventDefault(); }
      else if (e.key === 'Tab' && document.activeElement === q) { tab(e.shiftKey ? -1 : 1); e.preventDefault(); }
      else if (e.key === 'Enter') { run(); e.preventDefault(); }
      else if (e.key === 'Escape') { if (opt.onEscape) opt.onEscape(); else { q.value = ''; state.q = ''; render(); } e.stopPropagation(); }
      else return;
      e.stopPropagation();
    });
    root.addEventListener('click', e => {
      const t = e.target.closest('[data-tab]'), tile = e.target.closest('.oo-tile');
      if (t) { state.tab = +t.dataset.tab; state.sel = Math.min(2, Math.max(0, opFound(OP_TABS[state.tab], state.q).length - 1)); render(); }
      else if (tile) { const i = +tile.dataset.i; if (i === state.sel) run(); else { state.sel = i; place(); } }
      else if (e.target.closest('[data-run]')) run();
      q.focus({ preventScroll: true });
    });
    arc.addEventListener('wheel', e => { e.preventDefault(); const d = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY; if (Math.abs(d) > 8) move(d > 0 ? 1 : -1); }, { passive: false });
    const reset = () => { q.value = ''; state.q = ''; state.tab = 0; state.sel = 2; state.said = ''; render(); };
    reset();
    return {
      input: q, move, tab, run, focus: () => q.focus({ preventScroll: true }), reset,
      script: [['', o => { o.move(1); setTimeout(() => o.move(1), 500); setTimeout(() => o.move(-1), 1000); }], ['no', o => o.run()], ['', o => { o.tab(1); o.move(1); }], ['', o => { o.tab(1); o.tab(1); o.move(1); o.run(); }]]
    };
  }
  const OPENERS = { launcher: Launcher, minimal: OpenerMinimal, tree: OpenerTree, orbit: OpenerOrbit };

  /* ═════ Daily Shelf ═════ */
  function Shelf(root, opt = {}) {
    const st = {
      seg: 0, open: false,
      prs: [
        { n: 214, repo: 'aurora-web', t: 'Make the settings page work from the keyboard', meta: '12m · <span class="ok">+212</span> <span class="er">−48</span>', k: 'e', label: '2 failing', g: 'move' },
        { n: 418, repo: 'aurora', t: 'Cache favicons per host on disk', meta: '@theo · 35m', k: 'w', label: 'Changes asked', g: 'move' },
        { n: 412, repo: 'aurora', t: 'Add themes: seven built in, plus your own', meta: '@theo · 25m', k: 'g', label: 'Ready to merge', g: 'ready' }
      ],
      jira: [{ key: 'AUR-142', t: 'Settings: full keyboard navigation', pin: true }],
      meet: [{ t: 'Design review: settings v3', at: '18:13' }],
      docs: [{ t: 'Release checklist', host: 'docs' }],
      sites: [['V', 'var(--fg)', 'vercel'], ['S', ROSE, 'sentry'], ['G', 'var(--env)', 'grafana'], ['L', VIOLET, 'linear'], ['F', BLUE, 'figma']],
      notes: [{ t: 'swift test --filter DailyShelf' }]
    };
    const KC = { e: 'var(--err)', w: 'var(--warn)', g: 'var(--ok)', b: 'var(--info)', n: 'var(--dim)' };
    root.classList.add('dsh', 'sgn');
    root.setAttribute('role', 'region');
    root.setAttribute('aria-label', 'Daily Shelf demo');
    root.innerHTML = `<div class="hd">${zera({ s: 30, wave: true })}<span class="ti"><b>Today</b> <small data-date></small><br><small data-count></small></span><span class="sp"></span>${ibs('search', 'standup')}${opt.onClose ? ibtn('x', 'close', 'Close the shelf') : ibs('pin')}</div>
<div class="bd"><label class="add">${ic('plus')}<input type="text" placeholder="Paste a link or jot a note" autocomplete="off" spellcheck="false" maxlength="140" aria-label="Paste a link or jot a note">${kbd('↵')}</label>
<div class="segs" data-segs></div><div data-list></div></div>
<div class="sb"><span class="live"><i></i>LIVE</span><span>CLEARS 04:00 · PINNED STAY</span><span class="sp"></span><span data-said></span></div><i class="grip"></i>`;
    const input = $('input', root), listEl = $('[data-list]', root), segsEl = $('[data-segs]', root), said = $('[data-said]', root);
    $('[data-date]', root).textContent = new Date().toLocaleDateString('en-GB', { weekday: 'short', day: '2-digit', month: 'short' });
    const total = () => st.prs.length + st.jira.length + st.meet.length + st.docs.length + st.sites.length + st.notes.length;
    const sub2 = (c, t) => `<div class="sub2"><i style="--c:${c}"></i>${t}</div>`;
    const prRow = p => `<div class="r pr${p.fresh ? ' new-in' : ''}">${ix(p.n, KC[p.k])}<span class="m"><span class="t">${esc(p.t)}</span><span class="s">${esc(p.repo)} · ${p.meta}</span></span>${chip(p.label, p.k, null, p.busy ? 'p' : null)}</div>`;
    function render() {
      const need = st.prs.filter(p => p.g === 'move').length;
      $('[data-count]', root).innerHTML = `${total()} items · <span class="${need ? 'er' : 'ok'}">${need ? need + ' need you' : 'all clear'}</span>`;
      const SEG = [['All', total()], ['PRs', st.prs.length], ['Jira', st.jira.length], ['Meet', st.meet.length], ['Docs', st.docs.length], ['Sites', st.sites.length], ['Notes', st.notes.length]];
      segsEl.innerHTML = `<span class="sg">${SEG.map(([t, n], i) => `<button type="button" class="${i === st.seg ? 'on' : ''}" data-seg="${i}" aria-pressed="${i === st.seg}">${t}<b class="ct">${n}</b></button>`).join('')}</span>`;
      const show = i => st.seg === 0 || st.seg === i;
      let h = '';
      if (show(3) && st.meet.length) h += st.meet.map(m => r({ cls: 'sm' + (m.fresh ? ' new-in' : ''), l: ix(ic('video'), VIOLET), t: esc(m.t), s: `up next · ${m.at}`, r: btn('Join', 'f') })).join('');
      if (show(1) && st.prs.length) {
        const move = st.prs.filter(p => p.g === 'move'), ready = st.prs.filter(p => p.g === 'ready'), wait = st.prs.filter(p => p.g === 'wait');
        h += lbl('PULL REQUESTS', String(st.prs.length).padStart(2, '0'), `<span class="ac" style="letter-spacing:.04em">open ${st.prs.length}</span>`);
        if (move.length) h += sub2('var(--err)', 'YOUR MOVE') + move.map(prRow).join('');
        if (wait.length) h += sub2('var(--info)', 'WAITING ON CHECKS') + wait.map(prRow).join('');
        if (ready.length) h += sub2('var(--ok)', 'READY TO MERGE') + ready.map(prRow).join('');
      }
      if (show(2) && st.jira.length) h += lbl('JIRA', String(st.jira.length).padStart(2, '0')) + st.jira.map((j, i) => r({ cls: 'sm' + (j.fresh ? ' new-in' : ''), l: ix(ic('jira'), 'var(--info)'), t: esc(j.t), s: esc(j.key), r: ibtn('pin', 'pin', j.pin ? 'Unpin' : 'Pin for tomorrow', { kind: 'jira', i }, j.pin ? 'lit' : '') })).join('');
      if (show(4) && st.docs.length) h += lbl('DOCS', String(st.docs.length).padStart(2, '0')) + st.docs.map(d => r({ cls: 'sm' + (d.fresh ? ' new-in' : ''), l: ix(ic('file'), 'var(--env)'), t: esc(d.t), s: esc(d.host) })).join('');
      if (show(5) && st.sites.length) h += lbl('SITES', String(st.sites.length).padStart(2, '0')) + `<div class="sites">${st.sites.map(([t, c, n]) => `<span class="ix lg" style="--c:${c}" title="${esc(n)}">${esc(t)}</span>`).join('')}</div>`;
      if (show(6) && st.notes.length) h += lbl('NOTES', String(st.notes.length).padStart(2, '0')) + st.notes.map((n, i) => r({ cls: 'sm' + (n.fresh ? ' new-in' : ''), l: ix(CAR.replace('class="car"', 'class="car" style="margin:0"'), 'var(--dim)'), t: esc(n.t), r: ibtn('x', 'rm', 'Remove note', { kind: 'notes', i }) })).join('');
      listEl.innerHTML = h || '<div class="empty">Nothing here yet. Paste a link above.</div>';
      [st.prs, st.jira, st.meet, st.docs, st.notes].forEach(a => a.forEach(x => { x.fresh = false; }));
    }
    const say = t => { said.textContent = t; clearTimeout(say.t); say.t = setTimeout(() => { said.textContent = ''; }, 2200); };
    /* Files a pasted line by rule, like the app does for links it recognises. Nothing is fetched. */
    function add(text) {
      const raw = text.trim().slice(0, 140);
      if (!raw) return;
      let u = null;
      try { u = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(raw) ? raw : /^[\w-]+(\.[\w-]+)+(\/\S*)?$/.test(raw) ? 'https://' + raw : ''); } catch { u = null; }
      if (u && !/^https?:$/.test(u.protocol)) u = null;
      const host = u ? u.hostname.replace(/^www\./, '') : '';
      let m;
      if (u && host === 'github.com' && (m = u.pathname.match(/^\/([\w.-]+)\/([\w.-]+)\/pull\/(\d{1,6})/))) {
        const p = { n: +m[3], repo: m[2], t: opt.titles?.[m[3]] || `Pull request #${m[3]}`, meta: 'just now', k: 'b', label: 'Checking', busy: true, g: 'wait', fresh: true };
        st.prs.unshift(p); say('FILED · PULL REQUESTS');
        setTimeout(() => { p.busy = false; p.k = 'g'; p.label = 'Checks passing'; p.g = 'ready'; render(); }, 2600);
      } else if (u && /\.atlassian\.net$/.test(host) && (m = u.pathname.match(/browse\/([A-Z][A-Z0-9]+-\d+)/))) { st.jira.unshift({ key: m[1], t: `Ticket ${m[1]}`, fresh: true }); say('FILED · JIRA'); }
      else if (u && /(^|\.)(meet\.google\.com|zoom\.us|teams\.microsoft\.com)$/.test(host)) { st.meet.unshift({ t: 'Meeting link', at: 'now', fresh: true }); say('FILED · MEET'); }
      else if (u && /(^|\.)(docs\.google\.com|notion\.so|notion\.site|figma\.com)$/.test(host)) { st.docs.unshift({ t: (u.pathname.split('/').filter(Boolean).pop() || host).slice(0, 40), host, fresh: true }); say('FILED · DOCS'); }
      else if (u) { st.sites.unshift([host[0].toUpperCase(), [BLUE, ROSE, VIOLET, 'var(--ok)', 'var(--env)'][host.length % 5], host]); say('FILED · SITES'); }
      else { st.notes.unshift({ t: raw, fresh: true }); say('SAVED · NOTE'); }
      st.seg = 0; render();
      $('.bd', root).scrollTop = 0;
    }
    input.addEventListener('keydown', e => {
      if (e.key === 'Enter') { add(input.value); input.value = ''; e.preventDefault(); }
      else if (e.key === 'Escape' && opt.onClose) { opt.onClose(); e.stopPropagation(); }
      e.stopPropagation();
    });
    root.addEventListener('click', e => {
      const s = e.target.closest('[data-seg]'), a = e.target.closest('[data-act]');
      if (s) { st.seg = +s.dataset.seg; render(); }
      else if (a?.dataset.act === 'pin') { const x = st[a.dataset.kind][+a.dataset.i]; x.pin = !x.pin; say(x.pin ? 'PINNED · STAYS TOMORROW' : 'UNPINNED'); render(); }
      else if (a?.dataset.act === 'rm') { st[a.dataset.kind].splice(+a.dataset.i, 1); render(); }
      else if (a?.dataset.act === 'close') opt.onClose();
    });
    render();
    const setOpen = v => { st.open = v; root.classList.toggle('open', v); if (!v) input.blur(); };
    return { input, add, open: () => setOpen(true), close: () => setOpen(false), isOpen: () => st.open, root };
  }

  /* ═════ Wings: an agent's live activity either side of the notch ═════ */
  function Wings(host, opt = {}) {
    let state = 'idle', p = 0, t0 = 0, timer = null, tick = null, hands = false;
    const show = html => {
      host.innerHTML = html;
      const w = host.firstElementChild;
      if (w && !still()) { w.classList.add('out'); requestAnimationFrame(() => requestAnimationFrame(() => w.classList.remove('out'))); }
    };
    const left = (c, f, a, b) => `${ix('C1', c, f)}<span style="line-height:1.4"><b style="font-size:12.5px">${a}</b><br><span class="d" style="font-size:10.5px">${b}</span></span><span class="sp"></span><span class="ib rd">${ic('chevd')}</span>`;
    const after = (ms, fn) => { clearTimeout(timer); timer = setTimeout(fn, ms); };
    function set(s) {
      state = s; clearInterval(tick); clearTimeout(timer);
      if (opt.onState) opt.onState(s);
      if (s === 'idle') { host.innerHTML = opt.idle || ''; return; }
      if (s === 'run' || s === 'run2') {
        if (s === 'run') { p = 18; t0 = 9; }
        show(wings({ lw: 300, rw: 330, mood: 'think', L: left(null, 'f', 'Claude is working', s === 'run' ? 'Reading Settings.swift' : 'Running ThemeStoreTests'),
          R: `${chip('RUNNING', '', null, 'p')}<span class="row" style="flex:1">${bar(p, null, 'wp')}</span><b data-live="wpc">${p}%</b><span class="d" data-live="wt">${mmss(t0)}</span><i class="sorb"></i><span class="ib rd">${ic('minus')}</span>` }));
        const end = s === 'run' ? 62 : 100;
        tick = setInterval(() => {
          p = Math.min(end, p + (s === 'run' ? 5 : 6)); t0 += 1;
          const b = $('[data-live="wp"]', host); if (b) b.style.width = p + '%';
          const c = $('[data-live="wpc"]', host); if (c) c.textContent = p + '%';
          const tt = $('[data-live="wt"]', host); if (tt) tt.textContent = mmss(t0);
          if (p >= end) { clearInterval(tick); after(700, () => set(s === 'run' ? 'ask' : 'done')); }
        }, 520);
      } else if (s === 'ask') {
        show(wings({ lw: 280, rw: 470, col: 'var(--warn)', mood: 'warn', L: left('var(--warn)', 'f', 'Claude is ready', 'waiting on you'),
          R: `<span class="ib rd">${ic('term')}</span><span style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis">swift test --filter ThemeStoreTests</span>${btn('Reject', 'e', 'x', null, 'w-reject')}${btn('Approve', 'g', 'ok', null, 'w-approve')}` }));
        if (!hands) after(5200, () => set('run2'));       // approvals never auto-hide in the app; the demo moves on only while nobody is driving
      } else if (s === 'done') {
        show(wings({ lw: 290, rw: 400, col: 'var(--ok)', mood: 'ok', wave: true, L: left('var(--ok)', 'f', 'Claude is done', 'Fix the theme picker'),
          R: `${chip('DONE', 'g', 'ok')}<span class="d">${mmss(t0)}</span><span class="reply">${CAR}<span class="ft">Reply…</span><span class="cur s" style="background:var(--ok);box-shadow:0 0 10px var(--ok)"></span><i></i></span><span class="ib rd">${ic('minus')}</span>` }));
        after(6200, () => set('idle'));
      } else if (s === 'no') {
        show(wings({ lw: 290, rw: 330, col: 'var(--err)', mood: 'err', L: left('var(--err)', 'f', 'Claude stopped', 'you rejected the command'), R: `${chip('REJECTED', 'e', 'x')}<span class="d" style="flex:1">Nothing ran.</span><span class="ib rd">${ic('minus')}</span>` }));
        after(3200, () => set('idle'));
      }
      if (s === 'idle' && opt.loop) after(1800, () => set('run'));
    }
    host.addEventListener('click', e => {
      const a = e.target.closest('[data-act]');
      if (!a) return;
      hands = true;
      if (a.dataset.act === 'w-approve') set('run2'); else if (a.dataset.act === 'w-reject') set('no');
    });
    const api = { start: () => { if (state === 'idle') set('run'); }, stop: () => { clearInterval(tick); clearTimeout(timer); state = 'idle'; host.innerHTML = opt.idle || ''; if (opt.onState) opt.onState('idle'); }, state: () => state, touch: () => { hands = true; } };
    if (opt.loop) { const s0 = set; set = s => { s0(s); if (s === 'idle') after(1800, () => { if (api.live) s0('run'); }); }; }
    host.innerHTML = opt.idle || '';
    return api;
  }

  /* ═════ The desktop in the hero ═════ */
  function Stage(desk) {
    const NAV = [['home', 'home', 'Home'], ['agents', 'term', 'Agents'], ['prs', 'pr', 'Pull requests'], ['alerts', 'bell', 'Alerts'], ['clip', 'clip', 'Clipboard'],
      ['shelf', 'tray', 'Shelf'], ['tasks', 'tasks', 'Tasks'], ['rem', 'cal', 'Reminders'], ['tele', 'lines', 'Teleprompter'], ['focus', 'target', 'Focus']];
    const now = new Date(), day = now.toLocaleDateString('en-GB', { weekday: 'short', day: '2-digit', month: 'short' }).toLowerCase();
    const st = {
      key: 'home', open: false, auto: !still(), seen: false,
      c2: 'ask', p1: 62, t1: 252,
      prs: 0, prSel: 0,
      alerts: [['00:21:58', 'WARN', 'wn', 'codex', 'Review the new layout · needs your approval', 'agents'], ['00:18:02', 'FAIL', 'er', 'aurora-web', '#214 · 2 checks failing', 'prs'], ['00:12:40', 'DONE', 'ok', 'claude', 'Polish the preferences · finished in 3m 12s'], ['23:58:11', 'INFO', 'ac', 'reminders', 'Design review at 11:42', 'rem'], ['23:40:03', 'WARN', 'wn', 'system', 'Battery 20% · plug in soon']],
      clipSeg: 0, clipSel: 0,
      clips: [{ k: 'text', t: 'A little less switching. A little more focus.', s: 'text · 45 chars · just now' }, { k: 'link', t: 'https://example.com/studio/notes', s: 'link · example.com · just now' }, { k: 'color', t: '#9B8CFF', s: 'colour · rgb 155 140 255 · just now' }, { k: 'code', t: 'layer?.borderColor = Pal.border.cgColor', s: 'code · swift · 2 min ago' }],
      fileSel: 0, answer: null,
      proj: 0,
      tasks: [{ t: 'Ship the dark mode toggle', p: 'Aurora', e: '45m' }, { t: 'Review Theo’s avatar cache PR', p: 'Aurora', e: '20m' }, { t: 'Write the launch post', p: 'Website', e: '30m' }, { t: 'Plan next sprint', p: 'General', e: '' }],
      rem: [false, false], water: 3,
      tele: { roll: true, i: 1, play: true, speed: 1, mirror: false },
      focus: { total: 45 * 60, left: 45 * 60 - 2, run: true, task: 'Ship the dark mode toggle' },
      set: { sig: '#7be1c2', glass: 0, trace: true, br: true, glow: 1 }
    };
    const PC = { General: 'var(--sig)', Aurora: VIOLET, Website: ROSE };
    const PROJ = ['All', 'General', 'Aurora', 'Website'];
    const TELE = ['Your agents, files and focus.', 'Close at hand, in the notch.', 'Zera v2 is a native Mac companion.', 'Today’s links wait at the edge.', 'Copy once. Find it again.', 'A little less switching.'];
    const SIGS = [['Tidal', '#7be1c2'], ['Void', '#5ab8ff'], ['Violet', '#9b8df9'], ['Ember', '#ff9e64'], ['Phosphor', '#5dfc9a']];
    const timers = new Set();
    const later = (fn, ms) => { const id = setTimeout(() => { timers.delete(id); fn(); }, ms); timers.add(id); return id; };

    desk.innerHTML = `<div class="mb"><b>Zera</b><span>File</span><span>Edit</span><span>View</span><span class="sp"></span><span data-live="date"></span></div>
<span class="tagl" data-hint style="left:50%;top:96px;transform:translateX(-50%)">CLICK ZERA TO OPEN THE NOTCH</span>
<button type="button" class="dcue" data-act="dshelf" aria-label="Open Daily Shelf"></button><div data-shelf></div>
<div data-wings></div>
<div class="islw"><div class="islc"><div class="isli"><div class="wash"></div><svg class="trace" aria-hidden="true"><path class="t0"/><path class="t1"/></svg><i class="ind"></i>
<div class="nav lf">${NAV.slice(0, 5).map(nt).join('')}</div><div class="nav rt">${NAV.slice(5).map(nt).join('')}</div>
<div class="itr">${ibtn('gear', 'go', 'Settings', { go: 'settings' })}${ibtn('x', 'toggle', 'Close the notch')}</div>
<section class="pn" aria-live="off">${cns}<i class="port lf"></i><div class="scanh"><div class="scan"></div></div><div class="pt"></div><div class="pb"></div></section><div class="sb"></div></div></div></div>
<div class="notch" data-act="toggle"></div>
<button type="button" class="zz small" data-act="toggle" aria-label="Open or close the notch" aria-expanded="false"><span></span></button>
<div class="fl echo" role="status"></div><div class="dimr" data-act="close-op"></div>
<div class="stage-op" data-op></div><div class="stage-deck" data-deck></div>`;
    function nt([k, icn, name]) { return `<button type="button" class="nt" data-act="go" data-go="${k}" data-tip="${name.toUpperCase()}" aria-label="${name}">${ic(icn)}<em></em></button>`; }

    const islw = $('.islw', desk), isli = $('.isli', desk), pn = $('.pn', desk), pt = $('.pt', desk), pb = $('.pb', desk), sb = $('.isli > .sb', desk);
    const ind = $('.ind', desk), zz = $('.zz', desk), zzIn = $('.zz > span', desk), echoEl = $('.echo', desk), hint = $('[data-hint]', desk), dimr = $('.dimr', desk);
    const gear = $('.itr .ib', desk), scan = $('.pn .scan', desk), cue = $('.dcue', desk);
    $('[data-live="date"]', desk).textContent = now.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });

    const shelf = Shelf($('[data-shelf]', desk), { onClose: () => toggleShelf(false), titles: { 91: 'Pin the runner image digest' } });
    const opHost = $('[data-op]', desk), opEl = document.createElement('div'); opHost.appendChild(opEl);
    const opener = Launcher(opEl, { wall: desk, onEscape: () => toggleOpener(false), onWall: w => later(() => { toggleOpener(false); echo(`${kbd('↵', 1)}<b>WALLPAPER SET</b><span class="d">${esc(w.n)}</span>`); }, 420), onRun: x => later(() => { toggleOpener(false); if (x.go === 'dshelf') toggleShelf(true); else if (x.go === 'deck') toggleDeck(true); else if (x.go) { setOpen(true); go(x.go); } else echo(`${kbd('↵', 1)}<b>${esc(x.n)}</b><span class="d">in the app this opens for real</span>`); }, 620) });
    const deckHost = $('[data-deck]', desk), deckEl = document.createElement('div'); deckHost.appendChild(deckEl);
    const deck = Deck(deckEl, { onEscape: () => toggleDeck(false), onCopied: () => toggleDeck(false), onCopy: it => echo(`${kbd('↵', 1)}<b>COPIED</b><span class="d">${esc(it.title.slice(0, 34))}</span><span class="ft">⌘V to paste</span>`), onOpenFull: () => { toggleDeck(false); setOpen(true); go('clip'); } });
    const wingsApi = Wings($('[data-wings]', desk), { onState: s => { zz.style.opacity = s === 'idle' ? '' : '0'; zz.style.pointerEvents = s === 'idle' ? '' : 'none'; hint.style.opacity = s === 'idle' && !st.open ? '' : '0'; setTry('agent', s !== 'idle'); } });

    /* ── screens ── */
    const task = (x, i) => r({ cls: 'sm' + (x.done ? ' done' : '') + (x.fresh ? ' new-in' : ''), l: `<button type="button" class="cb${x.done ? ' on' : ''}" data-act="task" data-i="${i}" aria-label="${x.done ? 'Mark not done' : 'Mark done'}: ${esc(x.t)}">${ic('ok')}</button>`, t: esc(x.t),
      r: `<span class="chip" style="--k:${PC[x.p] || BLUE}"><i></i>${esc(x.p)}</span><span class="d" style="font-size:10.5px;width:30px;text-align:right">${esc(x.e)}</span>${`<button type="button" class="b sq" data-act="focus-task" data-i="${i}" aria-label="Focus on ${esc(x.t)}">${ic('play')}</button>`}` });
    const lg = (a, i) => `<div class="logr" data-row="${i}"><span class="ft">${a[0]}</span><b class="${a[2]}">${a[1]}</b><span class="d">${a[3]}</span><span class="fg" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${a[4]}</span><span class="row" style="gap:4px">${a[5] ? btn('Open', a[2] === 'wn' ? 'w' : '', null, null, 'go', { go: a[5] }) : ''}${ibtn('x', 'dismiss', 'Dismiss alert', { i })}</span></div>`;
    const setRow = (t, d, ctl) => `<div class="set"><span class="m"><b>${t}</b>${d ? `<span>${d}</span>` : ''}</span>${ctl}</div>`;
    const tcol = (t, d, c) => `<span style="width:64px;flex:none;border-left:2px solid ${c};padding-left:9px;line-height:1.35"><b style="font-size:12.5px">${t}</b><br><span class="d" style="font-size:10.5px">${d || '&nbsp;'}</span></span>`;
    const PRS = [
      { n: 214, c: 'var(--err)', t: 'Make the settings page work from the keyboard', s: '<b class="fg">aurora-web</b> · @maya · 5 min ago · <span class="ok">+212</span> <span class="er">−48</span>', chip: chip('2 checks failing', 'e', 'x'), in: [0, 1, 2] },
      { n: 412, c: 'var(--ok)', t: 'Add themes: seven built in, plus your own', s: '<b class="fg">aurora</b> · approved by @theo · 20 min ago', chip: chip('approved', 'g', 'ok'), in: [0, 3] },
      { n: 88, c: 'var(--warn)', t: 'Bump the build image to Node 22', s: '<b class="fg">infra</b> · @dependabot · 2 hours ago', chip: chip('needs approval', 'w', 'warn'), in: [0, 1] }
    ];
    const CLIPK = { text: ix(ic('lines'), 'var(--dim)'), link: ix(ic('link'), 'var(--info)'), code: ix(ic('code'), 'var(--env)') };
    const SUMMARY = ['Three site visits, 12–14 Oct, with measurements per room.', 'Open question on the north wall; photos on pages 8–11.', 'Next visit is not dated yet.'];
    const needs = () => (st.c2 === 'ask' ? 1 : 0);

    const SCREENS = {
      home: {
        name: 'Home', wave: true, sub: () => `${day} · ${needs() ? '1 needs you' : 'all clear'}`,
        body: () => `${inp('ASK ZERA', 'or search files', { name: 'ask', ph: 'Ask Zera or search files…', hints: ['↵ RUN'] })}<div class="blk answer" data-slot="answer" hidden><div class="code"></div></div>
${lbl('NEEDS YOU', needs() ? '01' : '00')}
${needs() ? r({ cls: 'on', act: 'go', data: { go: 'agents' }, l: ix('C2', 'var(--warn)'), t: 'Claude · Fix the theme picker', s: '~/Projects/Studio · waiting for your approval', r: chip('WAITING', 'w', null, 'p') + btn('Open', 'p', null, '↵') }) : ''}
${r({ act: 'go', data: { go: 'rem' }, l: ix(ic('cal'), VIOLET), t: 'Design review', s: '11:42 – 12:12 · Zera calendar', r: chip('in 1h', 'n') })}
${lbl('QUICK ACTIONS')}
<div class="row wrap">${btn('Agents', '', 'star', null, 'go', { go: 'agents' })}${btn('Files', '', 'tray', null, 'go', { go: 'shelf' })}${btn('Clipboard', '', 'clip', null, 'deck')}${btn('Daily Shelf', '', 'note', null, 'dshelf')}${btn('Opener', '', 'search', null, 'opener')}${btn('Tasks', '', 'tasks', null, 'go', { go: 'tasks' })}${btn('Timer', '', 'clock', null, 'go', { go: 'focus' })}</div>
${lbl('THIS MAC', null, '<span style="letter-spacing:.04em">sample readings</span>')}
<div class="row" style="gap:8px">${tile('CPU', '8C', '54', '%', cols(10, 1, 'cpu-cols'), 'cpu')}${tile('MEM', '16G', '9.0', 'GB', `<div class="row" style="height:18px">${bar(56, null, 'mem-bar')}</div>`, 'mem')}${tile('GPU', '', '12', '%', spark(4, VIOLET, 'gpu-line'), 'gpu')}${tile('WI-FI', '↓', '15.5', 'Mb/s', spark(7, 'var(--ok)', 'net-line'), 'net')}${tile('BAT', '', '78', '%', `<div class="row" style="height:18px">${bar(78, 'var(--ok)')}</div>`)}</div>`,
        status: () => ['zera v2', needs() ? '1 agent waiting' : 'nothing waiting', 'next 11:42'], keys: [['↵', 'run'], ['esc', 'close']]
      },
      agents: {
        name: 'Agents', mood: () => ({ ask: 'warn', run: 'think', done: 'ok', no: 'idle' }[st.c2]), sub: () => ({ ask: '2 working · 1 needs your approval', run: '2 working', done: '1 working · 1 done', no: '1 working · 1 stopped' }[st.c2]),
        tools: () => btn(`Approvals <b class="ct" style="color:var(--bg);background:var(--warn)">${needs()}</b>`, needs() ? 'w' : '', 'warn'),
        body: () => `<div class="row" style="margin-bottom:4px">${seg([['All', 3], ['Claude', 2], ['Codex', 1]])}<span class="sp"></span>${sel('All sessions')}</div>
${lbl('CLAUDE', '02')}
${r({ cls: 'on', l: ix('C1', null, 'f'), t: 'Polish the preferences', s: '~/Projects/Studio · <span data-live="a-step">Reading Settings.swift</span>', r: `<span class="row" style="width:130px">${bar(st.p1, null, 'a-bar')}</span><span class="chip"><i class="p"></i>RUNNING <span data-live="a-time">${mmss(st.t1).replace(/^0/, '')}</span></span>${ibs('more')}` })}
<div class="blk" style="margin:5px 0 5px 37px"><div class="bh"><span class="tgk ok">${ic('ok')}Read</span><span>Settings.swift</span><span class="ft">212 lines</span></div><div class="bh" style="border-top:1px solid var(--line)"><span class="tgk ac">${ic('chev')}Edit</span><span class="fg">Palette.swift</span><span class="ok">+18</span><span class="er">−4</span><span class="sp"></span><span class="cur s"></span></div></div>
${r({ l: ix('C2', VIOLET), t: 'Fix the theme picker', s: '~/Projects/Studio · managed session', r: { ask: chip('NEEDS YOU', 'w', null, 'p'), run: chip('RUNNING', '', null, 'p'), done: chip('DONE 0:07', 'g', 'ok'), no: chip('STOPPED', 'e', 'x') }[st.c2] + ibs('more') })}
<div class="blk" style="margin:5px 0 0 37px;border-color:color-mix(in srgb,${{ ask: 'var(--warn)', run: 'var(--sig)', done: 'var(--ok)', no: 'var(--err)' }[st.c2]} 34%,transparent)"><div class="bh" style="min-height:38px"><span class="tgk ${{ ask: 'wn', run: 'ac', done: 'ok', no: 'er' }[st.c2]}">${ic('term')}Bash</span><span class="fg">swift test --filter ThemeStoreTests</span><span class="sp"></span>${
  st.c2 === 'ask' ? btn('Reject', 'e', 'x', 'esc', 'reject') + btn('Approve', 'g', 'ok', '↵', 'approve')
    : st.c2 === 'run' ? '<span class="d">approved · running</span><span class="cur s"></span>' : st.c2 === 'done' ? '<span class="ok">12 tests passed</span>' : `<span class="er">rejected · nothing ran</span>${btn('Undo', 'q', 'reset', null, 'reset-agent')}`}</div></div>
${lbl('CODEX', '01')}
${r({ l: ix('X1', ROSE), t: 'Review the new layout', s: '~/Projects/Studio · observed desktop chat · read-only', r: chip('WATCHING', 'n') + `<span class="b sq">${ic('eye')}</span>` + ibs('more') })}
<div class="row" style="margin-top:14px;font-size:10px;letter-spacing:.12em;color:var(--faint);gap:10px"><span>PLAN</span><span class="row" style="width:160px">${bar(38)}</span><b class="d" style="font-weight:500">38%</b><span>5H WINDOW · A PLAN READING, NOT TASK PROGRESS</span></div>`,
        status: () => [st.c2 === 'done' ? '1 working' : '2 working', needs() ? '1 needs you' : 'nothing waiting'], keys: [['↵', 'approve'], ['esc', 'reject']]
      },
      prs: {
        name: 'Pull requests', sub: () => '@you · checked 1 min ago', tools: () => ibs('refresh', 'more'),
        body: () => { const l = PRS.filter(p => p.in.includes(st.prs)); return `<div class="row">${seg([['Open', 3, 'pr'], ['Review', 2, 'note'], ['CI', 1, 'x'], ['Approvals', 1, 'ok']], st.prs, 'w', 'prs')}</div>
<div class="row" style="margin:10px 0">${fld('Search PRs, repositories, or authors…')}${sel('Author')}${sel('Repo')}${sel('Sort')}</div>
${l.map((p, i) => r({ cls: i === Math.min(st.prSel, l.length - 1) ? 'on' : '', act: 'pr', data: { i }, l: ix(p.n, p.c, 'lg'), t: p.t, s: p.s, r: p.chip + btn('Review', i === st.prSel ? 'p' : '', null, null, 'review', { n: p.n }) + ibs('more') })).join('')}`; },
        status: () => ['3 open', '1 failing', 'github ok'], keys: [['↑↓', 'move'], ['↵', 'open']]
      },
      alerts: {
        name: 'Alerts', mood: () => (st.alerts.length ? 'warn' : 'ok'), sub: () => st.alerts.length ? `${st.alerts.filter(a => a[5]).length} need you · ${st.alerts.length} today` : 'all quiet',
        tools: () => st.alerts.length ? btn('Clear all', 'q', 'x', null, 'clear-alerts') : btn('Bring them back', 'q', 'reset', null, 'reset-alerts'),
        body: () => `<div class="row" style="margin-bottom:10px">${seg([['All', st.alerts.length], ['Agents'], ['PRs'], ['Reminders'], ['System']])}</div>
<div class="blk">${st.alerts.length ? st.alerts.map(lg).join('') : `<div class="code"><span class="ft">${S.clock()}:00</span>  <span class="ok">OK  </span>  all quiet. nothing needs you.</div>`}</div>`,
        status: () => [`${st.alerts.length} today`], keys: [['↵', 'open'], ['⌫', 'dismiss']]
      },
      clip: {
        name: 'Clipboard', sub: () => `${st.clips.length} items · kept for 7 days`, tools: () => btn('Open the deck', 'p', 'clip', null, 'deck') + ibs('more'),
        body: () => { const l = st.clipSeg === 0 || st.clipSeg === 1 ? st.clips : st.clipSeg === 4 ? st.clips.filter(c => c.pin) : []; return `<div class="row" style="margin-bottom:4px">${seg([['All', st.clips.length], ['Text'], ['Images'], ['Files'], ['Pinned']], st.clipSeg, '', 'clip')}${fld('Search copies')}</div>
${lbl('TODAY', String(l.length).padStart(2, '0'))}
${l.length ? l.map(c => { const i = st.clips.indexOf(c); return r({ cls: i === st.clipSel ? 'on' : '', act: 'clip', data: { i }, l: c.k === 'color' ? `<span class="ix" style="background:${c.t};border-color:${c.t}"></span>` : CLIPK[c.k], t: esc(c.t), s: c.s, r: ibtn('pin', 'clip-pin', c.pin ? 'Unpin' : 'Pin', { i }, c.pin ? 'lit' : '') + kbd('⌘' + (i + 1), i === st.clipSel) }); }).join('') : '<div class="new">Nothing of this kind yet.</div>'}`; },
        status: () => ['stays on this mac'], keys: [['↵', 'copy'], ['⌘1–9', 'quick copy']]
      },
      shelf: {
        name: 'Shelf', sub: () => '3 files · tap to copy, drag to use', tools: () => btn('Clear all', 'q', 'trash'),
        body: () => `<div class="row">${seg([['Shelf', 3, 'tray'], ['Fresh · 24 h', null, 'clock']], 0, 'w')}</div>
<div class="new" style="margin:10px 0">${ic('down')}<b class="fg">Drop files here</b><span>They wait on the Shelf. Zera only reads one when you ask.</span></div>
<div class="row">${btn('Summarize', 'p', 'star', null, 'answer', { k: 'sum' })}${btn('Explain', '', 'search', null, 'answer', { k: 'exp' })}${btn('Extract text', '', 'file', null, 'answer', { k: 'ext' })}</div><div style="height:10px"></div>
${[['Zera coast (2).png', 'image · 3.3 MB · 1 h ago', '<span class="thumb"></span>'], ['Zera coast.png', 'image · 28 KB · 2 h ago', '<span class="thumb" style="background:linear-gradient(135deg,#9db6c4,#4c6577)"></span>'], ['field-notes.pdf', 'pdf · 104.9 MB · from your phone · 2 h ago', ix(ic('file'), 'var(--dim)')]].map(([t, s, l], i) => r({ cls: i === st.fileSel ? 'on' : '', act: 'file', data: { i }, l, t, s, r: ibs('copy', 'chev', 'more') })).join('')}
<div data-slot="answer"${st.answer ? '' : ' hidden'}>${lbl('ZERA · field-notes.pdf')}<div class="blk"><div class="code" style="color:var(--fg)">${st.answer ? st.answer.map(l => `<span class="ac">›</span> ${l}`).join('\n') : ''}</div></div></div>`,
        status: () => ['3 files', 'references only', 'originals stay where they are']
      },
      tasks: {
        name: 'Tasks', sub: () => `${day} · ${st.tasks.filter(t => t.done).length} of ${st.tasks.length} done`,
        body: () => { const l = st.tasks.map((x, i) => [x, i]).filter(([x]) => st.proj === 0 || x.p === PROJ[st.proj]); return `<div class="row" style="margin-bottom:10px"><span class="sg" role="group">${PROJ.map((p, i) => `<button type="button" class="${i === st.proj ? 'on' : ''}" data-act="seg" data-seg="proj" data-i="${i}">${i ? `<i style="width:6px;height:6px;border-radius:50%;background:${PC[p]}"></i>` : ''}${p}</button>`).join('')}</span><span class="sp"></span>${mini('⌥⌘T from anywhere')}</div>
${inp(`ADD TO ${(st.proj ? PROJ[st.proj] : 'General').toUpperCase()}`, '#name picks a project · 30m sets the estimate', { name: 'task', ph: 'Write the release notes #Aurora 30m', hints: ['↵ ADD'] })}
${lbl('TO DO', String(l.filter(([x]) => !x.done).length).padStart(2, '0'))}
${l.map(([x, i]) => task(x, i)).join('') || '<div class="new">No tasks in this project.</div>'}`; },
        status: () => [`${st.tasks.filter(t => t.done).length} of ${st.tasks.length} done`, 'timesheets export to excel, csv or text'], keys: [['↵', 'add']]
      },
      rem: {
        name: 'Reminders', sub: () => 'your day, all in one place', tools: () => btn('Add event', 'p', 'plus'),
        body: () => `<div class="row">${seg([['Today', st.rem.filter(x => !x).length, 'bolt'], ['Upcoming', 0, 'cal'], ['Completed', st.rem.filter(Boolean).length, 'ok']], 0, 'w')}</div>
<div class="row wrap" style="margin:10px 0">${chip('All', '')}<span class="chip" style="--k:${BLUE}"><i></i>Google</span><span class="chip" style="--k:#7aa2f7"><i></i>Outlook</span><span class="chip" style="--k:${ROSE}"><i></i>Apple</span><span class="chip y"><i></i>Reminders</span></div>
${r({ cls: (st.rem[0] ? 'done' : 'on'), l: tcol('11:42', '30m', VIOLET) + ix(ic('star'), VIOLET), t: 'Design review', s: '11:42 – 12:12 · Zera', r: `<span class="chip" style="--k:${VIOLET}">${ic('clock')}in 1h</span>${`<button type="button" class="b sq g" data-act="rem" data-i="0" aria-label="Mark Design review done">${ic('ok')}</button>`}` })}
${r({ cls: (st.rem[1] ? 'done' : ''), l: tcol('12:42', '', 'var(--env)') + ix(ic('bell'), 'var(--env)'), t: 'Send the release notes', s: 'reminder', r: `<span class="chip y">${ic('clock')}in 2h</span><button type="button" class="b sq g" data-act="rem" data-i="1" aria-label="Mark Send the release notes done">${ic('ok')}</button>` })}
<div class="row" style="margin-top:14px;font-size:10px;letter-spacing:.14em;color:var(--faint);gap:10px"><span>WATER</span><span class="gl">${Array.from({ length: 8 }, (_, i) => `<button type="button" class="${i < st.water ? 'f' : ''}" data-act="water" data-i="${i}" aria-label="${i + 1} glasses"></button>`).join('')}</span><b class="d" style="font-weight:500">${st.water} OF 8</b><span>TAP A GLASS</span></div>`,
        status: () => [`${st.rem.filter(x => !x).length} today`, 'next 11:42'], keys: [['space', 'done']]
      },
      tele: {
        name: 'Teleprompter', sub: () => `a little place for your day · ${TELE.join(' ').split(' ').length} words`, tools: () => seg(['Edit', 'Roll'], st.tele.roll ? 1 : 0, '', 'tele'),
        body: () => st.tele.roll ? `<div class="blk" style="padding:14px 16px 12px;text-align:center;line-height:1.7"><div data-roll style="transform:scaleX(${st.tele.mirror ? -1 : 1});transition:transform .4s var(--ease)"><div class="telel" data-live="t-prev">${TELE[st.tele.i - 1] || ''}</div><div class="teleband" data-live="t-now">${TELE[st.tele.i]}</div><div class="telel" data-live="t-next">${TELE[st.tele.i + 1] || ''}</div></div>
<div class="row" style="margin-top:12px;justify-content:center">${`<button type="button" class="b sq f" data-act="tele-play" aria-label="${st.tele.play ? 'Pause' : 'Play'}">${ic(st.tele.play ? 'pause' : 'play')}</button>`}${btn(st.tele.speed.toFixed(1) + '×', '', null, null, 'tele-speed')}${btn('Mirror', st.tele.mirror ? 'p' : '', null, null, 'tele-mirror')}<span class="row" style="width:180px">${bar((st.tele.i + 1) / TELE.length * 100, null, 't-bar')}</span>${mini(`<span data-live="t-left">${TELE.length - 1 - st.tele.i}</span> lines left`)}</div></div>`
          : `<section class="pn q" style="margin:0"><div class="code" style="color:var(--fg);padding:12px 14px;line-height:1.9">${TELE.map((l, i) => `<span class="ft">${i + 1}</span>  ${l}`).join('\n')}<span class="cur s"></span></div></section>`,
        status: () => [`${TELE.length} lines`, 'reads beside the camera'], keys: [['↑↓', 'speed']]
      },
      focus: {
        name: 'Focus', mood: () => (st.focus.run ? 'think' : 'idle'), sub: () => `${st.tasks.filter(t => !t.done).length} open · one at a time`,
        body: () => { const f = st.focus; return `<div style="display:grid;grid-template-columns:290px 1fr;gap:18px;align-items:start">
<div>${ring(196, mmss(f.left), esc(f.task.length > 18 ? f.task.slice(0, 17) + '…' : f.task), 1 - f.left / f.total)}
<div class="row" style="justify-content:center;margin-top:8px">${btn(f.run ? 'Pause' : 'Resume', '', f.run ? 'pause' : 'play', 'space', 'f-toggle')}${btn('Reset', '', 'reset', null, 'f-reset')}${btn('Done', 'g', 'ok', '↵', 'f-done')}</div>
<div class="row" style="justify-content:center;margin-top:10px">${seg(['25', '45', '60'], [25, 45, 60].indexOf(f.total / 60), '', 'preset')}</div></div>
<div>${lbl('UP NEXT', String(st.tasks.filter(t => !t.done).length).padStart(2, '0'))}
${st.tasks.map((x, i) => x.done ? '' : r({ cls: 'sm' + (x.t === f.task ? ' on' : ''), act: 'focus-task', data: { i }, l: x.t === f.task ? ix(ic(f.run ? 'pause' : 'play'), null, 'f') : '<span class="cb" style="margin:0 5px"></span>', t: esc(x.t), s: esc(x.p), r: mini(x.e) })).join('') || '<div class="new">Everything is done.</div>'}</div></div>`; },
        status: () => [st.focus.run ? 'focusing' : 'paused'], keys: [['space', 'pause'], ['↵', 'done']]
      },
      settings: {
        name: 'Settings', sub: () => 'appearance · changes apply to this page',
        body: () => `<div style="display:grid;grid-template-columns:190px 1fr;gap:18px;align-items:start">
<div>${lbl('PANES', '09')}${[['gear', 'General'], ['swatch', 'Appearance', 1], ['tray', 'Notch'], ['clip', 'Clipboard'], ['note', 'Shelf'], ['plug', 'Integrations'], ['key', 'Shortcuts']].map(([i, t, on], n) => r({ cls: 'sm' + (on ? ' on' : ''), l: ix(ic(i), on ? null : 'var(--dim)', on ? 'f' : ''), t, r: `<span class="ft" style="font-size:10px">0${n + 1}</span>` })).join('')}</div>
<div>${lbl('SIGNAL')}
${setRow('Signal colour', 'The trace, brackets, cursor and selection', `<span class="row" style="gap:4px">${SIGS.map(([t, c]) => `<button type="button" class="swb${st.set.sig === c ? ' on' : ''}" style="--c:${c}" data-act="sig" data-c="${c}" aria-pressed="${st.set.sig === c}"><i></i>${t}</button>`).join('')}</span>`)}
${setRow('Trace from Zera to the open screen', '', tog(st.set.trace, 'set', { k: 'trace' }, 'Trace'))}
${setRow('Corner brackets', '', tog(st.set.br, 'set', { k: 'br' }, 'Corner brackets'))}
${lbl('GLASS')}
${setRow('Background', 'Solid by default. Translucent tints and blurs the desktop behind', seg(['Solid', 'Translucent'], st.set.glass, '', 'glass'))}
${setRow('Glow', '', seg(['Low', 'Mid', 'High'], st.set.glow, '', 'glow'))}
${lbl('COLOUR THEME', null, '<span style="letter-spacing:.04em">nine built in</span>')}
<div class="row wrap" style="gap:4px">${[['Signal', '#7be1c2', 1], ['Obsidian', '#9b8cff'], ['Zera', '#9d8cff'], ['Tokyo Night', '#7aa2f7'], ['Dracula', '#bd93f9'], ['Catppuccin', '#cba6f7'], ['Nord', '#88c0d0'], ['Rosé Pine', '#ebbcba'], ['Gruvbox', '#fabd2f']].map(([t, c, on]) => `<span class="swb${on ? ' on' : ''}" style="--c:${c}"><i></i>${t}</span>`).join('')}</div></div></div>`,
        status: () => ['settings', 'changes apply live']
      }
    };

    /* ── drawing ── */
    let mood = '';
    function setMood(m, wave) { const k = m + (wave ? 'w' : ''); if (k === mood) return; mood = k; zzIn.innerHTML = zera({ m, s: 60, wave }); }
    function badges() { $$('.nt', desk).forEach(b => { const k = b.dataset.go; $('em', b).textContent = k === 'agents' && needs() ? '1' : k === 'alerts' && st.alerts.length ? String(st.alerts.filter(a => a[5]).length || '') : ''; }); }
    function paint(sweep) {
      timers.forEach(clearTimeout); timers.clear();
      const sc = SCREENS[st.key];
      pt.innerHTML = `<div><h3>${sc.name}</h3><p>${sc.sub()}</p></div><div class="tools">${sc.tools ? sc.tools() : ''}</div>`;
      pb.innerHTML = sc.body();
      sb.innerHTML = `<span class="live"><i></i>LIVE</span><span>${sc.name.toUpperCase()}</span>${(sc.status ? sc.status() : []).map(s => `<span>${s}</span>`).join('')}<span class="sp"></span>${(sc.keys || []).map(([k, t]) => `<span class="k">${kbd(k)}${t}</span>`).join('')}${st.auto ? '<span class="ac">AUTO TOUR</span>' : ''}<b data-live="clock">${S.clock()}</b>`;
      $$('.nt', desk).forEach(b => b.classList.toggle('on', b.dataset.go === st.key));
      gear.classList.toggle('on', st.key === 'settings');
      badges();
      setMood(st.open ? (sc.mood ? sc.mood() : 'idle') : 'idle', st.open ? !!sc.wave : false);
      if (sweep && !still()) { pn.classList.remove('swap'); void pn.offsetWidth; pn.classList.add('swap'); scan.classList.remove('go'); void scan.offsetWidth; scan.classList.add('go'); }
      layout();
      $$('.r.new-in', pb).forEach(e => e.addEventListener('animationend', () => e.classList.remove('new-in'), { once: true }));
      st.tasks.forEach(t => { t.fresh = false; });
    }
    function layout() {
      islw.style.width = st.open ? '880px' : '';
      islw.style.height = st.open ? isli.offsetHeight + 'px' : '';
      const on = $('.nt.on', desk), tr = $('.trace', desk);
      if (!on) { ind.style.opacity = '0'; tr.style.opacity = '0'; return; }
      const x = on.parentElement.offsetLeft + on.offsetLeft, W = 880, tx = x + 15, ty = 53, left = tx < W / 2, s = left ? -1 : 1, q = 6;
      ind.style.opacity = '1'; tr.style.opacity = ''; ind.style.transform = `translateX(${x}px)`;
      const zx = W / 2 + s * 30, gx = left ? 7 : W - 7, px = left ? 14 : W - 14, y2 = 81, py = pn.offsetTop + 13.5;
      const d = `M${zx},${ty}H${tx}V${y2 - q}Q${tx},${y2} ${tx + s * q},${y2}H${gx - s * q}Q${gx},${y2} ${gx},${y2 + q}V${py - q}Q${gx},${py} ${gx - s * q},${py}H${px}`;
      $$('.trace path', desk).forEach(p => p.setAttribute('d', d));
      $('.pn > .port', desk).className = 'port ' + (left ? 'lf' : 'rt');
    }
    function go(key, quiet) {
      if (!SCREENS[key]) return;
      const same = key === st.key; st.key = key;
      if (key === 'focus' || key === 'tele') tickNow = 0;
      paint(!same && !quiet);
    }
    function setOpen(v) {
      if (v === st.open) return;
      st.open = v;
      if (v) { toggleShelf(false, true); wingsApi.stop(); }
      islw.classList.toggle('open', v); zz.classList.toggle('small', !v); zz.setAttribute('aria-expanded', v);
      hint.style.opacity = v ? '0' : '';
      setTry('toggle', v);
      paint(v);
      if (v && !still()) later(layout, 60);
    }
    function echo(html, ms = 1700) { echoEl.innerHTML = html; echoEl.classList.add('on'); clearTimeout(echo.t); echo.t = setTimeout(() => echoEl.classList.remove('on'), ms); }
    function toggleShelf(v, keep) {
      v = v ?? !shelf.isOpen();
      if (v === shelf.isOpen()) return;
      if (v) { if (!keep) setOpen(false); shelf.open(); later(() => shelf.input.focus({ preventScroll: true }), 420); } else shelf.close();
      cue.classList.toggle('hide', v); setTry('dshelf', v);
    }
    let pointer = { x: 760, y: 150 };
    function toggleDeck(v) {
      const on = deckHost.classList.contains('on'); v = v ?? !on;
      if (v === on) return;
      if (v) { deck.reset(); deckHost.style.left = clamp(pointer.x + 14, 16, 1164 - 420) + 'px'; deckHost.style.top = clamp(pointer.y - 60, 40, 712 - 448) + 'px'; }
      deckHost.classList.toggle('on', v); setTry('deck', v);
      if (v) later(() => deck.focus(), 60); else desk.focus({ preventScroll: true });
    }
    function toggleOpener(v) {
      const on = opHost.classList.contains('on'); v = v ?? !on;
      if (v === on) return;
      opener.reset();      // also on the way out: a picture only tried on is taken off again
      if (v) toggleDeck(false);
      opHost.classList.toggle('on', v); dimr.classList.toggle('on', v); dimr.classList.toggle('bare', v); setTry('opener', v);
      if (v) later(() => opener.focus(), 60); else desk.focus({ preventScroll: true });
    }
    function agent() {
      if (wingsApi.state() !== 'idle') { wingsApi.stop(); return; }
      setOpen(false); wingsApi.touch(); wingsApi.start();
    }
    function setTry(k, on) { $$(`[data-stage="${k}"]`).forEach(b => b.setAttribute('aria-pressed', on)); }
    function stream(el, lines, done) {
      const text = lines.join('\n'); let i = 0;
      const code = $('.code', el); el.hidden = false; layout();
      const step = () => {
        i = still() ? text.length : Math.min(text.length, i + 2);
        code.innerHTML = text.slice(0, i).split('\n').map(l => `<span class="ac">›</span> ${esc(l)}`).join('\n') + (i < text.length ? '<span class="cur s"></span>' : '');
        if (i % 40 < 2) layout();
        if (i < text.length) later(step, 18); else { layout(); if (done) done(); }
      };
      step();
    }

    /* ── live readings ── */
    let tickNow = 0;
    const live = (k, fn) => { const e = $(`[data-live="${k}"]`, desk); if (e) fn(e); };
    const walk = { cpu: 54, mem: 9.0, gpu: 12, net: 15.5, gl: S.series(4, 28), nl: S.series(7, 28) };
    function tick() {
      tickNow++;
      $$('[data-live="clock"]', desk).forEach(e => { e.textContent = S.clock(); });
      if (!st.open || !st.seen || document.hidden) return;
      if (st.key === 'home') {
        const j = (v, d, lo, hi) => clamp(v + (Math.random() - .5) * d, lo, hi);
        walk.cpu = j(walk.cpu, 16, 18, 92); walk.mem = j(walk.mem, .3, 7.8, 11.4); walk.gpu = j(walk.gpu, 8, 4, 48); walk.net = j(walk.net, 6, 2, 38);
        live('cpu', e => { e.textContent = Math.round(walk.cpu); }); live('mem', e => { e.textContent = walk.mem.toFixed(1); });
        live('gpu', e => { e.textContent = Math.round(walk.gpu); }); live('net', e => { e.textContent = walk.net.toFixed(1); });
        live('mem-bar', e => { e.style.width = walk.mem / 16 * 100 + '%'; });
        live('cpu-cols', e => { [...e.children].forEach(c => { c.style.height = 20 + Math.random() * 80 + '%'; }); });
        walk.gl.push(walk.gpu / 20); walk.gl.shift(); walk.nl.push(walk.net / 16); walk.nl.shift();
        live('gpu-line', e => e.setAttribute('points', S.sparkPoints(walk.gl))); live('net-line', e => e.setAttribute('points', S.sparkPoints(walk.nl)));
      }
      st.t1++; st.p1 = st.p1 >= 96 ? 22 : st.p1 + 1.2;
      if (st.key === 'agents') {
        live('a-bar', e => { e.style.width = st.p1 + '%'; }); live('a-time', e => { e.textContent = mmss(st.t1).replace(/^0/, ''); });
        live('a-step', e => { e.textContent = ['Reading Settings.swift', 'Editing Palette.swift', 'Checking the theme list', 'Running ThemeStoreTests'][Math.floor(st.p1 / 25) % 4]; });
      }
      const f = st.focus;
      if (f.run && f.left > 0) f.left--;
      if (st.key === 'focus') { live('ring-time', e => { e.textContent = mmss(f.left); }); live('ring', e => e.setAttribute('stroke-dasharray', `${(S.RING_C * (1 - f.left / f.total)).toFixed(1)} ${S.RING_C.toFixed(1)}`)); }
      const t = st.tele;
      if (st.key === 'tele' && t.roll && t.play && tickNow % Math.max(1, Math.round(2 / t.speed)) === 0) {
        t.i = (t.i + 1) % TELE.length;
        live('t-prev', e => { e.textContent = TELE[t.i - 1] || ''; }); live('t-now', e => { e.textContent = TELE[t.i]; }); live('t-next', e => { e.textContent = TELE[t.i + 1] || ''; });
        live('t-bar', e => { e.style.width = (t.i + 1) / TELE.length * 100 + '%'; }); live('t-left', e => { e.textContent = TELE.length - 1 - t.i; });
      }
      if (st.auto && st.open && tickNow % 5 === 0) { const i = NAV.findIndex(n => n[0] === st.key); go(NAV[(i + 1) % NAV.length][0]); }
    }
    setInterval(tick, 1000);

    /* ── actions ── */
    const A = {
      toggle: () => setOpen(!st.open),
      go: el => { setOpen(true); go(el.dataset.go); },
      dshelf: () => toggleShelf(), deck: () => toggleDeck(), opener: () => toggleOpener(), 'close-op': () => toggleOpener(false), agent,
      approve: () => { st.c2 = 'run'; paint(); echo(`${kbd('↵', 1)}<b>APPROVED</b><span class="d">swift test --filter ThemeStoreTests</span>`); later(() => { st.c2 = 'done'; if (st.key === 'agents') paint(); else badges(); }, 3400); },
      reject: () => { st.c2 = 'no'; paint(); echo(`${kbd('esc', 1)}<b>REJECTED</b><span class="d">nothing ran</span>`); },
      'reset-agent': () => { st.c2 = 'ask'; paint(); },
      seg: el => {
        const i = +el.dataset.i, k = el.dataset.seg;
        if (k === 'prs') { st.prs = i; st.prSel = 0; } else if (k === 'clip') st.clipSeg = i; else if (k === 'proj') st.proj = i;
        else if (k === 'tele') st.tele.roll = i === 1; else if (k === 'preset') { st.focus.total = [25, 45, 60][i] * 60; st.focus.left = st.focus.total; }
        else if (k === 'glass') { st.set.glass = i; document.documentElement.dataset.glass = i ? 'glass' : 'solid'; }
        else if (k === 'glow') { st.set.glow = i; desk.style.setProperty('--glow', [.4, 1, 1.9][i]); }
        paint();
      },
      pr: el => { st.prSel = +el.dataset.i; paint(); },
      review: el => echo(`${kbd('↵', 1)}<b>#${esc(el.dataset.n)}</b><span class="d">opens the review in your browser</span>`),
      dismiss: el => { const row = el.closest('.logr'); row.classList.add('out'); later(() => { st.alerts.splice(+el.dataset.i, 1); paint(); }, still() ? 0 : 280); },
      'clear-alerts': () => { st.alerts.keep = st.alerts.slice(); st.alerts.length = 0; paint(); },
      'reset-alerts': () => { st.alerts.push(...(st.alerts.keep || [])); paint(); },
      clip: el => { st.clipSel = +el.dataset.i; paint(); const c = st.clips[st.clipSel]; echo(`${kbd('⌘C', 1)}<b>COPIED</b><span class="d">${esc(c.t.slice(0, 32))}</span><span class="ft">⌘V to paste</span>`); },
      'clip-pin': el => { const c = st.clips[+el.dataset.i]; c.pin = !c.pin; paint(); },
      file: el => { st.fileSel = +el.dataset.i; paint(); },
      answer: el => {
        const lines = { sum: SUMMARY, exp: ['A field notebook as a PDF: dated entries, room sketches and photos.', 'Most useful part is the measurement table on page 3.'], ext: ['12 Oct · kitchen 3.4 × 4.1 m · ceiling 2.6 m', '13 Oct · north wall, damp patch near the window', '14 Oct · stairs, 14 risers at 18 cm'] }[el.dataset.k];
        st.answer = null; st.fileSel = 2; paint(); setMood('think');
        stream($('[data-slot="answer"]', pb), lines, () => { st.answer = lines.map(esc); setMood('ok'); later(() => setMood('idle'), 1800); });
      },
      task: el => { const x = st.tasks[+el.dataset.i]; x.done = !x.done; if (x.done) { setMood('ok'); later(() => setMood('idle'), 1400); } paint(); },
      'focus-task': el => { const x = st.tasks[+el.dataset.i]; st.focus.task = x.t; st.focus.left = st.focus.total; st.focus.run = true; go('focus'); paint(); },
      rem: el => { const i = +el.dataset.i; st.rem[i] = !st.rem[i]; paint(); },
      water: el => { const i = +el.dataset.i; st.water = st.water === i + 1 ? i : i + 1; paint(); if (st.water === 8) echo(`${chip('WATER', 'b')}<b>8 of 8</b><span class="d">that is the day done</span>`); },
      'tele-play': () => { st.tele.play = !st.tele.play; paint(); }, 'tele-mirror': () => { st.tele.mirror = !st.tele.mirror; paint(); },
      'tele-speed': () => { st.tele.speed = { 1: 1.5, 1.5: 2, 2: .5, .5: 1 }[st.tele.speed]; paint(); },
      'f-toggle': () => { st.focus.run = !st.focus.run; paint(); }, 'f-reset': () => { st.focus.left = st.focus.total; paint(); },
      'f-done': () => { const x = st.tasks.find(t => t.t === st.focus.task); if (x) x.done = true; const n = st.tasks.find(t => !t.done); st.focus.task = n ? n.t : 'Nothing left'; st.focus.left = st.focus.total; st.focus.run = !!n; setMood('ok'); paint(); later(() => paint(), 1600); },
      sig: el => { st.set.sig = el.dataset.c; if (window.ZeraPage) window.ZeraPage.setSig(el.dataset.c); else document.documentElement.style.setProperty('--sig', el.dataset.c); paint(); },
      set: el => { const k = el.dataset.k; st.set[k] = !st.set[k]; desk.classList.toggle('notrace', !st.set.trace); desk.classList.toggle('nobr', !st.set.br); paint(); }
    };
    const SUBMIT = {
      ask: v => {
        const s = v.toLowerCase();
        const lines = /pr|pull|review|check/.test(s) ? ['3 pull requests are open.', '#214 in aurora-web has 2 failing checks. Pull requests has the list.']
          : /task|todo|focus|today/.test(s) ? [`${st.tasks.filter(t => !t.done).length} tasks are open today.`, `Next up: ${st.tasks.find(t => !t.done)?.t || 'nothing'}.`]
            : /clip|copy|copied/.test(s) ? ['Your last copy was “A little less switching.”', 'The Clipboard deck has the rest.']
              : [needs() ? 'One Claude session is waiting for your approval.' : 'Nothing is waiting on you.', 'This is a canned demo answer. In the app, Zera asks the provider you chose.'];
        setMood('think'); stream($('[data-slot="answer"]', pb), lines, () => { setMood('ok'); later(() => setMood('idle', true), 1600); });
      },
      task: (v, input) => {
        let t = v, p = st.proj ? PROJ[st.proj] : 'General', e = '';
        t = t.replace(/(^|\s)#([\w-]{1,16})/, (_, a, n) => { p = Object.keys(PC).find(k => k.toLowerCase() === n.toLowerCase()) || n[0].toUpperCase() + n.slice(1); return a; });
        t = t.replace(/(^|\s)(\d{1,3})\s?(m|min|h)\b/i, (_, a, n, u) => { e = n + (u[0].toLowerCase() === 'h' ? 'h' : 'm'); return a; }).replace(/\s+/g, ' ').trim();
        if (!t) return;
        st.tasks.unshift({ t: t.slice(0, 80), p, e, fresh: true }); st.proj = 0; paint();
        const again = $('[data-input="task"]', pb); if (again && input) again.focus({ preventScroll: true });
      }
    };
    function chipsFor(input) {
      const box = $(`[data-chips="${input.dataset.input}"]`, pb);
      if (!box || input.dataset.input !== 'task') return;
      const p = input.value.match(/(?:^|\s)#([\w-]{1,16})/), e = input.value.match(/(?:^|\s)(\d{1,3})\s?(m|min|h)\b/i);
      box.innerHTML = (p ? `<span class="chip" style="--k:${PC[Object.keys(PC).find(k => k.toLowerCase() === p[1].toLowerCase())] || BLUE}">#${esc(p[1])}</span>` : '') + (e ? `<span class="chip y">${esc(e[1] + e[2][0].toLowerCase())}</span>` : '');
    }

    function stopAuto() { if (!st.auto) return; st.auto = false; setTry('tour', false); $$('.sb .ac', desk).forEach(e => e.remove()); }
    desk.addEventListener('pointerdown', stopAuto);
    desk.addEventListener('click', e => {
      const el = e.target.closest('[data-act]');
      if (el && desk.contains(el) && A[el.dataset.act] && !el.closest('.dsh') && !el.closest('[data-wings]')) { A[el.dataset.act](el); return; }
      if (deckHost.classList.contains('on') && !e.target.closest('[data-deck]') && !el) toggleDeck(false);
    });
    desk.addEventListener('input', e => { if (e.target.dataset.input) chipsFor(e.target); });
    desk.addEventListener('keydown', e => {
      stopAuto();
      const inField = e.target.matches('input');
      if (inField && e.target.dataset.input) {
        if (e.key === 'Enter' && e.target.value.trim()) { SUBMIT[e.target.dataset.input](e.target.value.trim(), e.target); if (e.target.isConnected) { e.target.value = ''; chipsFor(e.target); } e.preventDefault(); }
        else if (e.key === 'Escape') e.target.blur();
        return;
      }
      if (inField) return;
      if ((e.key === 'Enter' || e.key === ' ') && e.target.matches('[role="button"]')) { e.target.click(); e.preventDefault(); return; }
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const i = NAV.findIndex(n => n[0] === st.key);
      if (e.key === 'Escape') { if (opHost.classList.contains('on')) toggleOpener(false); else if (deckHost.classList.contains('on')) toggleDeck(false); else if (shelf.isOpen()) toggleShelf(false); else setOpen(false); }
      else if (e.key === 'ArrowRight' && st.open) { go(NAV[(i + 1 + NAV.length) % NAV.length][0]); e.preventDefault(); }
      else if (e.key === 'ArrowLeft' && st.open) { go(NAV[(i - 1 + NAV.length) % NAV.length][0]); e.preventDefault(); }
      else if (/^[0-9]$/.test(e.key) && !e.target.closest('button.cb')) { setOpen(true); go(NAV[(+e.key + 9) % 10][0]); }
      else if (e.key === 'n') setOpen(!st.open); else if (e.key === 'd') toggleShelf(); else if (e.key === 'v') toggleDeck(); else if (e.key === 'o') { toggleOpener(); e.preventDefault(); } else if (e.key === 'a') agent();
    });
    /* Zera looks at the pointer; the Clipboard deck opens beside it, as in the app. */
    let raf = 0;
    addEventListener('pointermove', e => {
      if (raf) return;
      raf = requestAnimationFrame(() => {
        raf = 0;
        const R = desk.getBoundingClientRect(), k = R.width / 1164;
        if (e.clientX >= R.left && e.clientX <= R.right && e.clientY >= R.top && e.clientY <= R.bottom) pointer = { x: (e.clientX - R.left) / k, y: (e.clientY - R.top) / k };
        const z = zz.getBoundingClientRect(), dx = e.clientX - (z.left + z.width / 2), dy = e.clientY - (z.top + z.height / 2), m = Math.hypot(dx, dy) || 1;
        zz.style.setProperty('--ex', (dx / m * Math.min(2.4, m / 60)).toFixed(2) + 'px'); zz.style.setProperty('--ey', (dy / m * Math.min(2, m / 60)).toFixed(2) + 'px');
      });
    }, { passive: true });

    $$('[data-stage]').forEach(b => b.addEventListener('click', () => {
      const k = b.dataset.stage;
      if (k === 'tour') { st.auto = !st.auto; b.setAttribute('aria-pressed', st.auto); if (st.auto) setOpen(true); paint(); return; }
      stopAuto(); A[k]();
    }));
    setTry('tour', st.auto);
    whileSeen(desk, () => { st.seen = true; if (!st.booted) { st.booted = true; later(() => setOpen(true), still() ? 0 : 520); } }, () => { st.seen = false; }, .12);
    paint();
    return { go: k => { stopAuto(); setOpen(true); go(k); }, open: () => setOpen(true), close: () => setOpen(false), shelf: toggleShelf, deck: toggleDeck, opener: toggleOpener, agent, layout };
  }

  /* ═════ mount ═════ */
  function boot() {
    document.body.insertAdjacentHTML('afterbegin', S.ZDEFS);
    const fits = [];
    const deskEl = $('#desk');
    if (deskEl) {
      const stage = Stage(deskEl);
      window.ZeraStage = stage;
      fits.push(S.autofit(deskEl.parentElement, 1, stage.layout));
      $$('[data-open-screen]').forEach(b => b.addEventListener('click', () => { stage.go(b.dataset.openScreen); deskEl.scrollIntoView({ behavior: still() ? 'auto' : 'smooth', block: 'center' }); deskEl.focus({ preventScroll: true }); }));
    }

    /* Agents: wings either side of a notch */
    const vw = $('[data-vig="wings"]');
    if (vw) {
      vw.innerHTML = `<div class="wstrip sgn"><div class="mb"><b>Zera</b><span>File</span><span>Edit</span><span class="sp"></span></div><div class="notch"></div><div data-w></div></div>`;
      const idle = `<div class="zz small" style="pointer-events:none"><span>${zera({ s: 60 })}</span></div>`;
      const api = Wings($('[data-w]', vw), { idle, loop: true });
      S.autofit(vw, 1);
      whileSeen(vw, () => { api.live = true; api.start(); }, () => { api.live = false; });
    }

    /* Daily Shelf */
    const vs = $('[data-vig="shelf"]');
    if (vs) {
      vs.innerHTML = '<div class="vshelf"><div data-s></div></div>';
      const sh = Shelf($('[data-s]', vs), { titles: { 91: 'Pin the runner image digest' } });
      sh.open();
      S.autofit(vs, 1);
      let hands = false, played = false, cancel = null;
      vs.addEventListener('pointerdown', () => { hands = true; if (cancel) cancel(); });
      vs.addEventListener('keydown', () => { hands = true; if (cancel) cancel(); });
      whileSeen(vs, () => {
        if (hands || played || still()) return; played = true;
        setTimeout(() => { if (hands) return; cancel = typeInto(sh.input, 'github.com/aurora/infra/pull/91', () => { if (hands) return; sh.add(sh.input.value); sh.input.value = '';
          setTimeout(() => { if (hands) return; cancel = typeInto(sh.input, 'ask Theo about the cache key', () => { if (!hands) { sh.add(sh.input.value); sh.input.value = ''; } }); }, 4200); }); }, 900);
      }, () => {});
    }

    /* Clipboard deck */
    const vd = $('[data-vig="deck"]');
    if (vd) {
      vd.innerHTML = '<div class="vdeck"><div data-d style="left:50%;margin-left:-202px"></div></div>';
      const d = Deck($('[data-d]', vd));
      const box = $('.vdeck', vd);
      const size = () => { const k = clamp((vd.clientWidth - 24) / 404, .6, 1.25); const el = $('[data-d]', vd); el.style.transform = `scale(${k})`; el.style.transformOrigin = '50% 0'; box.style.height = 440 * k + 34 + 'px'; };
      new ResizeObserver(size).observe(vd); size();
      let hands = false, id = 0, dir = 1, n = 0;
      const stop = () => { hands = true; clearInterval(id); };
      vd.addEventListener('pointerdown', stop); vd.addEventListener('keydown', stop);
      $$('[data-deck-act]').forEach(b => b.addEventListener('click', () => { stop(); const a = b.dataset.deckAct; if (a === 'up') d.step(-1); else if (a === 'down') d.step(1); else if (a === 'copy') d.copy(); else d.cycle(1); }));
      whileSeen(vd, () => { if (hands || still()) return; id = setInterval(() => { n++; if (n % 4 === 0) { d.copy(); return; } if (!d.step(dir)) { dir = -dir; d.step(dir); } }, 1900); }, () => clearInterval(id));
    }

    /* App opener: four looks behind a switcher, each one live */
    const vo = $('[data-vig="opener"]');
    if (vo) {
      const KEYS = Object.keys(OPENERS);
      vo.innerHTML = `<div class="vopen">${KEYS.map(k => `<div class="vo-look" data-look="${k}" hidden><div data-o></div></div>`).join('')}</div>`;
      const made = {};
      const look = k => made[k] || (made[k] = OPENERS[k]($(`.vo-look[data-look="${k}"] > [data-o]`, vo), k === 'launcher' ? { wall: vo } : {}));
      S.autofit(vo, 1);
      const note = $('[data-opnote]'), NOTES = { launcher: 'LIVE · TYPE > FOR COMMANDS', minimal: 'LIVE · TYPE TO FILTER', tree: 'LIVE · ⇥ OPENS THE NEXT BRANCH', orbit: 'LIVE · ← → ALONG THE ARC' };
      let cur = 'launcher', hands = false, cancel = null, t = 0, started = false, step = 0;
      const halt = () => { if (cancel) cancel(); clearTimeout(t); };
      const loop = () => {
        if (hands || still()) return;
        const o = look(cur), [text, then] = o.script[step++ % o.script.length];
        o.reset();
        cancel = typeInto(o.input, text, () => { if (hands) return; then(o); t = setTimeout(loop, 2800); }, 120);
      };
      function show(k, byHand) {
        halt();
        if (cur === 'launcher' && made.launcher) made.launcher.reset();
        cur = k; step = 0;
        $$('.vo-look', vo).forEach(el => { el.hidden = el.dataset.look !== k; });
        vo.dataset.shown = k;
        look(k).reset();
        $$('[data-opstyle]').forEach(b => { const on = b.dataset.opstyle === k; b.classList.toggle('on', on); b.setAttribute('aria-selected', on); b.tabIndex = on ? 0 : -1; });
        if (note) note.textContent = NOTES[k];
        // Picking a look is not taking the keys: it shows itself until you touch it.
        hands = false;
        if (started || byHand) { started = true; t = setTimeout(loop, 600); }
      }
      vo.addEventListener('pointerdown', () => { hands = true; halt(); });
      vo.addEventListener('keydown', e => { if (e.isTrusted) { hands = true; halt(); } });
      $$('[data-opstyle]').forEach(b => {
        b.addEventListener('click', () => show(b.dataset.opstyle, true));
        b.addEventListener('keydown', e => {
          if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
          const next = KEYS[(KEYS.indexOf(cur) + (e.key === 'ArrowRight' ? 1 : KEYS.length - 1)) % KEYS.length];
          show(next, true); $(`[data-opstyle="${next}"]`).focus(); e.preventDefault();
        });
      });
      show(cur);
      whileSeen(vo, () => { if (!started && !still()) { started = true; t = setTimeout(loop, 700); } }, () => {});
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
