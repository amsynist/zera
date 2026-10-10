// Splash, a bounded preview: no notifications or reminder data. Click the desk (or press the
// button) and a glass pops up there; Zera jumps from the notch into it with a splash.
(() => {
  const $ = (id) => document.getElementById(id);
  const desk = $('water-desk'), glass = $('water-glass'), cap = $('water-cap'), jumper = $('water-jumper');
  const hang = $('water-hang'), rope = $('water-rope'), bead = $('water-bead'), inGlass = $('water-in'), level = $('water-level');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let timers = [], at = null, busy = false, glasses = 4;
  let countTimer;
  const flashCount = (ms) => { $('water-count').classList.add('on'); clearTimeout(countTimer); if (ms) countTimer = setTimeout(() => $('water-count').classList.remove('on'), ms); };
  const setCount = () => {
    $('water-count-num').textContent = `${glasses}/8`; $('water-count-fill').style.height = `${glasses / 8 * 100}%`;
    $('water-count').setAttribute('aria-label', `Water today: ${glasses} of 8`); $('water-today').textContent = `${glasses} of 8 today`;
  };
  const later = (ms, f) => timers.push(setTimeout(f, reduced.matches ? 0 : ms));
  const clearAll = () => { timers.forEach(clearTimeout); timers = []; };
  const home = () => ({ x: desk.clientWidth / 2, y: 40 });
  const onRope = (on) => { hang.style.opacity = on ? 1 : 0; rope.classList.toggle('on', !on); };

  function jump(a, b, src, flip, done) {
    jumper.src = src;
    const peak = Math.min(a.y, b.y) - 70, frames = [];
    for (let i = 0; i <= 16; i++) {
      const t = i / 16, s = t * t * (3 - 2 * t), u = 1 - s;
      const x = u * u * a.x + 2 * u * s * (a.x + b.x) / 2 + s * s * b.x;
      const y = u * u * a.y + 2 * u * s * peak + s * s * b.y;
      frames.push({ transform: `translate(${x - 23}px, ${y - 24}px) rotate(${flip * 360 * t}deg)`, opacity: 1 });
    }
    jumper.style.opacity = 1;
    const an = jumper.animate(frames, { duration: reduced.matches ? 1 : 700, fill: 'forwards' });
    an.onfinish = () => { jumper.style.opacity = 0; done(); };
  }

  function splash(x, y) {
    if (reduced.matches) return;
    const r = document.createElement('div'); r.className = 'water-ripple';
    Object.assign(r.style, { left: (x - 31) + 'px', top: (y - 6) + 'px' }); desk.appendChild(r);
    r.animate([{ transform: 'scale(.4)', opacity: 1 }, { transform: 'scale(1.6)', opacity: 0 }], { duration: 700, fill: 'forwards' }).onfinish = () => r.remove();
    for (let i = 0; i < 8; i++) {
      const d = document.createElement('div'); d.className = 'water-drop';
      Object.assign(d.style, { left: (x - 3 + (i - 3.5) * 5) + 'px', top: (y - 4) + 'px' }); desk.appendChild(d);
      const dx = (i - 3.5) * 12, up = 34 + (i % 3) * 12;
      d.animate([{ transform: 'translate(0,0)' }, { transform: `translate(${dx * .6}px, ${-up}px)`, offset: .45 }, { transform: `translate(${dx}px, ${-up + 60}px)`, opacity: 0 }],
        { duration: 750, easing: 'cubic-bezier(.2,.6,.4,1)', fill: 'forwards' }).onfinish = () => d.remove();
    }
    glass.animate([{ transform: 'scale(1)' }, { transform: 'scale(1.05,.94)' }, { transform: 'scale(.98,1.02)' }, { transform: 'scale(1)' }], { duration: 420 });
  }

  function remind(point) {
    if (busy) return;
    busy = true; clearAll(); bead.hidden = true; cap.classList.remove('on'); $('water-count').classList.remove('on');
    const w = desk.clientWidth, h = desk.clientHeight, gw = 62, gh = 74, cw = cap.offsetWidth || 220, ch = 52;
    const gx = Math.max(8, Math.min(w - gw - 8, point.x + 18 + gw <= w - 8 ? point.x + 18 : point.x - 18 - gw));
    const gy = Math.max(90, Math.min(h - gh - 10, point.y + 18));
    Object.assign(glass.style, { left: gx + 'px', top: gy + 'px' });
    // Beside the glass when it fits (right first), otherwise below it, or above near the bottom.
    let cx, cy, side = 'right';
    if (gx + gw + 12 + cw <= w - 8) { cx = gx + gw + 12; cy = gy + 8; }
    else if (gx - 12 - cw >= 8) { cx = gx - 12 - cw; cy = gy + 8; side = 'left'; }
    else { cx = Math.max(8, Math.min(w - cw - 8, gx + gw / 2 - cw / 2)); cy = gy + gh + 12 + ch <= h - 6 ? gy + gh + 12 : gy - ch - 40; side = 'below'; }
    cap.classList.toggle('left', side === 'left');
    Object.assign(cap.style, { left: cx + 'px', top: cy + 'px' });
    inGlass.src = 'assets/zera-hello.png'; inGlass.style.opacity = 0; inGlass.style.top = '-14px'; level.style.height = '';
    glass.getAnimations().forEach(a => a.cancel()); glass.style.transform = '';
    glass.animate([{ transform: 'scale(0)' }, { transform: 'scale(1.1)', offset: .6 }, { transform: 'scale(1)' }], { duration: reduced.matches ? 1 : 420, fill: 'forwards' });
    const seat = { x: gx + gw / 2, y: gy + 10 };
    later(60, () => {
      onRope(false);
      jump(home(), seat, 'assets/zera-jump.png', 1, () => {
        splash(seat.x, gy + 26); inGlass.style.opacity = 1;
        later(420, () => { cap.classList.add('on'); busy = false; });
        later(30000, () => goHome(true));
      });
    });
  }

  function goHome(leaveBead) {
    clearAll(); busy = true; cap.classList.remove('on');
    const r = glass.getBoundingClientRect(), d = desk.getBoundingClientRect();
    const seat = { x: r.left - d.left + r.width / 2, y: r.top - d.top + 10 };
    inGlass.style.opacity = 0;
    jump(seat, home(), inGlass.src.includes('sleepy') ? 'assets/zera-sleepy.png' : 'assets/zera-cheer.png', -1, () => { onRope(true); busy = false; bead.hidden = !leaveBead; if (leaveBead) flashCount(0); });
    glass.animate([{ transform: 'scale(1)', opacity: 1 }, { transform: 'scale(.2)', opacity: 0 }], { duration: reduced.matches ? 1 : 420, delay: reduced.matches ? 0 : 200, fill: 'forwards' });
  }

  desk.addEventListener('click', (e) => {
    if (e.target.closest('button')) return;
    const d = desk.getBoundingClientRect();
    at = { x: e.clientX - d.left, y: e.clientY - d.top };
    remind(at);
  });
  $('water-send').addEventListener('click', () => remind(at || { x: desk.clientWidth * .1, y: desk.clientHeight * .38 }));
  bead.addEventListener('click', () => remind(at || { x: desk.clientWidth * .1, y: desk.clientHeight * .38 }));
  $('water-drank').addEventListener('click', () => {
    clearAll(); cap.classList.remove('on');
    inGlass.src = 'assets/zera-cheer.png'; level.style.height = '12%'; inGlass.style.top = '0px';
    later(1100, () => { glasses = Math.min(8, glasses + 1); goHome(false); later(800, () => { flashCount(6000); setTimeout(setCount, 250); }); });
  });
  $('water-later').addEventListener('click', () => {
    clearAll(); cap.classList.remove('on'); inGlass.src = 'assets/zera-sleepy.png';
    later(500, () => goHome(false));
  });
})();
