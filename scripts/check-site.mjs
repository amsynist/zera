// Run with Node alone: assets, anchors, page security rules, the live-demo kit, film lifecycle and safe release URLs.
import assert from 'node:assert/strict';
import {readFileSync, existsSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
const read=name=>readFileSync(new URL(`../site/${name}`,import.meta.url),'utf8');
const html=read('index.html'), css=read('zera.css'), stage=read('stage.js'), page=read('zera.js');

// Every local file the page or stylesheet points at exists.
for(const [,path] of html.matchAll(/(?:href|src|poster)="([^"#]+)"/g)) {
  if(!/^(https?:|mailto:)/.test(path)) assert(existsSync(new URL(`../site/${path}`,import.meta.url)),`Missing asset: ${path}`);
}
for(const [,path] of css.matchAll(/url\(([^)]+)\)/g)) assert(existsSync(new URL(`../site/${path}`,import.meta.url)),`Missing stylesheet asset: ${path}`);
assert(existsSync(new URL('../Androp.apk',import.meta.url)),'Root Android download is missing');
const ids=new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]));
for(const [,id] of html.matchAll(/href="#([^"]+)"/g)) assert(ids.has(id),`Broken anchor: ${id}`);
for(const id of ['sharing-film','daily-shelf','screens','tour']) assert(ids.has(id),`Published link target is gone: #${id}`);

// Page security: a strict policy, no inline script, no inline handlers, no third-party script or font.
const csp=html.match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)?.[1]??'';
assert.match(csp,/default-src 'self'/);
assert.match(csp,/script-src 'self'(;|$)/,'Scripts must come from this origin only');
assert.match(csp,/connect-src https:\/\/api\.github\.com(;|$)/,'The page may only call the GitHub releases API');
assert.match(csp,/object-src 'none'/);assert.match(csp,/base-uri 'none'/);
assert(!/<script(?![^>]*\bsrc=)[^>]*>/.test(html),'Inline scripts are not allowed');
assert(!/\son[a-z]+\s*=/i.test(html),'Inline event handlers are not allowed');
for(const [,src] of html.matchAll(/<script[^>]+src="([^"]+)"/g)) assert(!/^https?:/.test(src),`Third-party script: ${src}`);
for(const [tag] of html.matchAll(/<a\b[^>]*href="https?:[^>]*>/g)) assert(/rel="noopener noreferrer"/.test(tag),`External link without rel: ${tag}`);
for(const name of ['stage.js','zera.js','signal.js','film.js']) {
  const source=read(name);
  assert(!/\beval\(|new Function|document\.write|XMLHttpRequest|\bfetch\(/.test(source),`${name} must not evaluate strings or make requests`);
}

// Films keep their captions; motion has a reduced path.
for(const [video] of html.matchAll(/<video[\s\S]*?<\/video>/g)) assert.match(video,/<track kind="captions"[^>]+\.vtt/,'Every film needs captions');
assert.match(html,/<video id="daily-shelf-film"[^>]+controls/);
assert.match(css,/@media \(prefers-reduced-motion:reduce\)/);

// The kit builds markup and escapes visitor text.
const win={};
runInNewContext(read('signal.js'),{window:win,matchMedia:()=>({matches:false}),document:{},addEventListener(){},Date,Math,Object,Array,String});
const Sig=win.Sig;
assert.match(Sig.zera({m:'ok',wave:true}),/^<svg class="zera"/);
assert.equal(Sig.esc('<img src=x onerror="1">'),'&lt;img src=x onerror=&quot;1&quot;&gt;');
assert.match(Sig.btn('Approve','g','ok','↵','approve'),/^<button type="button"[^>]+data-act="approve"/);
assert.match(Sig.wings({L:'a',R:'b'}),/class="wg"/);

// Every tile on the rail, and every "open in the notch" link, has a screen behind it.
const nav=[...stage.match(/const NAV = \[([\s\S]*?)\];/)[1].matchAll(/\['([a-z]+)'/g)].map(m=>m[1]);
assert.equal(nav.length,10,'The rail has ten screens');
const screens=new Set([...stage.matchAll(/^ {6}([a-z]+): \{$/gm)].map(m=>m[1]));
for(const key of [...nav,'settings']) assert(screens.has(key),`No live screen for: ${key}`);
const linked=[...html.matchAll(/data-open-screen="([a-z]+)"/g),...page.matchAll(/^ {4}\['([a-z]+)', '/gm)].map(m=>m[1]);
assert(linked.length>=10);
for(const key of linked) assert(screens.has(key),`Link opens an unknown screen: ${key}`);
for(const act of ['approve','reject','task','dismiss','answer','sig','deck','dshelf','opener']) {
  assert(new RegExp(`(^|[\\s{,])'?${act}'?: `,'m').test(stage),`Demo action is not wired: ${act}`);
}

// Sharing film: autoplays muted in view, respects Reduce Motion, a hidden tab and a visitor's pause.
class Element {
  events={};attrs={};dataset={};paused=true;muted=true;plays=0;pauses=0;
  addEventListener(name,fn){this.events[name]=fn;}
  setAttribute(name,value){this.attrs[name]=value;}
  play(){this.paused=false;this.plays++;this.events.play?.();return Promise.resolve();}
  pause(){this.paused=true;this.pauses++;}
}
const film=new Element();
const document={hidden:false,events:{},getElementById:id=>id==='sharing-film'?film:null,addEventListener(name,fn){this.events[name]=fn;}};
const reduce=new Element();reduce.matches=false;let intersection;
runInNewContext(read('film.js'),{document,matchMedia:()=>reduce,IntersectionObserver:class{constructor(fn){intersection=fn;}observe(){}}});
intersection([{isIntersecting:true}]);assert.equal(film.plays,1);
reduce.matches=true;reduce.events.change();assert(film.paused);film.events.pause();
reduce.matches=false;reduce.events.change();assert.equal(film.plays,2,'Reduced Motion can be turned off without losing autoplay state');
document.hidden=true;document.events.visibilitychange();film.events.pause();assert(film.paused);
document.hidden=false;document.events.visibilitychange();assert.equal(film.plays,3);
film.pause();film.events.pause();intersection([{isIntersecting:false}]);intersection([{isIntersecting:true}]);
assert.equal(film.plays,3,'A user pause remains paused');

// Download buttons only ever take a GitHub release URL that matches the tag and the asset name.
async function release(dmgURL, apkURL, tag='v2.1.0'){
 const links=[new Element()],apk=[new Element()];const label=new Element();
 const doc={querySelectorAll:s=>s==='[data-download]'?links:apk,getElementById:()=>label};
 runInNewContext(readFileSync(new URL('../site/install.js',import.meta.url),'utf8'),{
   document:doc,
   fetch:async url=>{
     assert.equal(url,'https://api.github.com/repos/amsynist/zera/releases/latest');
     return {ok:true,json:async()=>({tag_name:tag,assets:[
       {name:'Zera-2.1.0.dmg',browser_download_url:dmgURL},
       {name:'Androp.apk',browser_download_url:apkURL}
     ]})};
   }
 });
 await new Promise(resolve=>setTimeout(resolve,0));return {links,apk,label};
}
const prefix='https://github.com/amsynist/zera/releases/download/';
const dmgURL=prefix+'v2.1.0/Zera-2.1.0.dmg', apkURL=prefix+'v2.1.0/Androp.apk';
let result=await release('https://evil.example/installer',dmgURL);
assert.equal(result.links[0].href,undefined,'Untrusted download URLs must be ignored');
assert.equal(result.apk[0].href,undefined,'A trusted URL must identify the correct asset');
result=await release(prefix+'v2.0.0/Zera-2.1.0.dmg',apkURL);
assert.equal(result.links[0].href,undefined,'An asset URL must match the release tag');
result=await release(dmgURL,apkURL);
assert.equal(result.links[0].href,dmgURL);
assert.equal(result.apk[0].href,apkURL);
assert.match(result.label.textContent,/^v2\.1\.0/);
result=await release(dmgURL,apkURL,'v2.1.0-rc.1');
assert.equal(result.links[0].href,undefined,'Pre-release tags must leave the download fallback intact');
console.log('Site checks passed: assets, anchors, security policy, captions, live-demo kit and screens, film lifecycle and release URLs.');
