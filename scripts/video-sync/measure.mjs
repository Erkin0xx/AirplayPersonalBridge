// Mesure du retard de l’horloge vidéo de Chromium (Chrome sans fenêtre ou Dia) par le protocole
// DevTools : journal média (« Large rendering delay ») et retard de currentTime sur l’horloge murale.
//   Chrome 157 = moteur de Dia 1.56. Lancer d’abord, SANS fenêtre (pas de profil Dia de test : Dia
//   y affiche son écran de connexion) :
//   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
//     --user-data-dir=<dossier temporaire> --remote-debugging-port=9334 --no-first-run \
//     --autoplay-policy=no-user-gesture-required file://<chemin>/scripts/video-sync/page.html
//   puis : node scripts/video-sync/measure.mjs 9334   (silent.mp4 à côté de page.html)

const port = process.argv[2] ?? '9333';
const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = targets.find(t => t.type === 'page' && t.url.includes('page.html'));
console.log('target', !!page);
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
ws.onclose = (e) => console.log('WS CLOSED', e.code, e.reason);
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  else if (m.method === 'Media.playerMessagesLogged') for (const x of m.params.messages) { if (!/FFmpegDemuxer|Selected /.test(x.message)) console.log('MSG', x.level, x.message); }
  else if (m.method === 'Media.playerErrorsRaised') console.log('ERR', JSON.stringify(m.params.errors));
  else if (m.method === 'Inspector.targetCrashed') console.log('TARGET CRASHED');
  else if (m.method === 'Runtime.consoleAPICalled') console.log('CONSOLE', JSON.stringify(m.params.args.map(a => a.value)));
};
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
await new Promise(r => ws.onopen = r);
await send('Inspector.enable'); await send('Runtime.enable'); await send('Media.enable');
const ev = async (expr) => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true, userGesture: true }));
console.log('ready', JSON.stringify((await ev('document.getElementById("v").readyState')).result));
const t = setTimeout(() => { console.log('TIMEOUT'); }, 20000);
const r = await ev(`(async () => { const v = document.getElementById('v'); v.currentTime = 0; const t0 = performance.now(); try { await v.play(); } catch (e) { return 'play error ' + e; } const s = []; for (let i = 0; i < 400; i++) { await new Promise(r => setTimeout(r, 20)); s.push([(performance.now()-t0)/1000, v.currentTime]); } v.pause(); const first = s.find(x => x[1] > 0.02); const tail = s.filter(x => x[0] > 6).map(x => x[0]-x[1]).sort((a,b)=>a-b); const q = v.getVideoPlaybackQuality(); return {first: first && first[0], lag: tail[Math.floor(tail.length/2)], dropped: q.droppedVideoFrames, total: q.totalVideoFrames}; })()`);
clearTimeout(t);
console.log('RESULT', JSON.stringify(r.result ?? r));
await new Promise(r => setTimeout(r, 500));
ws.close();
