(() => {
  const repo = 'amsynist/zera';
  fetch(`https://api.github.com/repos/${repo}/releases/latest`, {headers: {Accept: 'application/vnd.github+json'}})
    .then(response => {
      if (!response.ok) throw new Error('Release unavailable');
      return response.json();
    })
    .then(release => {
      const tag = release.tag_name;
      if (typeof tag !== 'string' || !/^v2\.\d+\.\d+$/.test(tag)) return;
      const download = name => {
        const expected = `https://github.com/${repo}/releases/download/${tag}/${name}`;
        return release.assets?.find(asset => asset.name === name && asset.browser_download_url === expected)?.browser_download_url;
      };
      const dmg = download(`Zera-${tag.slice(1)}.dmg`);
      if (dmg) {
        document.querySelectorAll('[data-download]').forEach(link => { link.href = dmg; });
        document.getElementById('download-version').textContent = `${tag} · macOS 13+ · Apple silicon & Intel`;
      }
      const apk = download('Androp.apk');
      if (apk) document.querySelectorAll('[data-apk-download]').forEach(link => { link.href = apk; });
    }).catch(() => {});
})();
