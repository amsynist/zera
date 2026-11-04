// The release page is a stable fallback until the v2 build is published.
(() => {
  fetch('https://api.github.com/repos/amsynist/zera/releases/tags/v2.0.0', {headers: {Accept: 'application/vnd.github+json'}})
    .then(response => { if (!response.ok) throw new Error('Release is not published'); return response.json(); })
    .then(release => {
      const dmg = release.assets?.find(asset => /^Zera-2\.0\.0\.dmg$/.test(asset.name));
      const trusted = url => typeof url === 'string' && url.startsWith('https://github.com/amsynist/zera/releases/download/');
      if (trusted(dmg?.browser_download_url)) {
        document.querySelectorAll('[data-download]').forEach(link => { link.href = dmg.browser_download_url; });
        document.getElementById('download-version').textContent = `${release.tag_name} · macOS 13+ · Apple silicon & Intel`;
      }
      const apk = release.assets?.find(asset => asset.name === 'Androp.apk');
      if (trusted(apk?.browser_download_url)) document.querySelectorAll('[data-apk-download]').forEach(link => { link.href = apk.browser_download_url; });
    }).catch(() => {});
})();
