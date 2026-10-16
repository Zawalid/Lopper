import { gsap } from 'gsap';
import type Lenis from 'lenis';
import { all, clamp, footageWidth, isSmall, one } from './dom';

type Cam = [number, number, number];
interface CamSet { d: [Cam, Cam]; m: [Cam, Cam] }
interface Chapter {
  id: string;
  el: HTMLElement;
  cam: CamSet;
  /** The layer in the app window: an image, or a wrapper holding a still and a video. */
  layer: HTMLElement | null;
  video: HTMLVideoElement | null;
  words: HTMLElement[];
  extras: HTMLElement[];
  start: number;
}

const SPAN = 1; // timeline units per chapter
const LEAD = 0.4; // intro before the first chapter settles
const TAIL = 0.15;

const easeInOut2 = gsap.parseEase('power2.inOut');
const easeInOut1 = gsap.parseEase('power1.inOut');
const easeOut3 = gsap.parseEase('power3.out');
const easeOut2 = gsap.parseEase('power2.out');
const easeIn2 = gsap.parseEase('power2.in');
const mix = (a: number, b: number, p: number) => a + (b - a) * p;

/**
 * The tour: one pinned stage, one app window. As you scroll, the window plays the real footage at the
 * scroll position, the camera moves to the part being discussed, and the copy changes word by word.
 *
 * Everything on the stage is a pure function of the scroll position (render(t) below), never the result
 * of tweens having played in order. Jumping with the chapter rail, End and Home, Page Down or a fast
 * fling lands on exactly the same picture as scrolling there slowly.
 */
export function initFilm(lenis: Lenis | null): void {
  const film = one('[data-film]');
  const stage = one('[data-film-stage]');
  const lens = one('[data-lens]');
  const device = one('[data-device]');
  if (!film || !stage || !lens || !device) return;

  const chapters: Chapter[] = all('[data-chapter]', film).map((el, i) => {
    const id = el.dataset.chapter ?? '';
    const layer = one(`[data-layer="${id}"]`, device);
    return {
      id,
      el,
      cam: JSON.parse(el.dataset.cam ?? '{}') as CamSet,
      layer,
      video: layer ? one<HTMLVideoElement>('video', layer) : null,
      words: all('.cw', el),
      extras: all('.chapter-body, .chapter-list, .chapter-note', el),
      start: LEAD + i * SPAN,
    };
  });
  if (!chapters.length) return;
  const total = LEAD + chapters.length * SPAN + TAIL;

  // Media: the clips load once the tour is near. The width is chosen from the largest size the camera
  // shows the window at, so a zoom never stretches a smaller file. Under every video sits a still of
  // the same screen, so the window is never empty while a clip loads, seeks, or fails.
  const largestCss = () => {
    const lensW = lens.clientWidth;
    const lensH = lens.clientHeight;
    const fit = isSmall() ? lensW : Math.min(lensW * 0.6, lensH * 0.74 * 1.6);
    const maxS = Math.max(...chapters.flatMap((c) => (isSmall() ? c.cam.m : c.cam.d).map((v) => v[0])));
    return fit * maxS;
  };
  const width = footageWidth(largestCss());
  const videos = chapters.map((c) => c.video).filter((v): v is HTMLVideoElement => v !== null);
  for (const v of videos) {
    v.addEventListener('error', () => { v.hidden = true; });
  }
  let mediaLoaded = false;
  const loadMedia = () => {
    if (mediaLoaded) return;
    mediaLoaded = true;
    for (const v of videos) {
      const src = v.dataset.src?.replace('{w}', String(width));
      if (!src) continue;
      v.preload = 'auto';
      v.src = src;
      v.load();
    }
  };
  new IntersectionObserver((entries, io) => {
    if (entries.some((e) => e.isIntersecting)) {
      loadMedia();
      io.disconnect();
    }
  }, { rootMargin: '200% 0px' }).observe(film);

  // Camera geometry.
  let m = { fitW: 0, fitH: 0, ax: 0, ay: 0 };
  const measure = () => {
    const lw = lens.clientWidth;
    const lh = lens.clientHeight;
    if (isSmall()) {
      m = { fitW: lw, fitH: lw / 1.6, ax: lw / 2, ay: lh / 2 };
    } else {
      const fitW = Math.min(lw * 0.6, lh * 0.74 * 1.6);
      m = { fitW, fitH: fitW / 1.6, ax: lw * 0.665, ay: lh * 0.5 + 18 };
    }
    device.style.width = `${m.fitW}px`;
  };
  const camOf = (c: Chapter, which: 0 | 1): Cam => (isSmall() ? c.cam.m : c.cam.d)[which];
  const camAt = (t: number): Cam => {
    let cam = camOf(chapters[0], 0);
    for (let i = 0; i < chapters.length; i++) {
      const c = chapters[i];
      const T = c.start;
      const prev = chapters[i - 1];
      if (prev && t >= T - 0.3 && t < T) {
        const a = camOf(prev, 1);
        const b = camOf(c, 0);
        const p = easeInOut2((t - (T - 0.3)) / 0.3);
        return [mix(a[0], b[0], p), mix(a[1], b[1], p), mix(a[2], b[2], p)];
      }
      if (t >= T) {
        const a = camOf(c, 0);
        const b = camOf(c, 1);
        const p = easeInOut1(clamp((t - T) / (SPAN - 0.38)));
        cam = [mix(a[0], b[0], p), mix(a[1], b[1], p), mix(a[2], b[2], p)];
      }
    }
    return cam;
  };
  const applyCam = (cam: Cam) => {
    const [s, fx, fy] = cam;
    const x = m.ax - fx * m.fitW * s;
    const y = m.ay - fy * m.fitH * s;
    device.style.transform = `translate3d(${x.toFixed(2)}px, ${y.toFixed(2)}px, 0) scale(${s.toFixed(4)})`;
  };
  measure();

  // Things driven by the position: layers, copy, video time, list highlights, the rail.
  const railLinks = all<HTMLButtonElement>('[data-rail-link]', film);
  const railFill = one('[data-rail-fill]', film);
  const evidence = chapters.find((c) => c.id === 'evidence');
  const agents = chapters.find((c) => c.id === 'agents');
  const evidenceItems = evidence ? all('.list-evidence li', evidence.el) : [];
  const toolItems = agents ? all('.list-tools li', agents.el) : [];
  const targets = new Map<HTMLVideoElement, number>();
  let active = -1;
  let current = 0;

  /** How far the wipe that brings chapter i into the window has gone, 0 to 1. */
  const wipe = (i: number, t: number) => (i === 0 ? 1 : easeInOut2(clamp((t - (chapters[i].start - 0.27)) / 0.24)));

  function render(t: number): void {
    current = t;
    applyCam(camAt(t));

    chapters.forEach((c, i) => {
      const last = i === chapters.length - 1;

      // The layer: wiped in from the right, then hidden once the next one fully covers it.
      if (c.layer) {
        const p = wipe(i, t);
        const covered = !last && wipe(i + 1, t) >= 1;
        const shown = p > 0 && !covered;
        c.layer.style.opacity = shown ? '1' : '0';
        c.layer.style.clipPath = p >= 1 ? 'none' : `inset(0% 0% 0% ${((1 - p) * 100).toFixed(2)}%)`;
      }

      // The headline, word by word: in from below, out above.
      const inAt = c.start - 0.1;
      const outAt = c.start + SPAN - 0.36;
      c.words.forEach((w, k) => {
        const pin = easeOut3(clamp((t - (inAt + k * 0.035)) / 0.42));
        const pout = last ? 0 : easeIn2(clamp((t - (outAt + k * 0.025)) / 0.28));
        w.style.transform = `translate3d(0, ${(160 * (1 - pin) - 160 * pout).toFixed(2)}%, 0)`;
      });

      // Body, list and note.
      c.extras.forEach((e, k) => {
        const pin = easeOut2(clamp((t - (c.start - 0.02 + k * 0.05)) / 0.25));
        const pout = last ? 0 : easeIn2(clamp((t - outAt) / 0.18));
        e.style.opacity = (pin * (1 - pout)).toFixed(3);
        e.style.transform = `translate3d(0, ${(16 * (1 - pin) - 12 * pout).toFixed(2)}px, 0)`;
      });

      // Video time follows the position.
      if (c.video) {
        const local = clamp((t - (c.start - 0.25)) / (SPAN + 0.05));
        const d = c.video.duration;
        if (Number.isFinite(d) && d > 0) targets.set(c.video, local * (d - 0.05));
      }
    });

    if (evidence) {
      const p = clamp((t - evidence.start) / (SPAN * 0.6));
      evidenceItems.forEach((li, i) => li.classList.toggle('on', p > (i + 0.5) / evidenceItems.length));
    }
    if (agents) {
      const p = clamp((t - agents.start + 0.05) / (SPAN * 0.62));
      const k = Math.min(toolItems.length - 1, Math.floor(p * toolItems.length));
      toolItems.forEach((li, i) => li.classList.toggle('on', i === k));
    }
    const idx = Math.max(0, Math.min(chapters.length - 1, Math.floor((t - LEAD + 0.35) / SPAN)));
    if (idx !== active) {
      active = idx;
      railLinks.forEach((a, i) => {
        a.classList.toggle('on', i === idx);
        if (i === idx) a.setAttribute('aria-current', 'step');
        else a.removeAttribute('aria-current');
      });
    }
    if (railFill) railFill.style.transform = `scaleX(${clamp(t / total).toFixed(4)})`;
  }

  // The timeline only carries the scroll position (with a little smoothing); render(t) draws it.
  const line = gsap.timeline({
    scrollTrigger: {
      trigger: film,
      start: 'top top',
      end: 'bottom bottom',
      scrub: 0.45,
      onRefreshInit: () => measure(),
      onRefresh: () => render(current),
    },
    onUpdate: () => render(line.time()),
  });
  line.to({}, { duration: total, ease: 'none' }, 0);
  render(0);

  // Seek videos toward their targets, one seek at a time so frames never queue up.
  let raf = 0;
  const seekLoop = () => {
    raf = requestAnimationFrame(seekLoop);
    targets.forEach((time, v) => {
      if (v.readyState < 1 || v.seeking || v.hidden) return;
      if (Math.abs(v.currentTime - time) > 1 / 48) v.currentTime = time;
    });
  };
  new IntersectionObserver((entries) => {
    const on = entries.some((e) => e.isIntersecting);
    if (on && !raf) seekLoop();
    if (!on && raf) {
      cancelAnimationFrame(raf);
      raf = 0;
    }
  }).observe(stage);

  // Once a clip can paint, go straight to the frame for the current position.
  for (const v of videos) {
    v.addEventListener('loadeddata', () => {
      render(current);
      const t = targets.get(v);
      if (t !== undefined) v.currentTime = t;
    }, { once: true });
  }

  // Rail buttons scroll to the chapter.
  railLinks.forEach((a, i) => {
    a.addEventListener('click', () => {
      const st = line.scrollTrigger;
      if (!st) return;
      const t = chapters[i].start + 0.5;
      const y = st.start + (st.end - st.start) * (t / line.duration());
      if (lenis) lenis.scrollTo(y, { duration: 1.2 });
      else window.scrollTo({ top: y, behavior: 'smooth' });
    });
  });

  // Breakpoint changes swap camera sets and lens geometry.
  window.addEventListener('resize', () => {
    measure();
    render(current);
  });
}
