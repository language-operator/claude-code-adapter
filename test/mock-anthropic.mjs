// A mock of Anthropic's Messages API for test/task-mode.sh, run in the image's
// own node. Answers POST /v1/messages — streamed or not — for MOCK_MODEL with a
// fixed reply, and 404s any other model the way the real API does, so Claude Code
// exits non-zero. Every request is logged as one JSON line, which is how the test
// checks that the instructions arrived as the prompt.
import { createServer } from 'node:http';
const MODEL = process.env.MOCK_MODEL ?? 'mock-model';
const PORT = Number(process.env.MOCK_PORT ?? 18080);
createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    let json = {};
    try { json = JSON.parse(body || '{}'); } catch {}
    // The user turns' text, in full: Claude Code prepends a long system-reminder
    // to the prompt, so a truncated body would cut off the very text the test
    // looks for.
    const prompt = (json.messages ?? [])
      .filter((m) => m.role === 'user')
      .flatMap((m) => (typeof m.content === 'string' ? [m.content] : (m.content ?? []).map((c) => c.text ?? '')))
      .join('\n');
    console.log(JSON.stringify({ url: req.url, model: json.model, prompt }));
    const path = req.url.split('?')[0];
    if (req.method !== 'POST' || path !== '/v1/messages') {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: `no route ${req.url}` } }));
      return;
    }
    if (json.model !== MODEL) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: `model: ${json.model}` } }));
      return;
    }
    const id = 'msg_mock';
    const text = 'MOCK-DONE';
    const usage = { input_tokens: 1, output_tokens: 1 };
    if (!json.stream) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id, type: 'message', role: 'assistant', model: MODEL, content: [{ type: 'text', text }], stop_reason: 'end_turn', stop_sequence: null, usage }));
      return;
    }
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
    const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify({ type: event, ...data })}\n\n`);
    send('message_start', { message: { id, type: 'message', role: 'assistant', model: MODEL, content: [], stop_reason: null, stop_sequence: null, usage } });
    send('content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
    send('content_block_delta', { index: 0, delta: { type: 'text_delta', text } });
    send('content_block_stop', { index: 0 });
    send('message_delta', { delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 1 } });
    send('message_stop', {});
    res.end();
  });
}).listen(PORT, () => console.log(`mock anthropic on ${PORT}`));
