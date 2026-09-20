// Serve the current directory on 127.0.0.1, for the browser a debug session
// opens. Node rather than python because the case that needs this already
// needs node, and one dependency fewer is one fewer thing that silently is
// not there.
//
// Usage: node serve-fixture.js PORT

import { createServer } from "node:http";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { extname, join, normalize } from "node:path";

const port = Number(process.argv[2]);
const root = process.cwd();

const types = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".map": "application/json",
  ".tsx": "text/plain",
  ".ts": "text/plain",
  ".json": "application/json",
};

const server = createServer(async (request, response) => {
  const asked = decodeURIComponent(new URL(request.url, "http://127.0.0.1").pathname);
  const path = join(root, normalize(asked === "/" ? "/index.html" : asked));

  if (!path.startsWith(root)) {
    response.writeHead(403).end();
    return;
  }

  try {
    await stat(path);
  } catch {
    response.writeHead(404).end();
    return;
  }

  response.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream" });
  createReadStream(path).pipe(response);
});

server.listen(port, "127.0.0.1", () => console.log(`serving ${root} on ${port}`));
