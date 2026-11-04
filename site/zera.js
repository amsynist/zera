(() => {
  const tabs = [...document.querySelectorAll('[data-screen]')];
  const image = document.getElementById('screen-image');
  const panel = document.getElementById('screen-panel');
  const select = (tab, focus = false) => {
    for (const item of tabs) { const active = item === tab; item.setAttribute('aria-selected', String(active)); item.tabIndex = active ? 0 : -1; }
    image.src = tab.dataset.image; image.alt = `${tab.dataset.label}: current native Zera 2 screen with example data`;
    document.getElementById('screen-title').textContent = tab.dataset.label;
    document.getElementById('screen-caption').textContent = tab.dataset.caption;
    panel.setAttribute('aria-labelledby', tab.id);
    if (focus) tab.focus();
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', event => {
      let index;
      if (event.key === 'ArrowRight') index = (i + 1) % tabs.length;
      else if (event.key === 'ArrowLeft') index = (i + tabs.length - 1) % tabs.length;
      else if (event.key === 'Home') index = 0;
      else if (event.key === 'End') index = tabs.length - 1;
      else return;
      event.preventDefault(); select(tabs[index], true);
    });
  });
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const film = document.getElementById('sharing-film');
  let visible = false, userPaused = false, internalPause = false;
  const sync = () => {
    if (reduce.matches || document.hidden || !visible || userPaused) { if (!film.paused) { internalPause = true; film.pause(); } }
    else if (film.muted) film.play().catch(() => {});
  };
  film.addEventListener('pause', () => { if (internalPause) { internalPause = false; return; } if (visible && !document.hidden) userPaused = true; });
  film.addEventListener('play', () => { userPaused = false; });
  new IntersectionObserver(entries => { visible = entries[0].isIntersecting; sync(); }, {threshold: 0.3}).observe(film);
  reduce.addEventListener('change', sync); document.addEventListener('visibilitychange', sync);
})();
