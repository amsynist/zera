/* The sharing film plays muted while it is on screen, and stays paused once the visitor pauses it.
   Reduce Motion and a hidden tab both hold it still. */
(() => {
  const film = document.getElementById('sharing-film');
  if (!film) return;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  let visible = false, userPaused = false, internalPause = false;
  const sync = () => {
    if (reduce.matches || document.hidden || !visible || userPaused) { if (!film.paused) { internalPause = true; film.pause(); } }
    else if (film.muted) film.play().catch(() => {});
  };
  film.addEventListener('pause', () => { if (internalPause) { internalPause = false; return; } if (visible && !document.hidden) userPaused = true; });
  film.addEventListener('play', () => { userPaused = false; });
  new IntersectionObserver(entries => { visible = entries[0].isIntersecting; sync(); }, { threshold: 0.3 }).observe(film);
  reduce.addEventListener('change', sync);
  document.addEventListener('visibilitychange', sync);
})();
