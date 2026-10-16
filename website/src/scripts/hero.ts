import { gsap } from 'gsap';
import { one, isSmall } from './dom';

/**
 * The hero camera: the window lies tilted under the headline, then rises, flattens and fills the screen
 * as you scroll. The next section slides over it like a curtain while it dims.
 */
export function initHero(): void {
  const hero = one('[data-hero]');
  const copy = one('[data-hero-copy]');
  const wrap = one('[data-hero-wrap]');
  const tilt = one('[data-hero-tilt]');
  const dim = one('[data-hero-dim]');
  if (!hero || !copy || !wrap || !tilt || !dim) return;

  const vh = () => window.innerHeight;
  const targetScale = () => {
    const w0 = wrap.offsetWidth;
    const small = isSmall();
    const maxW = small ? window.innerWidth - 24 : Math.min(window.innerWidth * 0.9, (vh() - 110) * 1.6);
    return Math.max(1, maxW / w0);
  };
  const targetY = () => {
    const top = wrap.offsetTop;
    const h = wrap.offsetHeight;
    const centre = isSmall() ? vh() * 0.5 : vh() * 0.5 + 20;
    return centre - (top + h / 2);
  };

  gsap.set(tilt, { rotateX: isSmall() ? 16 : 24, scale: isSmall() ? 0.96 : 0.92, transformOrigin: '50% 0%' });

  const tl = gsap.timeline({
    defaults: { ease: 'none' },
    scrollTrigger: {
      trigger: hero,
      start: 'top top',
      end: () => `+=${vh() * 1.9}`,
      scrub: 0.6,
      invalidateOnRefresh: true,
    },
  });

  tl.to(copy, { y: () => -vh() * 0.2, opacity: 0, duration: 0.38, ease: 'power1.in' }, 0)
    .to(tilt, { rotateX: 0, scale: 1, duration: 0.8, ease: 'power2.out' }, 0)
    .to(wrap, { y: targetY, scale: targetScale, duration: 0.9, ease: 'power2.inOut' }, 0)
    .to(wrap, { scale: () => targetScale() * 1.06, duration: 1.0, ease: 'power1.in' }, 0.9)
    .to(dim, { opacity: 0.75, duration: 1.0, ease: 'power1.in' }, 0.9);
}
