import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import Lenis from 'lenis';
import 'lenis/dist/lenis.css';
import { initCopy, initFaq, initHeroVideo, initNav } from './basics';
import { initFilm } from './film';
import { initHero } from './hero';
import { initPrune } from './prune';
import { initReveals } from './reveals';

declare global {
  interface Window { __lopperMotion?: boolean }
}

const root = document.documentElement;
const motion = root.classList.contains('motion');

initCopy();
initFaq(motion);
initNav(motion);
initHeroVideo(motion);

if (motion) {
  try {
    gsap.registerPlugin(ScrollTrigger);
    ScrollTrigger.config({ ignoreMobileResize: true });

    let lenis: Lenis | null = null;
    const coarse = window.matchMedia('(pointer: coarse)').matches;
    if (!coarse) {
      lenis = new Lenis({ lerp: 0.11, anchors: true, autoRaf: false });
      lenis.on('scroll', ScrollTrigger.update);
      gsap.ticker.add((time) => lenis?.raf(time * 1000));
      gsap.ticker.lagSmoothing(0);
    }

    initHero();
    initPrune();
    initFilm(lenis);
    initReveals();
    window.__lopperMotion = true;

    // Fonts change line heights; measure again once they are in.
    void document.fonts.ready.then(() => ScrollTrigger.refresh());
  } catch (error) {
    root.classList.remove('motion');
    console.warn('Motion disabled', error);
  }
}
