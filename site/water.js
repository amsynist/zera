// A bounded preview: no browser notifications, reminder data or automatic visits.
(() => {
  const demo = document.querySelector('#water-demo');
  const figure = document.querySelector('#water-character');
  const heading = document.querySelector('#water-heading'), line = document.querySelector('#water-line');
  const send = document.querySelector('#water-send'), replies = document.querySelector('#water-replies');
  const sip = document.querySelector('#water-sip'), moment = document.querySelector('#water-moment');
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  const prompts = [
    ['neutral', 'Tiny screen tap! Your water misses you. A sip? 💧'],
    ['pleading', "One tiny sip? Look, I'm doing my very best puppy eyes."],
    ['unimpressed', 'Another tab? Interesting. Is that tab a glass of water?'],
    ['sleepy', "I've aged three business days waiting for this sip."],
    ['happy', 'Emotional support boba is here. Your water is over there.'],
    ['thoughtful', "Plot twist: the main character drinks water. That's you. 💧"],
  ];
  let timer, nextLine = 0, pending, due = 0, remaining = 0, visible = false;
  function schedule(fn, ms) {
    clearTimeout(timer); pending = fn; remaining = ms; due = 0;
    if (visible && !document.hidden) { due = performance.now() + ms; timer = setTimeout(() => { pending = null; fn(); }, ms); }
  }
  function activity() {
    demo.classList.toggle('offscreen', !visible || document.hidden);
    if (!pending) return;
    clearTimeout(timer);
    if (!visible || document.hidden) { if (due) remaining = Math.max(0, due - performance.now()); due = 0; }
    else { const fn = pending; schedule(fn, remaining); }
  }
  function waiting() {
    demo.dataset.state = 'waiting';
    heading.textContent = 'A little water break';
    const [mood, text] = prompts[nextLine++ % prompts.length];
    demo.dataset.mood = mood; line.textContent = text;
    send.hidden = true; replies.hidden = false; sip.disabled = moment.disabled = false;
    schedule(waiting, 12000);
  }
  send.addEventListener('click', () => {
    nextLine = 0; send.hidden = true; replies.hidden = true;
    heading.textContent = 'Boba delivery. Human hydration.';
    line.textContent = 'Coming over with a tiny tap and a big request.';
    demo.dataset.state = 'arriving'; demo.dataset.mood = 'surprised';
    schedule(waiting, motion.matches ? 0 : 1250);
  });
  sip.addEventListener('click', () => {
    if (!['waiting', 'quiet'].includes(demo.dataset.state)) return;
    demo.dataset.state = 'thanking'; demo.dataset.mood = 'happy';
    heading.textContent = 'Sip, sip, hooray!';
    line.textContent = "Cheers! Your brain says thanks. I'll head back up. 💙";
    replies.hidden = true;
    schedule(() => {
      demo.dataset.state = 'returning';
      schedule(() => {
        demo.dataset.state = 'idle'; demo.dataset.mood = 'happy';
        send.textContent = 'Another little visit ↗'; send.hidden = false;
        heading.textContent = 'That’s my hydrated human.';
        line.textContent = 'Back to my perch. Your next sip has a fan.';
        send.focus({preventScroll: true});
      }, motion.matches ? 0 : 1000);
    }, 2100);
  });
  moment.addEventListener('click', () => {
    demo.dataset.state = 'quiet'; demo.dataset.mood = 'happy';
    heading.textContent = "I'll keep you company";
    line.textContent = "No rush. I'll sip my boba while you find your water. 🧋";
    schedule(waiting, 20000);
  });
  sip.addEventListener('pointerenter', () => demo.dataset.mood = 'happy');
  sip.addEventListener('pointerleave', () => {
    if (demo.dataset.state === 'waiting') demo.dataset.mood = prompts[(nextLine - 1) % prompts.length][0];
  });
  figure.addEventListener('click', () => {
    if (['arriving', 'returning'].includes(demo.dataset.state)) return;
    demo.dataset.mood = 'happy'; figure.classList.remove('poke'); void figure.offsetWidth; figure.classList.add('poke');
    if (demo.dataset.state === 'idle') line.textContent = 'I have boba. You bring the water. Deal?';
  });
  figure.addEventListener('animationend', e => {
    if (e.animationName === 'water-cheer') figure.classList.remove('poke');
  });
  demo.addEventListener('pointermove', e => {
    if (!visible) return;
    const r = figure.getBoundingClientRect();
    figure.style.setProperty('--gaze-x', `${Math.tanh((e.clientX - r.left - r.width / 2) / 180) * 4}px`);
    figure.style.setProperty('--gaze-y', `${Math.tanh((e.clientY - r.top - r.height * .55) / 130) * 3}px`);
  }, {passive:true});
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; activity(); }, {threshold:.1}).observe(demo);
  document.addEventListener('visibilitychange', activity);
})();
