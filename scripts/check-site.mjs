// Run: node scripts/check-site.mjs. No browser dependencies needed.
import assert from 'node:assert/strict';
import {readFileSync, existsSync} from 'node:fs';
import {runInNewContext} from 'node:vm';

const html = readFileSync(new URL('../site/index.html', import.meta.url), 'utf8');
for (const [, path] of html.matchAll(/(?:href|src)="([^"#]+)"/g)) {
  if (!/^(https?:|mailto:)/.test(path)) assert(existsSync(new URL(`../site/${path}`, import.meta.url)), `Missing site asset: ${path}`);
}
// Syntax-check the existing page controller too.
for (const [, script] of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) new Function(script);

class Element {
  events = {}; attrs = {}; children = {}; classes = new Set();
  classList = {
    add: (...names) => names.forEach(n => this.classes.add(n)),
    remove: (...names) => names.forEach(n => this.classes.delete(n)),
    toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
  };
  addEventListener(name, fn) { this.events[name] = fn; }
  setAttribute(name, value) { this.attrs[name] = value; }
  querySelector(name) { return this.children[name] ??= new Element(); }
  getBoundingClientRect() { return {left:400,top:0,width:112,height:193}; }
}
const elements = Object.fromEntries(['#web-zera','#buddy-body','#buddy-left','#buddy-right','#buddy-bubble'].map(id=>[id,new Element()]));
const document = new Element(); document.hidden = false; document.documentElement = new Element();
document.querySelector = id => elements[id];
const motion = new Element(); motion.matches = false;
const windowEvents = {}, frames = new Map(); let frameID = 0, now = 1000;
runInNewContext(readFileSync(new URL('../site/zera.js',import.meta.url),'utf8'), {
  document, matchMedia:()=>motion, performance:{now:()=>now},
  addEventListener:(name,fn)=>windowEvents[name]=fn,
  ResizeObserver:class { observe() {} }, setTimeout:()=>1, clearTimeout:()=>{},
  requestAnimationFrame:fn=>{frames.set(++frameID,fn);return frameID;},
  cancelAnimationFrame:id=>frames.delete(id),
});
const paint = time => { now=time; const [id,fn]=frames.entries().next().value;frames.delete(id);fn(time); };
paint(1000);
windowEvents.pointermove({clientX:10000,clientY:10000});
for(let t=1040;t<=1600;t+=40) paint(t);
const [eyeX,eyeY] = elements['#buddy-left'].attrs.transform.match(/translate\(([^ ]+) ([^)]+)\)/).slice(1).map(Number);
assert(eyeX>51 && eyeX<=55 && eyeY>167 && eyeY<=170, 'Gaze should follow and stay within the face');
for(let i=0;i<4;i++){now+=150;elements['#web-zera'].events.click();}
assert(elements['#web-zera'].classes.has('annoyed'), 'Four quick taps should huff');
paint(now+2700);
assert(!elements['#web-zera'].classes.has('annoyed'), 'Expression should settle');
document.hidden=true;document.events.visibilitychange();
assert.equal(frames.size,0,'Hidden tabs must stop the clock');
document.hidden=false;document.events.visibilitychange();
assert.equal(frames.size,1,'Visible tabs should resume once');
motion.matches=true;motion.events.change();paint(now+40);
assert.equal(frames.size,0,'Reduce Motion must not run an idle animation loop');
assert.equal(elements['#buddy-body'].attrs.transform,'translate(89 0) rotate(0) scale(1) translate(-89 0)');
console.log('Site checks passed: assets, script syntax, gaze bounds, tap recovery, visibility and Reduce Motion.');
