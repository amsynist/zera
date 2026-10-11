// One release lookup for all download buttons. The release page remains the fallback.
(() => {
  fetch('https://api.github.com/repos/amsynist/zera/releases/latest', {
    headers: { Accept: 'application/vnd.github+json' }
  }).then(response => {
    if (!response.ok) throw new Error('Release unavailable');
    return response.json();
  }).then(release => {
    const dmg = release.assets?.find(asset => /^Zera-.*\.dmg$/.test(asset.name));
    if (!dmg?.browser_download_url?.startsWith('https://github.com/amsynist/zera/releases/download/')) return;
    document.querySelectorAll('[data-download]').forEach(link => {
      link.href = dmg.browser_download_url;
    });
    document.getElementById('download-version').textContent =
      `${release.tag_name} · macOS 13+ · Apple silicon and Intel`;
  }).catch(() => {});

  const copy = document.getElementById('copy-install');
  copy.addEventListener('click', async () => {
    const status = document.getElementById('copy-status');
    try {
      await navigator.clipboard.writeText(document.getElementById('install-command').textContent.trim());
      status.textContent = 'Copied. Paste into Terminal after installing Zera.';
    } catch {
      status.textContent = 'Select the two lines above and copy them with ⌘C.';
    }
  });
})();
