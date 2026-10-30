// Run the real pinned bundle and loader in native Luau. Only Roblox's external
// services are mocked; compilation, bootstrap, UI and provider modules are real.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const upstream = process.argv[2];
const binary = process.argv[3] || process.env.LUAU_BIN;
if (!upstream || !binary) {
  console.error('Usage: node test/native_gateway_loader.cjs <ProjectUAI checkout> <native luau binary>');
  process.exit(1);
}

function literal(text) {
  let equals = '=';
  while (text.includes(`]${equals}]`)) equals += '=';
  return `[${equals}[${text}]${equals}]`;
}

const names = ['env', 'json', 'scheduler', 'datatypes', 'instance', 'services'];
const sources = Object.fromEntries(names.map(name => [name,
  fs.readFileSync(path.join(upstream, 'test/mock', `${name}.lua`), 'utf8')]));
sources.bundle = fs.readFileSync(path.join(upstream, 'dist/uai.lua'), 'utf8');
assert.equal(crypto.createHash('sha256').update(sources.bundle).digest('hex'),
  'ed5176f3301b7412b1627040ef85357684c5525b995672f66389a1787304ef80',
  'Tests must execute the exact pinned 3.7.1 bundle, not a different client');
sources.loader = fs.readFileSync(path.join(__dirname, '../examples/gateway.lua'), 'utf8');
sources.scenario = fs.readFileSync(path.join(__dirname, 'native_gateway_loader.lua'), 'utf8');

const program = `
local sources = {${Object.entries(sources).map(([key, text]) => `[${JSON.stringify(key)}] = ${literal(text)}`).join(',\n')}}
local env = setmetatable({}, {__index = getfenv(0)})
env._G = env
env.package = {path = '', loaded = {}}
local nativeLoad = loadstring
env.loadstring = function(source, name)
  local chunk, why = nativeLoad(source, name)
  if chunk then setfenv(chunk, env) end
  return chunk, why
end
env.require = function(name)
  if env.package.loaded[name] then return env.package.loaded[name] end
  local result = assert(env.loadstring(assert(sources[name], name), '@' .. name))()
  env.package.loaded[name] = result
  return result
end
env.package.loaded.luau = {load = function(source, name)
  local chunk, why = env.loadstring(source, '@' .. name)
  return chunk, chunk and nil or {{line = 0, msg = why}}
end}
env.sources = sources
assert(env.loadstring(sources.scenario, '@scenario'))()
`;

const scratch = process.env.OPENCODE_TMP_DIR ||
  (fs.existsSync('/tmp/opencode') ? '/tmp/opencode' : os.tmpdir());
const directory = fs.mkdtempSync(path.join(scratch, 'uai-native-test-'));
const file = path.join(directory, 'program.lua');
try {
  fs.writeFileSync(file, program);
  const result = spawnSync(binary, [file], {encoding: 'utf8', timeout: 120000});
  process.stdout.write(result.stdout || '');
  process.stderr.write(result.stderr || '');
  if (result.error) console.error(result.error.message);
  process.exitCode = result.status === 0 ? 0 : 1;
} finally {
  fs.unlinkSync(file);
  fs.rmdirSync(directory);
}
