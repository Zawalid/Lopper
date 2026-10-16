import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { all, one } from './dom';

/** Section transitions after the tour: type that scales in, a ledger that rules itself, words that light up, a mint panel that opens. */
export function initReveals(): void {
  // Safety title: settles from large and faint as it arrives.
  for (const el of all('[data-scale-in]')) {
    gsap.fromTo(el, { scale: 1.18, opacity: 0.15, transformOrigin: '0% 100%' }, {
      scale: 1, opacity: 1, ease: 'none',
      scrollTrigger: { trigger: el, start: 'top 95%', end: 'top 45%', scrub: 0.5 },
    });
  }

  // Ledger rows: the rule draws, then the words arrive.
  for (const row of all('[data-ledger-row]')) {
    const line = one('.rule-line', row);
    const parts = all('dt, dd', row);
    gsap.set(line, { scaleX: 0 });
    gsap.set(parts, { opacity: 0, y: 18 });
    ScrollTrigger.create({
      trigger: row,
      start: 'top 86%',
      once: true,
      onEnter: () => {
        gsap.to(line, { scaleX: 1, duration: 0.9, ease: 'power3.inOut' });
        gsap.to(parts, { opacity: 1, y: 0, duration: 0.7, stagger: 0.09, delay: 0.25, ease: 'power3.out' });
      },
    });
  }

  // Privacy statement: words light up as you read down.
  const statement = one('[data-statement]');
  if (statement) {
    const words = all('.sw', statement);
    ScrollTrigger.create({
      trigger: statement,
      start: 'top 78%',
      end: 'bottom 42%',
      scrub: true,
      onUpdate: (self) => {
        const n = Math.round(self.progress * words.length);
        words.forEach((w, i) => w.classList.toggle('lit', i < n));
      },
    });
  }

  // Simple fade up for small items.
  for (const el of all('[data-reveal]')) {
    gsap.fromTo(el, { opacity: 0, y: 24 }, {
      opacity: 1, y: 0, duration: 0.8, ease: 'power3.out',
      scrollTrigger: { trigger: el, start: 'top 90%', once: true },
    });
  }

  // Install: the mint panel opens from a card to the full width.
  const panel = one('[data-install-panel]');
  if (panel) {
    gsap.fromTo(panel, { clipPath: 'inset(8% 6% 0% 6% round 16px)' }, {
      clipPath: 'inset(0% 0% 0% 0% round 0px)', ease: 'none',
      scrollTrigger: { trigger: panel, start: 'top 95%', end: 'top 25%', scrub: 0.4 },
    });
    const title = one('.install-title', panel);
    if (title) {
      gsap.fromTo(title, { yPercent: 40, opacity: 0 }, {
        yPercent: 0, opacity: 1, ease: 'power2.out',
        scrollTrigger: { trigger: panel, start: 'top 80%', end: 'top 30%', scrub: 0.4 },
      });
    }
  }
}
