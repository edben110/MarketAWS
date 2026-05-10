const http = require('http');

const port = process.env.PORT || 3001;
const version = process.env.VERSION || 'v1.0-Main';

const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Access-Control-Allow-Origin', '*');
    
    if (req.url === '/health') {
        res.statusCode = 200;
        res.end(JSON.stringify({ status: 'ok' }));
        return;
    }

    res.statusCode = 200;
    res.end(JSON.stringify({
        message: "MarketAWS Backend Response",
        version: version,
        port: port,
        timestamp: new Date().toISOString(),
        instanceId: process.env.HOSTNAME || 'unknown'
    }));
});

server.listen(port, () => {
    console.log(`Server running at http://localhost:${port}/ (Version: ${version})`);
});
