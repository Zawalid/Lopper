// Static assets ignore Range requests, but <video> seeking and Safari playback need them.
// Only /media/*.mp4 runs through this Worker (run_worker_first in wrangler.jsonc); every other file is served as static assets.
const RANGE = /^bytes=(\d*)-(\d*)$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const full = await env.ASSETS.fetch(new Request(url, { method: 'GET' }));
    if (!full.ok) return full;

    const headers = new Headers(full.headers);
    headers.set('Accept-Ranges', 'bytes');

    const range = RANGE.exec(request.headers.get('Range') ?? '');
    if (!range || (range[1] === '' && range[2] === '')) return new Response(request.method === 'HEAD' ? null : full.body, { status: 200, headers });

    const body = await full.arrayBuffer();
    const size = body.byteLength;
    let start;
    let end;
    if (range[1] === '') {
      start = Math.max(size - Number(range[2]), 0);
      end = size - 1;
    } else {
      start = Number(range[1]);
      end = range[2] === '' ? size - 1 : Math.min(Number(range[2]), size - 1);
    }
    if (start > end || start >= size) {
      headers.set('Content-Range', `bytes */${size}`);
      return new Response(null, { status: 416, headers });
    }

    headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
    headers.set('Content-Length', String(end - start + 1));
    return new Response(request.method === 'HEAD' ? null : body.slice(start, end + 1), { status: 206, headers });
  },
};
