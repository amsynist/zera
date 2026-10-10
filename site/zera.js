// The app's hang_smile anchors, in original 153 × 264 sprite coordinates.
// Native SVG layers stay attached to one body; no sprite swaps or animation library.
(() => {
  const buddy = document.querySelector('#web-zera');
  const body = document.querySelector('#buddy-body');
  const eyes = [document.querySelector('#buddy-left'), document.querySelector('#buddy-right')];
  const bubble = document.querySelector('#buddy-bubble');
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  let bounds, gx = 0, gy = 0, tx = 0, ty = 0, hover = false;
  let frame = 0, previous = 0, nextBlink = 0, blinkStart = 0;
  let lastTap = 0, taps = 0, reaction = 0, annoyed = false, speechTimer, settleTimer;
  const anchors = [[51, 167], [109, 140]];
  const refreshBounds = () => { bounds = buddy.getBoundingClientRect(); };
  const say = text => {
    bubble.textContent = text;
    bubble.classList.add('show');
    clearTimeout(speechTimer);
    speechTimer = setTimeout(() => bubble.classList.remove('show'), 2800);
  };
  function paint(now) {
    if (document.hidden) { frame = 0; return; }
    // Match the app's 30 fps clock and .17 second gaze settling time.
    if (previous && now - previous < 1000 / 30 && !motion.matches) {
      frame = requestAnimationFrame(paint); return;
    }
    const dt = previous ? Math.min((now - previous) / 1000, .1) : 1 / 30;
    previous = now;
    const ease = motion.matches ? 1 : 1 - Math.exp(-dt / .17);
    gx += (tx - gx) * ease; gy += (ty - gy) * ease;
    let openness = 1;
    if (!motion.matches) {
      if (!nextBlink) nextBlink = now + 3000 + Math.random() * 3000;
      if (now >= nextBlink) { blinkStart = now; nextBlink = now + 3000 + Math.random() * 3000; }
      const blink = now - blinkStart;
      if (blinkStart && blink < 220) openness = blink < 70 ? 1 - blink / 70 : blink < 100 ? 0 : (blink - 100) / 120;
    }
    const elapsed = (now - reaction) / 1000;
    const reacting = reaction > 0 && elapsed < (annoyed ? 2.6 : 1.2);
    if (!reacting) { buddy.classList.remove('happy', 'annoyed'); annoyed = false; }
    const huff = reacting && annoyed ? Math.min(1, elapsed / .15, (2.6 - elapsed) / .45) : 0;
    eyes.forEach((eye, i) => {
      const [x, y] = anchors[i];
      eye.setAttribute('transform', `translate(${x + gx * 4} ${y + gy * 3}) rotate(-25)`);
      eye.querySelector('.eye-open').setAttribute('transform', `scale(${1 + (hover ? .04 : 0)} ${Math.max(.045, openness * (1 - huff * .45))})`);
      const inward = i === 0 ? 1 : -1;
      eye.querySelector('.eye-brow').setAttribute('d', `M-6 ${-20 - huff * 5 * inward} Q0 -22 6 ${-20 + huff * 5 * inward}`);
    });
    let angle = 0, bounce = 0, scale = 1;
    if (!motion.matches) {
      angle = Math.sin(now / 1700) * 1.4 + gx * 1.4;
      scale = 1 + Math.sin(now / 950) * .004 + (hover ? .012 : 0);
      if (reacting) {
        if (annoyed) angle += Math.sin(elapsed * 28) * 6 * Math.exp(-elapsed * 1.5) * huff;
        else bounce = -Math.sin(Math.min(1, elapsed / .65) * Math.PI) * 5;
      }
    }
    body.setAttribute('transform', `translate(89 0) rotate(${angle}) scale(${scale}) translate(-89 ${bounce})`);
    frame = motion.matches ? 0 : requestAnimationFrame(paint);
  }
  function start() {
    if (!frame && !document.hidden) { previous = 0; frame = requestAnimationFrame(paint); }
  }
  refreshBounds();
  new ResizeObserver(refreshBounds).observe(buddy);
  addEventListener('scroll', refreshBounds, {passive: true});
  addEventListener('resize', refreshBounds, {passive: true});
  addEventListener('pointermove', e => {
    tx = Math.tanh((e.clientX - bounds.left - bounds.width / 2) / 260);
    ty = Math.tanh((e.clientY - bounds.top - bounds.height * .58) / 200);
    if (motion.matches) start();
  }, {passive: true});
  document.documentElement.addEventListener('pointerleave', () => { tx = ty = 0; start(); });
  buddy.addEventListener('pointerenter', () => { hover = true; start(); });
  buddy.addEventListener('pointerleave', () => { hover = false; start(); });
  buddy.addEventListener('click', () => {
    const now = performance.now();
    taps = now - lastTap < 1100 ? taps + 1 : 1; lastTap = now;
    annoyed = taps >= 4; if (annoyed) taps = 0;
    reaction = now;
    buddy.classList.toggle('annoyed', annoyed);
    buddy.classList.toggle('happy', !annoyed);
    say(annoyed ? 'Hey! Tiny buddy. Personal space.' : ['Hi! I saved you a spot.', 'Just hanging out. With you.', 'A little sip of water? 💧'][Math.floor(Math.random() * 3)]);
    // A reduced-motion reaction still settles without running a continuous clock.
    clearTimeout(settleTimer);
    settleTimer = setTimeout(() => { if (motion.matches) start(); }, annoyed ? 2650 : 1250);
    start();
  });
  document.addEventListener('visibilitychange', () => {
    cancelAnimationFrame(frame); frame = 0; previous = 0; nextBlink = blinkStart = 0;
    if (!document.hidden) start();
  });
  motion.addEventListener('change', () => {
    cancelAnimationFrame(frame); frame = 0; nextBlink = blinkStart = 0; start();
  });
  buddy.addEventListener('focus', () => say('Hello! Press Enter to say hi.'));
  start();
})();
