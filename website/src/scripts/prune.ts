import { gsap } from 'gsap';
import { all, one } from './dom';

const OPEN = 22;
const CLOSED = 1;

interface Snip { ids: string[]; x: number; y: number; rot: number }

/** Swap one display line for the next, word by word. */
export function swapWords(tl: gsap.core.Timeline, out: Element | null, inn: Element | null, at: number): void {
  if (out) {
    tl.fromTo(all('.pw, .cw', out), { yPercent: 0 }, { yPercent: -140, duration: 0.28, stagger: 0.025, ease: 'power2.in', immediateRender: false }, at);
  }
  if (inn) {
    tl.fromTo(all('.pw, .cw', inn), { yPercent: 140 }, { yPercent: 0, duration: 0.42, stagger: 0.035, ease: 'power3.out', immediateRender: false }, at + 0.22);
  }
}

function drawable(path: SVGPathElement): number {
  const len = path.getTotalLength();
  gsap.set(path, { strokeDasharray: `${len} ${len}`, strokeDashoffset: len });
  return len;
}

export function initPrune(): void {
  const section = one('[data-prune]');
  const svg = one<SVGSVGElement>('[data-graph]');
  if (!section || !svg) return;

  const lines = all('[data-line]', section);
  const receipts = all('[data-receipts] li', section);
  const trunk = one<SVGPathElement>('[data-trunk]', svg);
  const head = one<SVGCircleElement>('[data-head]', svg);
  const scissors = one<SVGGElement>('[data-scissors]', svg);
  const bladeA = one<SVGGElement>('[data-blade-a]', svg);
  const bladeB = one<SVGGElement>('[data-blade-b]', svg);
  if (!trunk || !head || !scissors || !bladeA || !bladeB) return;

  // Initial state: line 0 shown, everything else hidden, graph undrawn.
  lines.forEach((line, i) => gsap.set(all('.pw', line), { y: 0, yPercent: i === 0 ? 0 : 140 }));
  gsap.set(receipts, { opacity: 0, x: -12 });
  const trunkLen = drawable(trunk);
  gsap.set(trunk, { opacity: 0 });
  const grows = [0, 1, 2].map((g) => all<SVGPathElement>(`[data-grow="${g}"]`, svg));
  // Hidden until drawn: a round cap on an empty dash still paints a dot.
  grows.flat().forEach((p) => { drawable(p); gsap.set(p, { opacity: 0 }); });
  const commits = [0, 1, 2].map((g) => all(`[data-commit="${g}"]`, svg));
  const nodes = [0, 1, 2].map((g) => all(`[data-node="${g}"]`, svg));
  gsap.set([...commits.flat(), ...nodes.flat()], { scale: 0, transformOrigin: '50% 50%' });
  gsap.set(head, { scale: 0, transformOrigin: '50% 50%' });

  const tl = gsap.timeline({
    defaults: { ease: 'none' },
    scrollTrigger: { trigger: section, start: 'top top', end: 'bottom bottom', scrub: 0.5 },
  });

  // Growth in three phases, one per line.
  const trunkTo = [0.3, 0.56, 1];
  const phaseAt = [0.15, 1.95, 3.75];
  tl.to(trunk, { opacity: 1, duration: 0.05 }, phaseAt[0]);
  phaseAt.forEach((at, g) => {
    tl.to(trunk, { strokeDashoffset: trunkLen * (1 - trunkTo[g]), duration: 0.7, ease: 'power1.inOut' }, at);
    tl.to(commits[g], { scale: 1, duration: 0.18, stagger: 0.12, ease: 'back.out(3)' }, at + 0.2);
    tl.to(grows[g], { strokeDashoffset: 0, duration: 0.85, stagger: 0.12, ease: 'power2.out' }, at + 0.25);
    tl.to(grows[g], { opacity: 1, duration: 0.08, stagger: 0.12 }, at + 0.25);
    tl.to(nodes[g], { scale: 1, duration: 0.25, stagger: 0.12, ease: 'back.out(2.4)' }, at + 0.85);
  });
  tl.to(head, { scale: 1, duration: 0.2, ease: 'back.out(3)' }, 4.35);

  swapWords(tl, lines[0], lines[1], 1.6);
  swapWords(tl, lines[1], lines[2], 3.4);

  // Line 3: most of it is finished. The stale branches go quiet.
  swapWords(tl, lines[2], lines[3], 5.2);
  const staleGroups = all<SVGGElement>('[data-stale]', svg);
  for (const g of staleGroups) {
    const id = g.dataset.stale ?? '';
    const grow = one('.grow', g);
    const parts = all('.stump, [data-tail]', g);
    const tip = one(`[data-stale-tip="${id}"]`, svg);
    tl.to(grow, { opacity: 0, duration: 0.5 }, 5.8);
    tl.fromTo(parts, { opacity: 0 }, { opacity: 1, duration: 0.5, immediateRender: false }, 5.8);
    if (tip) tl.to(tip, { opacity: 0, duration: 0.4 }, 5.8);
  }

  // Line 4: the cut.
  swapWords(tl, lines[3], lines[4], 6.9);
  const cutOf = (id: string): [number, number] => {
    const g = one<SVGGElement>(`[data-stale="${id}"]`, svg);
    const v = (g?.dataset.cut ?? '0 0').split(' ').map(Number);
    return [v[0], v[1]];
  };
  const snips: Snip[] = [['s1', 's2'], ['s3'], ['s5', 's4'], ['s6']].map((ids) => {
    const a = cutOf(ids[0]);
    const b = cutOf(ids[ids.length - 1]);
    const rot = ids.length > 1 ? (Math.atan2(b[1] - a[1], b[0] - a[0]) * 180) / Math.PI : 38;
    return { ids, x: (a[0] + b[0]) / 2, y: (a[1] + b[1]) / 2, rot };
  });

  const sc = { x: snips[0].x - 520, y: snips[0].y - 460, r: snips[0].rot - 30, a: OPEN };
  const render = () => {
    scissors.setAttribute('transform', `translate(${sc.x.toFixed(1)} ${sc.y.toFixed(1)}) rotate(${sc.r.toFixed(1)}) scale(1.25)`);
    bladeA.setAttribute('transform', `rotate(${(-sc.a).toFixed(2)})`);
    bladeB.setAttribute('transform', `rotate(${sc.a.toFixed(2)})`);
  };
  render();

  const first = snips[0];
  tl.fromTo(scissors, { opacity: 0 }, { opacity: 1, duration: 0.3, immediateRender: false }, 7.3);
  tl.fromTo(sc, { x: first.x - 520, y: first.y - 460, r: first.rot - 30 }, { x: first.x, y: first.y, r: first.rot, duration: 0.5, ease: 'power3.out', onUpdate: render, immediateRender: false }, 7.3);

  snips.forEach((s, i) => {
    const T = 8.0 + i * 0.85;
    tl.fromTo(sc, { a: OPEN }, { a: CLOSED, duration: 0.12, ease: 'power3.in', onUpdate: render, immediateRender: false }, T - 0.12);
    tl.fromTo(sc, { a: CLOSED }, { a: OPEN, duration: 0.22, ease: 'power2.out', onUpdate: render, immediateRender: false }, T + 0.02);
    const next = snips[i + 1];
    if (next) {
      tl.fromTo(sc, { x: s.x, y: s.y, r: s.rot }, { x: next.x, y: next.y, r: next.rot, duration: 0.45, ease: 'power2.inOut', onUpdate: render, immediateRender: false }, T + 0.2);
    } else {
      tl.fromTo(sc, { x: s.x, y: s.y, r: s.rot }, { x: s.x + 420, y: s.y - 520, r: s.rot + 30, duration: 0.6, ease: 'power2.in', onUpdate: render, immediateRender: false }, T + 0.3);
      tl.to(scissors, { opacity: 0, duration: 0.4 }, T + 0.5);
    }
    s.ids.forEach((id, k) => {
      const [cx, cy] = cutOf(id);
      const tail = one(`[data-stale="${id}"] [data-tail]`, svg);
      const ring = one(`[data-ring="${id}"]`, svg);
      const left = cx < 1180;
      if (tail) {
        tl.fromTo(tail, { y: 0, rotation: 0 }, { y: 300 + k * 30, rotation: left ? -14 : 14, svgOrigin: `${cx} ${cy}`, duration: 0.7, ease: 'power2.in', immediateRender: false }, T + k * 0.05);
        tl.to(tail, { opacity: 0, duration: 0.3 }, T + 0.4 + k * 0.05);
      }
      if (ring) {
        tl.fromTo(ring, { opacity: 0.95, attr: { r: 8 } }, { opacity: 0, attr: { r: 54 }, duration: 0.45, ease: 'power2.out', immediateRender: false }, T);
      }
      tl.to(`[data-stale="${id}"] .stump`, { opacity: 0.5, duration: 0.3 }, T + 0.1);
    });
    tl.to(receipts[i], { opacity: 1, x: 0, duration: 0.25, ease: 'power3.out' }, T + 0.02);
  });

  // Line 5: what is left.
  const settle = 8.0 + snips.length * 0.85 + 0.3;
  swapWords(tl, lines[4], lines[5], settle);
  tl.to(receipts, { opacity: 0.55, duration: 0.4 }, settle + 0.3);
  tl.fromTo(all('.node.hi .halo', svg), { scale: 1 }, { scale: 1.5, opacity: 0, transformOrigin: '50% 50%', duration: 0.6, ease: 'power2.out', immediateRender: false }, settle + 0.4);
  tl.to({}, { duration: 0.9 }, settle + 0.9);
}
