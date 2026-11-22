// Run with Node alone: assets, native gallery navigation, player lifecycle and safe release URLs.
import assert from 'node:assert/strict';
import {readFileSync, existsSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
const html=readFileSync(new URL('../site/index.html',import.meta.url),'utf8');
for(const [,path] of html.matchAll(/(?:href|src|poster|data-image)="([^"#]+)"/g)) {
  if(!/^(https?:|mailto:)/.test(path)) assert(existsSync(new URL(`../site/${path}`,import.meta.url)),`Missing asset: ${path}`);
}
assert(existsSync(new URL('../Androp.apk',import.meta.url)),'Root Android download is missing');
const ids=new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]));
for(const [,id] of html.matchAll(/href="#([^"]+)"/g)) assert(ids.has(id),`Broken anchor: ${id}`);
class Element {
  events={};attrs={};dataset={};paused=true;muted=true;plays=0;pauses=0;
  addEventListener(name,fn){this.events[name]=fn;}
  setAttribute(name,value){this.attrs[name]=value;}
  focus(){this.focused=true;}
  play(){this.paused=false;this.plays++;this.events.play?.();return Promise.resolve();}
  pause(){this.paused=true;this.pauses++;}
}
const tabs=[...html.matchAll(/<button role="tab"([^>]+)>/g)].map(([,raw])=>{
  const el=new Element();
  for(const [,key,value] of raw.matchAll(/([\w-]+)="([^"]+)"/g)) {
    if(key.startsWith('data-'))el.dataset[key.slice(5)]=value;
    else if(key==='id')el.id=value;
  }
  return el;
});
assert.equal(tabs.length,14,'Every current primary screen should be represented');
const nodes=Object.fromEntries(['screen-image','screen-panel','screen-title','screen-caption','sharing-film','download-version'].map(id=>[id,new Element()]));
const document={hidden:false,events:{},querySelectorAll:()=>tabs,getElementById:id=>nodes[id],addEventListener(name,fn){this.events[name]=fn;}};
const reduce=new Element();reduce.matches=false;let intersection;
runInNewContext(readFileSync(new URL('../site/zera.js',import.meta.url),'utf8'),{document,matchMedia:()=>reduce,IntersectionObserver:class{constructor(fn){intersection=fn;}observe(){}}});
const event=key=>({key,preventDefault(){this.prevented=true;}});
tabs[0].events.keydown(event('ArrowLeft'));
assert.equal(nodes['screen-image'].src,tabs.at(-1).dataset.image,'Keyboard navigation wraps');
assert.equal(nodes['screen-panel'].attrs['aria-labelledby'],tabs.at(-1).id);
tabs.at(-1).events.keydown(event('Home'));
assert.equal(tabs[0].attrs['aria-selected'],'true');
tabs[2].events.click();assert.equal(nodes['screen-title'].textContent,'Agents');
tabs[2].events.keydown(event('ArrowRight'));
assert.equal(nodes['screen-title'].textContent,'Daily Shelf');
assert.match(html, /<video id="daily-shelf-film"[^>]+controls[^>]*>[\s\S]*?<track kind="captions"[^>]+daily-shelf\.vtt/);
assert.equal(tabs.filter(t=>t.attrs['aria-selected']==='true').length,1);
const film=nodes['sharing-film'];intersection([{isIntersecting:true}]);assert.equal(film.plays,1);
reduce.matches=true;reduce.events.change();assert(film.paused);film.events.pause();
reduce.matches=false;reduce.events.change();assert.equal(film.plays,2,'Reduced Motion can be turned off without losing autoplay state');
document.hidden=true;document.events.visibilitychange();film.events.pause();assert(film.paused);
document.hidden=false;document.events.visibilitychange();assert.equal(film.plays,3);
film.pause();film.events.pause();intersection([{isIntersecting:false}]);intersection([{isIntersecting:true}]);
assert.equal(film.plays,3,'A user pause remains paused');
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
console.log('Site checks passed: assets, anchors, 14-screen gallery, keyboard/ARIA, captions, player lifecycle and release URLs.');
