const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {test} = require('node:test');

const root = path.join(__dirname, '..');
const checkout = process.env.UAI_CHECKOUT || '/root/ProjectUAI';
const client = fs.readFileSync(path.join(checkout, 'dist/uai.lua'), 'utf8');
const bootstrap = () => fs.readFileSync(path.join(root, 'src/gateway_bootstrap.lua'), 'utf8');

test('published artifact reproducibly embeds the pinned client and integration', () => {
  const {buildGateway} = require('../tools/build-gateway.cjs');
  const artifact = buildGateway(client, bootstrap());
  assert.equal(artifact, fs.readFileSync(path.join(root, 'examples/gateway.lua'), 'utf8'));
  assert.equal(buildGateway(client, bootstrap()), artifact);
  assert.ok(artifact.includes('Copyright (c) 2026 CarlDV'));
  assert.ok(artifact.includes('d5060d3c4868cf6676ac191a1aa7708b78fa6b6d'));
  assert.ok(artifact.includes('local FOLDER = "UAI-Compat-3.7.1"'));
  assert.ok(!artifact.includes('local FOLDER = "UAI"'));
});

test('changed upstream source is rejected before generating a loader', () => {
  const {buildGateway} = require('../tools/build-gateway.cjs');
  assert.throws(() => buildGateway(client + '\n-- changed\n', bootstrap()), /pinned client hash/);
});

test('integration calls its embedded client without secondary compilation or download', () => {
  const source = bootstrap();
  assert.match(source, /local startClient, token = \.\.\./);
  assert.match(source, /pcall\(startClient,/);
  assert.doesNotMatch(source, /loadstring|CLIENT_URL|\/dist\/uai\.lua/);
});
