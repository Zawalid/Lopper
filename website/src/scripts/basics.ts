import { all, footageWidth, one } from './dom';

/** Copy buttons next to commands. */
export function initCopy(): void {
  const status = one('[data-copy-status]');
  for (const button of all<HTMLButtonElement>('[data-copy]')) {
    let timer = 0;
    button.addEventListener('click', async () => {
      const text = button.dataset.copy ?? '';
      let ok = false;
      try {
        await navigator.clipboard.writeText(text);
        ok = true;
      } catch {
        const area = document.createElement('textarea');
        area.value = text;
        area.setAttribute('readonly', '');
        area.style.position = 'fixed';
        area.style.opacity = '0';
        document.body.append(area);
        area.select();
        ok = document.execCommand('copy');
        area.remove();
      }
      button.textContent = ok ? 'Copied' : 'Press Command-C';
      button.toggleAttribute('data-copied', ok);
      if (status) status.textContent = ok ? 'Command copied to the clipboard.' : 'Copy failed. Select the command and copy it.';
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        button.textContent = 'Copy';
        button.removeAttribute('data-copied');
      }, 1800);
    });
  }
}

/** FAQ: animate the answer height when motion is allowed. Native details still works without this. */
export function initFaq(motion: boolean): void {
  if (!motion) return;
  for (const details of all<HTMLDetailsElement>('details[data-faq]')) {
    const summary = one<HTMLElement>('summary', details);
    const answer = one<HTMLElement>('.answer', details);
    if (!summary || !answer) continue;
    let anim: Animation | null = null;
    summary.addEventListener('click', (event) => {
      event.preventDefault();
      anim?.cancel();
      const opening = !details.open;
      if (opening) details.open = true;
      const full = answer.scrollHeight;
      anim = answer.animate(
        opening
          ? [{ height: '0px', opacity: 0 }, { height: `${full}px`, opacity: 1 }]
          : [{ height: `${full}px`, opacity: 1 }, { height: '0px', opacity: 0 }],
        { duration: opening ? 420 : 300, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' },
      );
      anim.onfinish = () => {
        if (!opening) details.open = false;
        anim = null;
      };
    });
  }
}

/** Nav: compact once the page moves, Download appears after the hero. */
export function initNav(motion: boolean): void {
  const nav = one('[data-nav]');
  if (!nav) return;
  const heroDownload = one('[data-hero-download]');
  let ticking = false;
  const update = () => {
    ticking = false;
    const y = window.scrollY;
    nav.classList.toggle('is-scrolled', y > 24);
    if (motion) {
      nav.classList.toggle('show-cta', y > window.innerHeight * 0.55);
    } else if (heroDownload) {
      nav.classList.toggle('show-cta', heroDownload.getBoundingClientRect().bottom < 0);
    }
  };
  window.addEventListener('scroll', () => {
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(update);
    }
  }, { passive: true });
  update();
}

/** The hero video: autoplay only when motion is allowed, always with a visible pause control. */
export function initHeroVideo(motion: boolean): void {
  const video = one<HTMLVideoElement>('[data-hero-video]');
  const toggle = one<HTMLButtonElement>('[data-hero-toggle]');
  if (!video || !toggle) return;
  const label = one('[data-label]', toggle);
  // The largest size the hero window reaches while it fills the screen.
  const largest = Math.min(window.innerWidth * 0.9, (window.innerHeight - 110) * 1.6) * 1.06;
  const src = `/media/hero-${footageWidth(largest)}.mp4`;
  let loaded = false;
  const load = () => {
    if (loaded || !src) return;
    loaded = true;
    video.src = src;
    video.preload = 'auto';
  };
  const sync = () => {
    const paused = video.paused;
    toggle.setAttribute('aria-pressed', paused ? 'true' : 'false');
    if (label) label.textContent = paused ? 'Play video' : 'Pause video';
  };
  toggle.hidden = false;
  toggle.addEventListener('click', () => {
    load();
    if (video.paused) {
      video.dataset.userPaused = '';
      void video.play().catch(() => undefined);
    } else {
      video.dataset.userPaused = '1';
      video.pause();
    }
  });
  video.addEventListener('play', sync);
  video.addEventListener('pause', sync);
  sync();
  if (!motion) return;
  // The poster image is the first paint; the video starts once the page has settled.
  const start = () => {
    load();
    if (video.dataset.userPaused !== '1' && video.getBoundingClientRect().bottom > 0) void video.play().catch(() => undefined);
  };
  if (document.readyState === 'complete') setTimeout(start, 300);
  else window.addEventListener('load', () => setTimeout(start, 300), { once: true });
  // Play while on screen, pause when scrolled away, unless the person paused it.
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        if (loaded && video.dataset.userPaused !== '1') void video.play().catch(() => undefined);
      } else if (!video.paused) {
        video.pause();
        sync();
      }
    }
  }, { threshold: 0.05 });
  io.observe(video);
}
