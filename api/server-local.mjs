import http from "http";
import handler from "./api/v1/ai-puzzle.js";

const port = Number(process.env.PORT) || 3000;
const server = http.createServer(async (req, res) => {
  if (req.url !== "/api/v1/ai-puzzle") {
    res.writeHead(404);
    res.end();
    return;
  }
  let body = "";
  for await (const chunk of req) body += chunk;
  const mockReq = {
    method: req.method,
    headers: Object.fromEntries(
      Object.entries(req.headers).map(([k, v]) => [k.toLowerCase(), v])
    ),
    body,
  };
  const mockRes = {
    statusCode: 200,
    status(c) {
      this.statusCode = c;
      return this;
    },
    json(obj) {
      res.writeHead(this.statusCode, { "Content-Type": "application/json" });
      res.end(JSON.stringify(obj));
    },
  };
  await handler(mockReq, mockRes);
});

server.listen(port, () => {
  console.log(`AI puzzle API at http://127.0.0.1:${port}/api/v1/ai-puzzle`);
});
