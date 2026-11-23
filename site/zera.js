/* Page behaviour: the section rail and its lit trace, reveals, the signal colour, small utilities. */
(() => {
  'use strict';
  const $ = (s, el = document) => el.querySelector(s), $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const root = document.documentElement;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');

  /* ── signal colour: one accent for the whole page, like Appearance › Signal colour in the app ── */
  const SIGS = ['#7be1c2', '#5ab8ff', '#9b8df9', '#ff9e64', '#5dfc9a'];
  function setSig(c, save = true) {
    if (!SIGS.includes(c)) return;                      // only the five known colours, never free text
    root.style.setProperty('--sig', c);
    $$('[data-sig]').forEach(b => b.setAttribute('aria-pressed', b.dataset.sig === c));
    if (save) try { localStorage.setItem('zera-sig', c); } catch { /* private window: the choice just lasts this visit */ }
  }
  $$('[data-sig]').forEach(b => b.addEventListener('click', () => setSig(b.dataset.sig)));
  try { const saved = localStorage.getItem('zera-sig'); if (saved) setSig(saved, false); } catch { /* storage blocked */ }
  window.ZeraPage = { setSig };

  /* ── everyday tiles: each one opens its screen in the live notch ── */
  const TILES = [
    ['tasks', 'tasks', 'Tasks and timesheets', 'Type a task with #project and 30m. Export a range to Excel, CSV or text.', '#9b8df9'],
    ['focus', 'target', 'Focus', 'One task, one ring. A small orb at the edge keeps time while you work.', '#7be1c2'],
    ['prs', 'pr', 'Pull requests', 'Reviews, checks and approvals from your GitHub account, with status in words.', '#ff6f7f'],
    ['rem', 'cal', 'Reminders and water', 'Your calendars in one day view, heads-ups before meetings, small water breaks.', '#ffcf70'],
    ['shelf', 'tray', 'File Shelf', 'Drop a file on the notch. Drag it out later, or ask Zera about it when you choose.', '#5ab8ff'],
    ['tele', 'lines', 'Teleprompter', 'Your words roll beside the camera, at your speed, mirrored if you need.', '#ee7991'],
    ['alerts', 'bell', 'Alerts', 'One inbox that reads like a log: what failed, what waits, what finished.', '#ffc661'],
    ['clip', 'clip', 'Clipboard history', 'Text, links, colours, code and files you copied, with ⌘1–9 to copy again.', '#9be36b'],
    ['settings', 'swatch', 'Themes and Signal', 'Nine colour themes, five signal colours, solid or translucent glass.', '#b6a4ff']
  ];
  const grid = $('#tiles');
  if (grid && window.Sig) {
    grid.innerHTML = TILES.map(([k, icn, t, d, c]) => `<button class="tilec" type="button" data-open-screen="${k}"><span class="hd"><span class="ixp" style="--c:${c}"><svg viewBox="0 0 16 16" aria-hidden="true">${window.Sig.I[icn]}</svg></span><h3>${t}</h3></span><p>${d}</p><span class="go">OPEN IN THE NOTCH ↑</span></button>`).join('');
  }

  /* ── rail, title cap and the lit trace from the active tile to the focused pane ── */
  const secs = $$('main > .sec'), links = $$('#rail a'), trace = $('#ptrace');
  let active = null;
  function spy() {
    const line = innerHeight * .42;
    let cur = secs[0];
    for (const s of secs) if (s.getBoundingClientRect().top <= line) cur = s;
    if (cur !== active) {
      active = cur;
      secs.forEach(s => s.classList.toggle('focus', s === cur));
      links.forEach(a => a.classList.toggle('on', a.getAttribute('href') === '#' + cur.id));
      const n = $('#cap-n'), t = $('#cap-t');
      if (n) n.textContent = cur.dataset.n;
      if (t) t.textContent = cur.dataset.name;
    }
    draw();
  }
  function draw() {
    if (!trace || !active || getComputedStyle(trace).display === 'none') return;
    const on = $('#rail a.on i'); if (!on) return;
    const a = on.getBoundingClientRect(), p = active.getBoundingClientRect(), q = 6;
    const x0 = a.right, y0 = a.top + a.height / 2, px = p.left, gx = Math.max(x0 + 12, px - 18);
    const py = Math.max(60, Math.min(innerHeight - 44, p.top + 15));
    const s = py > y0 ? 1 : -1, flat = Math.abs(py - y0) < q * 2;
    const d = flat ? `M${x0},${y0}H${px}` : `M${x0},${y0}H${gx - q}Q${gx},${y0} ${gx},${y0 + s * q}V${py - s * q}Q${gx},${py} ${gx + q},${py}H${px}`;
    $$('path', trace).forEach(el => el.setAttribute('d', d));
    const dot = $('circle', trace); dot.setAttribute('cx', px); dot.setAttribute('cy', flat ? y0 : py);
  }
  let raf = 0;
  const onScroll = () => { if (!raf) raf = requestAnimationFrame(() => { raf = 0; spy(); }); };
  addEventListener('scroll', onScroll, { passive: true });
  addEventListener('resize', onScroll);
  if ('ResizeObserver' in window) new ResizeObserver(onScroll).observe($('main'));
  spy();

  /* ── reveals ── */
  if ('IntersectionObserver' in window && !reduce.matches) {
    const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('rv-in'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -8% 0px' });
    $$('.rv').forEach(el => io.observe(el));
  } else $$('.rv').forEach(el => el.classList.add('rv-in'));

  /* ── copy the build commands ── */
  const copyBtn = $('#copy-build');
  if (copyBtn) copyBtn.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(copyBtn.dataset.copy); copyBtn.textContent = 'COPIED'; }
    catch { copyBtn.textContent = 'SELECT AND COPY'; }
    setTimeout(() => { copyBtn.textContent = 'COPY'; }, 1600);
  });

  const clock = $('#page-clock');
  if (clock) { const tick = () => { clock.textContent = new Date().toTimeString().slice(0, 8); }; tick(); setInterval(tick, 1000); }
})();
