#!/usr/bin/env node
'use strict';

// bbMusic sidecar.
//
// The upstream package (@yakult-green-tea/qq-music-api) listens on `app.listen(port)` with no
// host argument, which binds every interface (`::`) on a fixed port. We only ever want this
// service reachable from this Mac, on a port nobody else has claimed.
//
// `NODE_ENV=test` makes the upstream skip its own listen() (its exported `server` becomes null),
// leaving the default-exported Koa app for us to bind ourselves. Keep this assignment above the
// require: the upstream reads the flag at import time.
process.env.NODE_ENV = 'test';
// The upstream validates PORT as > 0 at import time and exits on a bad value. We bind port 0
// ourselves below, so make sure no inherited PORT can fail that validation.
if (process.env.PORT === '0' || process.env.PORT === '') {
  delete process.env.PORT;
}

const HOST = '127.0.0.1';
const HANDSHAKE = 'BBMUSIC_PORT ';
const PACKAGE = '@yakult-green-tea/qq-music-api';

function fail(message) {
  process.stderr.write(`sidecar: ${message}\n`);
  process.exit(1);
}

let root;
try {
  root = require(PACKAGE);
} catch (error) {
  fail(`cannot load QQ Music API: ${error && error.message}`);
}

// Login state has to survive a sidecar restart, otherwise every crash forces the user to scan a
// new QR code. The upstream ships an encrypted file repository for exactly this, but importing the
// package does NOT install it: without this call the session store stays in memory, restores zero
// sessions, and every authenticated route answers 401 even though the session file is intact.
try {
  const repositoryModule = require(`${PACKAGE}/dist/src/services/auth/fileAuthSessionRepository.js`);
  const repository = repositoryModule.createConfiguredAuthSessionRepository(process.env);
  if (repository) {
    root.configureAuthSessionRepository(repository);
    process.stderr.write(`sidecar: session persistence ${repository.kind}\n`);
  } else {
    // Neither QQ_SESSION_SECRET nor QQ_AUTH_SESSION_PATH was set; logins will not survive a
    // restart. Say so instead of silently degrading.
    process.stderr.write('sidecar: session persistence unavailable (no secret/path)\n');
  }
} catch (error) {
  process.stderr.write(`sidecar: session persistence failed: ${error && error.message}\n`);
}

const app = root.default;
if (!app || typeof app.listen !== 'function') {
  fail('QQ Music API did not export a Koa application');
}

const server = app.listen(0, HOST, () => {
  const address = server.address();
  if (!address || typeof address === 'string') {
    fail('could not read the bound address');
  }
  // The parent parses exactly this line to learn where the API lives.
  process.stdout.write(`${HANDSHAKE}${address.port}\n`);
});

server.on('error', (error) => {
  fail(`listen failed: ${error && error.message}`);
});

function shutdown(signal) {
  server.close(() => process.exit(0));
  // Do not let an idle keep-alive connection hold the process open forever.
  setTimeout(() => process.exit(0), 3000).unref();
  process.stderr.write(`sidecar: ${signal}, closing\n`);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
