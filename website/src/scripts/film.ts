import { gsap } from 'gsap';
import type Lenis from 'lenis';
import { all, clamp, footageWidth, isSmall, one } from './dom';
import { swapWords } from './prune';

type Cam = [number, number, number];
interface CamSet { d: [Cam, Cam]; m: [Cam, Cam] }
interface Chapter {
  id: string;
  el: HTMLElement;
  cam: CamSet;
  layer: HTMLImageElement | HTMLVideoElement | null;
  start: number;
}

const SPAN = 1; // timeline units per chapter
const LEAD = 0.4; // intro before the first chapter settles

/**
 * The tour: one pinned stage, one app window. As you scroll, the window plays the real footage at the
 * scroll position, the camera moves to the part being discussed, and the copy changes word by word.
 */
export function initFilm(lenis: Lenis | null): void {
  const film = one('[data-film]');
  const stage = one('[data-film-stage]');
  const lens = one('[data-lens]');
  const device = one('[data-device]');
  if (!film || !stage || !lens || !device) return;

  const chapters: Chapter[] = all('[data-chapter]', film).map((el, i) => {
    const id = el.dataset.chapter ?? '';
    return {
      id,
      el,
      cam: JSON.parse(el.dataset.cam ?? '{}') as CamSet,
      layer: one<HTMLImageElement | HTMLVideoElement>(`[data-layer="${id}"]`, device),
      start: LEAD + i * SPAN,
    };
  });
  if (!chapters.length) return;
  const total = LEAD + chapters.length * SPAN;

  // Media: posters first, then the clips once the tour is near. The width is chosen from the largest
  // size the camera shows the window at, so a zoom never stretches a smaller file.
  const largestCss = () => {
    const lensW = lens.clientWidth;
    const lensH = lens.clientHeight;
    const fit = isSmall() ? lensW : Math.min(lensW * 0.6, lensH * 0.74 * 1.6);
    const maxS = Math.max(...chapters.flatMap((c) => (isSmall() ? c.cam.m : c.cam.d).map((v) => v[0])));
    return fit * maxS;
  };
  const width = footageWidth(largestCss());
  const videos = chapters.map((c) => c.layer).filter((l): l is HTMLVideoElement => l instanceof HTMLVideoElement);
  let mediaLoaded = false;
  const loadMedia = () => {
    if (mediaLoaded) return;
    mediaLoaded = true;
    for (const v of videos) {
      const src = v.dataset.src?.replace('{w}', String(width));
      if (!src) continue;
      v.poster = v.dataset.poster?.replace('{w}', String(width)) ?? '';
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
  let m = { lw: 0, lh: 0, fitW: 0, fitH: 0, ax: 0, ay: 0 };
  const measure = () => {
    const lw = lens.clientWidth;
    const lh = lens.clientHeight;
    if (isSmall()) {
      const fitW = lw;
      m = { lw, lh, fitW, fitH: fitW / 1.6, ax: lw / 2, ay: lh / 2 };
    } else {
      const fitW = Math.min(lw * 0.6, lh * 0.74 * 1.6);
      m = { lw, lh, fitW, fitH: fitW / 1.6, ax: lw * 0.665, ay: lh * 0.5 + 18 };
    }
    device.style.width = `${m.fitW}px`;
  };
  const cam = { s: 1, fx: 0.5, fy: 0.5 };
  const applyCam = () => {
    const w = m.fitW * cam.s;
    const h = m.fitH * cam.s;
    const x = m.ax - cam.fx * w;
    const y = m.ay - cam.fy * h;
    device.style.transform = `translate3d(${x.toFixed(2)}px, ${y.toFixed(2)}px, 0) scale(${cam.s.toFixed(4)})`;
  };
  measure();

  const camOf = (c: Chapter, which: 0 | 1): { s: number; fx: number; fy: number } => {
    const v = (isSmall() ? c.cam.m : c.cam.d)[which];
    return { s: v[0], fx: v[1], fy: v[2] };
  };

  // Things driven by the timeline position: video time, list highlights, the rail.
  const railLinks = all<HTMLButtonElement>('[data-rail-link]', film);
  const railFill = one('[data-rail-fill]', film);
  const evidence = chapters.find((c) => c.id === 'evidence');
  const agents = chapters.find((c) => c.id === 'agents');
  const evidenceItems = evidence ? all('.list-evidence li', evidence.el) : [];
  const toolItems = agents ? all('.list-tools li', agents.el) : [];
  const targets = new Map<HTMLVideoElement, number>();
  let active = -1;

  function onTime(t: number): void {
    for (const c of chapters) {
      if (!(c.layer instanceof HTMLVideoElement)) continue;
      const local = clamp((t - (c.start - 0.25)) / (SPAN + 0.05));
      const d = c.layer.duration;
      if (Number.isFinite(d) && d > 0) targets.set(c.layer, local * (d - 0.05));
    }
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

  let tl: gsap.core.Timeline | null = null;
  const mm = gsap.matchMedia();
  mm.add('(max-width: 899px)', () => build());
  mm.add('(min-width: 900px)', () => build());

  function build(): void {
    measure();
    // Initial states.
    for (const c of chapters) {
      gsap.set(all('.cw', c.el), { y: 0, yPercent: 140 });
      gsap.set(all('.chapter-body, .chapter-list, .chapter-note', c.el), { opacity: 0, y: 16 });
    }
    if (chapters[0].layer) gsap.set(chapters[0].layer, { opacity: 1 });
    Object.assign(cam, camOf(chapters[0], 0));
    applyCam();

    const line = gsap.timeline({
      defaults: { ease: 'none' },
      scrollTrigger: {
        trigger: film,
        start: 'top top',
        end: 'bottom bottom',
        scrub: 0.45,
        invalidateOnRefresh: true,
        onRefreshInit: () => measure(),
        onRefresh: () => applyCam(),
      },
      onUpdate: () => {
        applyCam();
        onTime(line.time());
      },
    });

    chapters.forEach((c, i) => {
      const T = c.start;
      const prev = chapters[i - 1];
      // copy in
      swapWords(line, null, one('.chapter-title', c.el), T - 0.32);
      line.to(all('.chapter-body, .chapter-list, .chapter-note', c.el), { opacity: 1, y: 0, duration: 0.25, stagger: 0.05, ease: 'power2.out' }, T - 0.02);
      // copy out
      if (i < chapters.length - 1) {
        const outAt = T + SPAN - 0.36;
        swapWords(line, one('.chapter-title', c.el), null, outAt);
        line.to(all('.chapter-body, .chapter-list, .chapter-note', c.el), { opacity: 0, y: -12, duration: 0.18, ease: 'power2.in' }, outAt);
      }
      // camera: travel from the previous chapter, then a slow move inside this one
      if (prev) {
        line.fromTo(cam, camOf(prev, 1), { ...camOf(c, 0), duration: 0.3, ease: 'power2.inOut', immediateRender: false }, T - 0.3);
        if (prev.layer && c.layer) {
          // a wipe, not a cross-fade: two app screens blended together read as mud
          line.fromTo(c.layer, { opacity: 1, clipPath: 'inset(0% 0% 0% 100%)' }, { clipPath: 'inset(0% 0% 0% 0%)', duration: 0.24, ease: 'power2.inOut', immediateRender: false }, T - 0.27);
          line.fromTo(prev.layer, { opacity: 1 }, { opacity: 0, duration: 0.01, immediateRender: false }, T - 0.02);
        }
      }
      line.fromTo(cam, camOf(c, 0), { ...camOf(c, 1), duration: SPAN - 0.38, ease: 'power1.inOut', immediateRender: false }, T);
    });
    line.to({}, { duration: 0.15 }, total);
    tl = line;
  }

  // Seek videos toward their targets, one seek at a time so frames never queue up.
  let raf = 0;
  const seekLoop = () => {
    raf = requestAnimationFrame(seekLoop);
    targets.forEach((time, v) => {
      if (v.readyState < 1 || v.seeking) return;
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

  // iOS paints nothing for a paused video until it has played once.
  for (const v of videos) {
    v.addEventListener('loadeddata', () => {
      const t = targets.get(v);
      if (t !== undefined) v.currentTime = t;
    }, { once: true });
  }

  // Rail links scroll to the chapter instead of jumping to the top of the stage.
  railLinks.forEach((a, i) => {
    a.addEventListener('click', (event) => {
      event.preventDefault();
      const st = tl?.scrollTrigger;
      if (!tl || !st) return;
      const t = chapters[i].start + 0.32;
      const y = st.start + (st.end - st.start) * (t / tl.duration());
      if (lenis) lenis.scrollTo(y, { duration: 1.2 });
      else window.scrollTo({ top: y, behavior: 'smooth' });
    });
  });

  window.addEventListener('resize', () => {
    measure();
    applyCam();
  });
}
