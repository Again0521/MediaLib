#!/usr/bin/env node
// P0 播放性能基线：用真实 Chromium 驱动网页播放器，采集实测指标。
//
// 为什么不是字符串断言：`player.js` 里有没有出现 `addEventListener('seeked')`
// 与"用户点了进度条之后画面真的跳过去了"是两回事。这个脚本按下真实的按钮、
// 等真实的媒体事件、读真实的解码统计，因此它能失败在只有真浏览器才暴露的
// 地方——自动播放策略、编解码支持、Range 重试、事件时序。
//
// 只依赖 Node 内建能力（fetch + WebSocket + child_process）通过 CDP 直接驱动
// 系统上已安装的 Chrome，不引入 npm 依赖：验收工具链自己不应该成为一处需要
// 长期维护的供应链。
//
//   node scripts/web_playback_baseline.mjs \
//     --server http://127.0.0.1:8099 \
//     --password '...' \
//     --manifest /private/tmp/medialib-baseline/matrix-manifest.json \
//     --out /private/tmp/medialib-baseline/baseline.json
//
// 退出码：0 全部样本完成脚本流程（含"预期无法直放"的样本），1 出现意外失败。

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CHROME_CANDIDATES = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'
];

function parseArguments(argv) {
  const options = {
    server: 'http://127.0.0.1:8099',
    // 夹具数据库里的初始管理员用户名就是 `admin`。
    username: 'admin',
    password: '',
    manifest: '',
    out: '',
    headless: true,
    seekCount: 6,
    samplesOnly: false
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    switch (flag) {
      case '--server': options.server = value; index += 1; break;
      case '--username': options.username = value; index += 1; break;
      case '--password': options.password = value; index += 1; break;
      case '--manifest': options.manifest = value; index += 1; break;
      case '--out': options.out = value; index += 1; break;
      case '--seeks': options.seekCount = Number(value); index += 1; break;
      case '--samples-only': options.samplesOnly = true; break;
      case '--headed': options.headless = false; break;
      default: break;
    }
  }
  return options;
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

/** 极小的 CDP 客户端。一个页面目标、一个 WebSocket、按 id 配对响应。 */
class DevToolsSession {
  constructor(webSocketURL) {
    this.socket = new WebSocket(webSocketURL);
    this.nextID = 1;
    this.pending = new Map();
    this.ready = new Promise((resolve, reject) => {
      this.socket.addEventListener('open', () => resolve());
      this.socket.addEventListener('error', event => reject(new Error(`CDP 连接失败: ${event.message ?? 'unknown'}`)));
    });
    this.socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.id === undefined) return;
      const entry = this.pending.get(message.id);
      if (!entry) return;
      this.pending.delete(message.id);
      if (message.error) entry.reject(new Error(`${message.error.message} (${entry.method})`));
      else entry.resolve(message.result);
    });
  }

  async send(method, params = {}) {
    await this.ready;
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  /** 在页面主世界求值。`awaitPromise` 让页面里的异步测量可以直接 await。 */
  async evaluate(expression, { awaitPromise = true, timeoutMs = 60_000 } = {}) {
    const result = await Promise.race([
      this.send('Runtime.evaluate', {
        expression, awaitPromise, returnByValue: true, userGesture: true
      }),
      sleep(timeoutMs).then(() => { throw new Error(`页面求值超时(${timeoutMs}ms)`); })
    ]);
    if (result.exceptionDetails) {
      const text = result.exceptionDetails.exception?.description
        ?? result.exceptionDetails.text ?? '未知页面异常';
      throw new Error(`页面异常: ${text}`);
    }
    return result.result?.value;
  }

  close() { try { this.socket.close(); } catch { /* 已关闭 */ } }
}

async function launchChrome(options) {
  const executable = CHROME_CANDIDATES.find(path => {
    try { readFileSync(path); return true; } catch { return false; }
  });
  if (!executable) throw new Error(`未找到 Chrome/Chromium：${CHROME_CANDIDATES.join(', ')}`);

  const profile = mkdtempSync(join(tmpdir(), 'medialib-baseline-profile-'));
  const args = [
    '--remote-debugging-port=0',
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-timer-throttling',
    '--disable-renderer-backgrounding',
    // 无用户手势也允许起播：验收要测的是播放链路，不是自动播放策略本身。
    // 真实点击路径仍然由脚本按下页面按钮触发。
    '--autoplay-policy=no-user-gesture-required',
    'about:blank'
  ];
  if (options.headless) args.unshift('--headless=new');

  const child = spawn(executable, args, { stdio: ['ignore', 'ignore', 'pipe'] });
  const endpoint = await new Promise((resolve, reject) => {
    let buffer = '';
    const timer = setTimeout(() => reject(new Error('Chrome 未在 30 秒内输出调试端点')), 30_000);
    child.stderr.on('data', chunk => {
      buffer += chunk.toString();
      const match = buffer.match(/ws:\/\/127\.0\.0\.1:(\d+)\/devtools\/browser\/[\w-]+/);
      if (match) { clearTimeout(timer); resolve({ port: match[1] }); }
    });
    child.on('exit', code => { clearTimeout(timer); reject(new Error(`Chrome 提前退出，code=${code}`)); });
  });

  return {
    child,
    port: endpoint.port,
    dispose() {
      try { child.kill('SIGTERM'); } catch { /* 已退出 */ }
      try { rmSync(profile, { recursive: true, force: true }); } catch { /* 忽略 */ }
    }
  };
}

async function openPage(port) {
  const response = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' });
  const target = await response.json();
  const session = new DevToolsSession(target.webSocketDebuggerUrl);
  await session.ready;
  await session.send('Page.enable');
  await session.send('Runtime.enable');
  return { session, targetId: target.id };
}

async function navigate(session, url) {
  await session.send('Page.navigate', { url });
  // 轮询 readyState 比等 loadEventFired 稳：渐进式切页会在同一文档里换内容。
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const state = await session.evaluate('document.readyState', { awaitPromise: false });
    if (state === 'complete') return;
    await sleep(100);
  }
  throw new Error(`页面未在 10 秒内完成加载: ${url}`);
}

/**
 * 页面内安装的采集器。它必须在导航之前挂上，否则 `waiting`/`stalled` 与
 * 长任务会在装监听之前就发生过——那正是首帧阶段最需要看的一段。
 */
const COLLECTOR_SOURCE = `
(() => {
  if (window.__medialibBaseline) return 'already-installed';
  const state = {
    events: [],
    waiting: { count: 0, totalMs: 0, openedAt: null },
    stalled: { count: 0, totalMs: 0, openedAt: null },
    longTasks: { count: 0, totalMs: 0, longestMs: 0 },
    seeks: [],
    startedAt: 0,
    media: null
  };
  window.__medialibBaseline = state;

  try {
    new PerformanceObserver(list => {
      for (const entry of list.getEntries()) {
        state.longTasks.count += 1;
        state.longTasks.totalMs += entry.duration;
        state.longTasks.longestMs = Math.max(state.longTasks.longestMs, entry.duration);
      }
    }).observe({ type: 'longtask', buffered: true });
  } catch (_) { /* 该浏览器不支持 longtask */ }

  const mark = name => {
    if (state.events.some(entry => entry.name === name)) return;
    state.events.push({ name, at: performance.now() - state.startedAt });
  };

  state.attach = media => {
    if (state.media === media) return;
    state.media = media;
    state.startedAt = performance.now();
    for (const name of ['loadedmetadata', 'loadeddata', 'canplay', 'playing', 'pause', 'ended', 'error']) {
      media.addEventListener(name, () => mark(name));
    }
    media.addEventListener('waiting', () => {
      state.waiting.count += 1;
      state.waiting.openedAt = performance.now();
    });
    media.addEventListener('stalled', () => {
      state.stalled.count += 1;
      state.stalled.openedAt = performance.now();
    });
    const closeGap = key => {
      const gap = state[key];
      if (gap.openedAt === null) return;
      gap.totalMs += performance.now() - gap.openedAt;
      gap.openedAt = null;
    };
    media.addEventListener('playing', () => { closeGap('waiting'); closeGap('stalled'); });
    media.addEventListener('seeked', () => { closeGap('waiting'); closeGap('stalled'); });
  };

  return 'installed';
})();
`;

/** 首帧：优先用 requestVideoFrameCallback，拿不到时退回 timeupdate 的首次推进。 */
const FIRST_FRAME_SOURCE = `
new Promise(resolve => {
  const media = document.querySelector('video, audio');
  if (!media) return resolve(null);
  const startedAt = performance.now();
  if (typeof media.requestVideoFrameCallback === 'function') {
    media.requestVideoFrameCallback(() => resolve({ ms: performance.now() - startedAt, source: 'requestVideoFrameCallback' }));
  } else {
    const onUpdate = () => {
      if (media.currentTime <= 0) return;
      media.removeEventListener('timeupdate', onUpdate);
      resolve({ ms: performance.now() - startedAt, source: 'timeupdate' });
    };
    media.addEventListener('timeupdate', onUpdate);
  }
  setTimeout(() => resolve(null), 15000);
});
`;

async function installCollector(session) {
  await session.send('Page.addScriptToEvaluateOnNewDocument', { source: COLLECTOR_SOURCE });
}

async function logIn(session, options) {
  await navigate(session, `${options.server}/login`);
  const submitted = await session.evaluate(`
    (() => {
      const form = document.querySelector('form');
      const username = document.querySelector('input[name="username"]');
      const password = document.querySelector('input[name="password"]');
      if (!form || !username || !password) return 'missing-form';
      username.value = ${JSON.stringify(options.username)};
      password.value = ${JSON.stringify(options.password)};
      username.dispatchEvent(new Event('input', { bubbles: true }));
      password.dispatchEvent(new Event('input', { bubbles: true }));
      const button = form.querySelector('button[type="submit"], button:not([type])');
      if (button) button.click(); else form.submit();
      return 'submitted';
    })();
  `, { awaitPromise: false });
  if (submitted !== 'submitted') throw new Error(`登录表单不可用: ${submitted}`);

  for (let attempt = 0; attempt < 100; attempt += 1) {
    await sleep(150);
    const path = await session.evaluate('window.location.pathname', { awaitPromise: false });
    if (path && path !== '/login') return path;
  }
  throw new Error('登录后 15 秒内未离开 /login');
}

/** 一个样本的完整流程：点击播放 → 暂停 → 恢复 → 多次 seek → 读取统计。 */
async function measureSample(session, options, item) {
  const url = `${options.server}/play/${encodeURIComponent(item.itemID)}#play`;
  await navigate(session, url);

  await session.evaluate(`
    (() => {
      const media = document.querySelector('video, audio');
      if (media && window.__medialibBaseline) window.__medialibBaseline.attach(media);
      // Capture only HLS.js's documented enum-like error fields. They contain
      // no media URL, token, path, response body, or stack trace, but explain
      // why a stream that ffprobe accepts may still fail in MSE.
      if (window.Hls && !window.__medialibHLSInstrumented) {
        window.__medialibHLSInstrumented = true;
        window.__medialibHLSErrors = [];
        const originalTrigger = window.Hls.prototype.trigger;
        window.Hls.prototype.trigger = function(event, data) {
          if (event === window.Hls.Events.ERROR) {
            window.__medialibHLSErrors.push({
              type:typeof data?.type === 'string' ? data.type.slice(0, 80) : null,
              details:typeof data?.details === 'string' ? data.details.slice(0, 120) : null,
              fatal:data?.fatal === true
            });
          }
          return originalTrigger.call(this, event, data);
        };
      }
      if (!window.__medialibPlaybackFetchInstrumented) {
        window.__medialibPlaybackFetchInstrumented = true;
        window.__medialibPlaybackSessionRequests = [];
        const originalFetch = window.fetch.bind(window);
        window.fetch = async (...args) => {
          const request = args[0];
          const url = typeof request === 'string' ? request : String(request?.url || '');
          const method = String(args[1]?.method || request?.method || 'GET').toUpperCase();
          const response = await originalFetch(...args);
          if (url === '/api/v1/playback/sessions' && method === 'POST') {
            const entry = { status:response.status, mode:null, state:null };
            try {
              const payload = await response.clone().json();
              entry.mode = typeof payload?.mode === 'string' ? payload.mode.slice(0, 80) : null;
              entry.state = typeof payload?.state === 'string' ? payload.state.slice(0, 80) : null;
            } catch (_) { /* status alone remains useful */ }
            window.__medialibPlaybackSessionRequests.push(entry);
          }
          return response;
        };
      }
      return !!media;
    })();
  `, { awaitPromise: false });

  // 播放页刻意不自动开播（`#play` 只负责带到页面），所以基线必须真的按下那颗
  // 按钮。服务端声明的 MIME 与浏览器 MediaCapabilities 的判断一并记下来，
  // 让"没播成"能被解释成一个具体原因，而不是一句"失败"。
  const decision = await session.evaluate(`
    (() => {
      const button = document.getElementById('direct-play');
      const contentType = document.body.dataset.browserContentType || '';
      return {
        hasStartButton: Boolean(button),
        startButtonDisabled: button ? button.disabled : null,
        declaredContentType: contentType,
        canPlayTypeVerdict: contentType
          ? (document.querySelector('video, audio')?.canPlayType(contentType) || 'no-support')
          : 'no-declared-type',
        statusText: (document.getElementById('player-status')?.textContent || '').trim().slice(0, 160)
      };
    })();
  `, { awaitPromise: false });

  const clickedAt = Date.now();
  const startMode = await session.evaluate(`
    (() => {
      const button = document.getElementById('direct-play');
      if (button && !button.disabled) { button.click(); return 'clicked-direct-play'; }
      if (button) return 'direct-play-disabled';
      return 'no-direct-play-button';
    })();
  `, { awaitPromise: false });

  const playing = startMode !== 'clicked-direct-play'
    ? { ok: false, reason: startMode }
    : await session.evaluate(`
    new Promise(resolve => {
      const media = document.querySelector('video, audio');
      if (!media) return resolve({ ok: false, reason: 'no-media-element' });
      if (!media.paused && media.readyState >= 3) return resolve({ ok: true });
      const done = ok => resolve({ ok, reason: ok ? undefined : (media.error ? 'media-error-' + media.error.code : 'timeout') });
      media.addEventListener('playing', () => done(true), { once: true });
      media.addEventListener('error', () => done(false), { once: true });
      setTimeout(() => done(false), 12000);
    });
  `);

  const firstFrame = playing.ok ? await session.evaluate(FIRST_FRAME_SOURCE) : null;
  // `playing` alone is not proof of usable playback: browsers may decode the
  // video while silently rejecting TrueHD/DTS. Wait for the page's bounded
  // negotiation marker and record the actual authenticated HLS mode.
  const negotiatedPlayback = playing.ok ? await session.evaluate(`
    new Promise(resolve => {
      const media = document.querySelector('video, audio');
      const startedAt = performance.now();
      const read = () => ({
        playbackMode: media?.dataset.playbackMode || null,
        serverPlaybackMode: media?.dataset.serverPlaybackMode || null,
        sourceRevision: Number(media?.dataset.sourceRevision || 0) || 0
      });
      const poll = () => {
        const value = read();
        if (value.serverPlaybackMode || performance.now() - startedAt >= 1500) return resolve(value);
        setTimeout(poll, 50);
      };
      poll();
    });
  `) : null;
  const events = await session.evaluate('window.__medialibBaseline?.events ?? []', { awaitPromise: false });

  let pauseResumeOK = null;
  let seekSummary = null;
  if (playing.ok) {
    pauseResumeOK = await session.evaluate(`
      new Promise(async resolve => {
        const media = document.querySelector('video, audio');
        media.pause();
        await new Promise(r => setTimeout(r, 250));
        const paused = media.paused;
        const play = media.play();
        if (play && typeof play.catch === 'function') play.catch(() => {});
        await new Promise(r => setTimeout(r, 400));
        resolve(paused && !media.paused);
      });
    `);

    seekSummary = await session.evaluate(`
      new Promise(async resolve => {
        const media = document.querySelector('video, audio');
        const seekControl = document.getElementById('playback-seek');
        const durations = [];
        const attempts = [];
        const controlMaximum = Number(seekControl?.max || 0);
        const total = Number.isFinite(controlMaximum) && controlMaximum > 0
          ? controlMaximum
          : (Number.isFinite(media.duration) && media.duration > 0 ? media.duration : 4);
        for (let index = 0; index < ${options.seekCount}; index += 1) {
          // 在片长内均匀取点并错开，避免每次都落在同一个已缓冲区间上。
          const target = ((index + 1) / (${options.seekCount} + 1)) * total;
          const startedAt = performance.now();
          const initialRevision = Number(media.dataset.sourceRevision || 0) || 0;
          const hlsMode = media.dataset.playbackMode === 'hls';
          const settled = await new Promise(done => {
            let finished = false;
            const finish = value => {
              if (finished) return;
              finished = true;
              media.removeEventListener('seeked', onSeeked);
              media.removeEventListener('playing', onPlaying);
              done(value);
            };
            const onSeeked = () => { if (!hlsMode) finish(true); };
            const onPlaying = () => {
              const revision = Number(media.dataset.sourceRevision || 0) || 0;
              if (hlsMode && revision > initialRevision) finish(true);
            };
            media.addEventListener('seeked', onSeeked);
            media.addEventListener('playing', onPlaying);
            if (seekControl) {
              seekControl.value = String(target);
              seekControl.dispatchEvent(new Event('input', { bubbles:true }));
              seekControl.dispatchEvent(new Event('change', { bubbles:true }));
            } else {
              media.currentTime = target;
            }
            const poll = () => {
              if (finished) return;
              const revision = Number(media.dataset.sourceRevision || 0) || 0;
              if (hlsMode && revision > initialRevision && media.readyState >= 2) return finish(true);
              setTimeout(poll, 50);
            };
            poll();
            setTimeout(() => finish(false), 12000);
          });
          const elapsed = performance.now() - startedAt;
          attempts.push({
            target:Number(target.toFixed(3)),
            settled,
            elapsedMs:Math.round(elapsed),
            initialRevision,
            finalRevision:Number(media.dataset.sourceRevision || 0) || 0,
            readyState:media.readyState,
            paused:media.paused,
            statusText:(document.getElementById('player-status')?.textContent || '').trim().slice(0, 160),
            sessionRequests:Array.isArray(window.__medialibPlaybackSessionRequests)
              ? window.__medialibPlaybackSessionRequests.slice(-4) : []
          });
          if (settled) durations.push(elapsed);
          await new Promise(r => setTimeout(r, 120));
        }
        durations.sort((a, b) => a - b);
        const at = ratio => durations.length
          ? Math.round(durations[Math.min(durations.length - 1, Math.floor(durations.length * ratio))])
          : null;
        resolve({ completed: durations.length, attempted: ${options.seekCount}, p50Ms: at(0.5), p95Ms: at(0.95), attempts });
      });
    `);
  }

  // A newly swapped HLS source can deliver its first video frame before the
  // browser updates the audio decoded-byte counter. Give the decoder one small
  // observation window so a successful seek is not mislabeled as silent.
  if (playing.ok) await sleep(750);

  // Chromium's non-standard webkitAudioDecodedByteCount can reset to zero
  // after an MSE source replacement. Sample the actual media-element PCM as a
  // second, independent signal: a sine-wave fixture must produce measurable
  // deviation from digital silence. No samples leave the page.
  const audioSignal = playing.ok ? await session.evaluate(`
    (async () => {
      const media = document.querySelector('video, audio');
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!media || !AudioContextClass) return { supported:false, reason:'audio-context-unavailable' };
      try {
        const context = new AudioContextClass();
        const analyser = context.createAnalyser();
        analyser.fftSize = 2048;
        const source = context.createMediaElementSource(media);
        source.connect(analyser);
        analyser.connect(context.destination);
        await context.resume();
        if (media.paused) await media.play();
        const values = new Uint8Array(analyser.fftSize);
        let peakDeviation = 0;
        let rmsMaximum = 0;
        for (let attempt = 0; attempt < 20; attempt += 1) {
          analyser.getByteTimeDomainData(values);
          let squared = 0;
          for (const value of values) {
            const deviation = value - 128;
            peakDeviation = Math.max(peakDeviation, Math.abs(deviation));
            squared += deviation * deviation;
          }
          rmsMaximum = Math.max(rmsMaximum, Math.sqrt(squared / values.length));
          if (peakDeviation > 2 && rmsMaximum > 0.5) break;
          await new Promise(resolve => setTimeout(resolve, 50));
        }
        await context.close();
        return {
          supported:true,
          audible:peakDeviation > 2 && rmsMaximum > 0.5,
          peakDeviation,
          rmsMaximum:Number(rmsMaximum.toFixed(2))
        };
      } catch (error) {
        return { supported:false, reason:String(error?.name || 'audio-probe-failed').slice(0, 80) };
      }
    })();
  `) : null;

  // 解码字节数把"视频能解、音频不能解"这类部分成功区分出来。只看 `playing`
  // 会把一个没有声音的播放当成完全成功——那恰好是"仅转音频"那一层要处理的场景。
  const quality = await session.evaluate(`
    (() => {
      const media = document.querySelector('video, audio');
      if (!media) return null;
      const q = typeof media.getVideoPlaybackQuality === 'function'
        ? media.getVideoPlaybackQuality() : null;
      return {
        totalVideoFrames: q ? q.totalVideoFrames : null,
        droppedVideoFrames: q ? q.droppedVideoFrames : null,
        videoDecodedBytes: media.webkitVideoDecodedByteCount ?? null,
        audioDecodedBytes: media.webkitAudioDecodedByteCount ?? null
      };
    })();
  `, { awaitPromise: false });

  const collected = await session.evaluate(`
    (() => {
      const state = window.__medialibBaseline;
      if (!state) return null;
      const media = document.querySelector('video, audio');
      return {
        waiting: { count: state.waiting.count, totalMs: Math.round(state.waiting.totalMs) },
        stalled: { count: state.stalled.count, totalMs: Math.round(state.stalled.totalMs) },
        longTasks: {
          count: state.longTasks.count,
          totalMs: Math.round(state.longTasks.totalMs),
          longestMs: Math.round(state.longTasks.longestMs)
        },
        heapBytes: performance.memory ? performance.memory.usedJSHeapSize : null,
        mediaError: media?.error ? media.error.code : null,
        readyState: media?.readyState ?? null,
        finalStatusText:(document.getElementById('player-status')?.textContent || '').trim().slice(0, 160),
        hlsErrors:Array.isArray(window.__medialibHLSErrors)
          ? window.__medialibHLSErrors.slice(-12) : []
      };
    })();
  `, { awaitPromise: false });

  const eventTime = name => {
    const entry = events.find(item => item.name === name);
    return entry ? Math.round(entry.at) : null;
  };

  return {
    file: item.file,
    itemID: item.itemID,
    startMode,
    decision,
    directPlayed: playing.ok,
    failureReason: playing.ok ? null : playing.reason,
    clickToLoadedMetadataMs: eventTime('loadedmetadata'),
    clickToPlayingMs: eventTime('playing'),
    firstFrameMs: firstFrame ? Math.round(firstFrame.ms) : null,
    firstFrameSource: firstFrame ? firstFrame.source : null,
    negotiatedPlayback,
    audioSignal,
    pauseResumeOK,
    seek: seekSummary,
    quality,
    ...collected,
    wallClockMs: Date.now() - clickedAt
  };
}

/** 自动下一集：由服务端授权的下一集地址驱动，不接受前端自造的跳转。 */
async function measureAutoNext(session, options, episodeIDs) {
  if (episodeIDs.length < 2) return { supported: false, reason: 'fixture-has-fewer-than-two-episodes' };
  await navigate(session, `${options.server}/play/${encodeURIComponent(episodeIDs[0])}#play`);
  const probe = await session.evaluate(`
    (() => {
      const explicit = document.body.dataset.nextEpisodePath || '';
      if (!explicit) return { href: null };
      // 只报告形状，不把不透明 ID 写进报告：报告会被贴进交接文档。
      return {
        href: explicit,
        shape: explicit.replace(/\\/[^/]+$/, '/<opaque-id>'),
        hasQuery: explicit.includes('?'),
        isAbsolute: /^https?:/i.test(explicit),
        hasAutomaticNextControl: Boolean(document.getElementById('automatic-next'))
      };
    })();
  `, { awaitPromise: false });
  if (!probe.href) {
    return { supported: false, reason: 'no-server-authorized-next-episode' };
  }
  // 自动下一集勾选后应真的跳到服务端授权的下一集。
  //
  // 判定必须在页面**之外**做：续播是一次真实导航，任何跨越它的页内 Promise 都会
  // 被 CDP 以 "target navigated" 中断，那看起来像失败，其实恰恰是成功。
  const startedPath = await session.evaluate('window.location.pathname', { awaitPromise: false });
  await session.evaluate(`
    (() => {
      const toggle = document.getElementById('automatic-next');
      const button = document.getElementById('direct-play');
      if (!toggle || !button) return 'missing-controls';
      toggle.checked = true;
      toggle.dispatchEvent(new Event('change', { bubbles: true }));
      button.click();
      const media = document.querySelector('video, audio');
      if (media) {
        media.addEventListener('playing', () => {
          if (Number.isFinite(media.duration) && media.duration > 0) {
            media.currentTime = Math.max(0, media.duration - 0.3);
          }
        }, { once: true });
      }
      return 'armed';
    })();
  `, { awaitPromise: false });

  let advanced = { ok: false, reason: 'did-not-advance-within-25s' };
  const deadline = Date.now() + 25_000;
  while (Date.now() < deadline) {
    await sleep(400);
    let path;
    try {
      path = await session.evaluate('window.location.pathname', { awaitPromise: false, timeoutMs: 5_000 });
    } catch {
      // 正在导航中，下一轮再读。
      continue;
    }
    if (path && path !== startedPath) { advanced = { ok: true, leftStartingItem: true }; break; }
  }
  return {
    supported: true,
    nextPathShape: probe.shape,
    nextIsSameOriginNoQuery: !probe.hasQuery && !probe.isAbsolute,
    hasAutomaticNextControl: probe.hasAutomaticNextControl,
    advanced
  };
}

/** 离页续播：播到中途离开，再回来看服务端是否记住了位置。 */
async function measureResumeAcrossNavigation(session, options, itemID) {
  await navigate(session, `${options.server}/play/${encodeURIComponent(itemID)}#play`);
  const played = await session.evaluate(`
    new Promise(resolve => {
      const media = document.querySelector('video, audio');
      if (!media) return resolve(null);
      const play = media.play();
      if (play && typeof play.catch === 'function') play.catch(() => {});
      setTimeout(() => {
        media.currentTime = Math.max(1, (media.duration || 4) * 0.5);
        setTimeout(() => resolve(media.currentTime), 1200);
      }, 800);
    });
  `);
  // 播放状态写入是 15 秒节流的，离页前必须给它一次真正的落盘机会。
  await sleep(2_000);
  await navigate(session, `${options.server}/library`);
  await sleep(500);
  await navigate(session, `${options.server}/play/${encodeURIComponent(itemID)}#play`);
  const resumed = await session.evaluate(`
    new Promise(resolve => {
      const media = document.querySelector('video, audio');
      if (!media) return resolve(null);
      const read = () => resolve({
        resumePosition: Number(document.body.dataset.resumePosition || 0),
        currentTime: media.currentTime
      });
      if (media.readyState >= 1) return read();
      media.addEventListener('loadedmetadata', read, { once: true });
      setTimeout(() => read(), 6000);
    });
  `);
  return { positionBeforeLeaving: played, afterReturning: resumed };
}

async function fetchTelemetry(session, options) {
  return session.evaluate(`
    fetch('${options.server}/api/v1/admin/playback-telemetry', { credentials: 'same-origin' })
      .then(response => response.ok ? response.json() : ({ error: response.status }))
      .catch(error => ({ error: String(error) }));
  `);
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (!options.password) throw new Error('必须提供 --password');
  if (!options.manifest) throw new Error('必须提供 --manifest');
  const manifest = JSON.parse(readFileSync(options.manifest, 'utf8'));

  const chrome = await launchChrome(options);
  let session;
  try {
    const page = await openPage(chrome.port);
    session = page.session;
    await installCollector(session);

    const landing = await logIn(session, options);
    console.log(`已登录，落地页 ${landing}`);

    const samples = [];
    for (const item of manifest.items) {
      process.stdout.write(`  测量 ${item.file} … `);
      try {
        const measurement = await measureSample(session, options, item);
        samples.push(measurement);
        console.log(measurement.directPlayed
          ? `${measurement.negotiatedPlayback?.serverPlaybackMode || measurement.negotiatedPlayback?.playbackMode || '播放'}成功 首帧 ${measurement.firstFrameMs ?? '-'}ms`
          : `未直放（${measurement.failureReason}）`);
      } catch (error) {
        samples.push({ file: item.file, itemID: item.itemID, harnessError: String(error.message ?? error) });
        console.log(`夹具错误: ${error.message ?? error}`);
      }
    }

    const autoNext = options.samplesOnly
      ? { supported: false, reason: 'samples-only' }
      : await measureAutoNext(session, options, manifest.episodeItemIDs ?? []);
    const resume = options.samplesOnly
      ? { supported: false, reason: 'samples-only' }
      : await measureResumeAcrossNavigation(session, options, manifest.items[0]?.itemID ?? '');
    const telemetry = await fetchTelemetry(session, options);

    const report = {
      capturedAt: new Date().toISOString(),
      browser: 'chromium',
      headless: options.headless,
      samples,
      autoNext,
      resumeAcrossNavigation: resume,
      serverTelemetry: telemetry
    };
    if (options.out) {
      writeFileSync(options.out, JSON.stringify(report, null, 2));
      console.log(`\n报告已写入 ${options.out}`);
    }

    console.log('\n样本结果：');
    for (const sample of samples) {
      if (sample.harnessError) {
        console.log(`  ${sample.file.padEnd(28)} 夹具错误 ${sample.harnessError}`);
        continue;
      }
      const seek = sample.seek ? `seek p50=${sample.seek.p50Ms}ms p95=${sample.seek.p95Ms}ms` : 'seek 未执行';
      console.log(
        `  ${sample.file.padEnd(28)} ${sample.directPlayed ? (sample.negotiatedPlayback?.serverPlaybackMode || sample.negotiatedPlayback?.playbackMode || '播放') : '未播放'} ` +
        `metadata=${sample.clickToLoadedMetadataMs ?? '-'}ms playing=${sample.clickToPlayingMs ?? '-'}ms ` +
        `firstFrame=${sample.firstFrameMs ?? '-'}ms waiting=${sample.waiting?.count ?? '-'}/${sample.waiting?.totalMs ?? '-'}ms ` +
        `dropped=${sample.quality ? sample.quality.droppedVideoFrames : '-'} ${seek}`
      );
    }

    // 只看 `playing` 会把"画面在动但一点声音都没有"记成完全成功。把它单独点出来，
    // 因为这正是四级策略里"仅转音频"那一层要解决的场景。
    const silentVideo = samples.filter(sample =>
      sample.directPlayed && sample.negotiatedPlayback?.playbackMode === 'direct' &&
        sample.quality?.audioDecodedBytes === 0 && sample.quality?.videoDecodedBytes > 0
    );
    if (silentVideo.length > 0) {
      console.log('\n视频已解码但音频完全未解码（直放看似成功，实际无声）：');
      for (const sample of silentVideo) console.log(`  ${sample.file}`);
    }

    const harnessFailures = samples.filter(sample => sample.harnessError);
    process.exitCode = harnessFailures.length > 0 ? 1 : 0;
  } finally {
    session?.close();
    chrome.dispose();
  }
}

main().catch(error => {
  console.error(`基线采集失败: ${error.message ?? error}`);
  process.exit(1);
});
