const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { verifyChecksum, getPlatformKey } = require('../install');

test('accepts only the matching release artifact and digest', () => {
  const bytes = Buffer.from('disposable test artifact');
  const hash = createHash('sha256').update(bytes).digest('hex');
  verifyChecksum(bytes, `${hash}  zipher-cli-darwin-arm64\n`, 'zipher-cli-darwin-arm64');
  assert.throws(() => verifyChecksum(Buffer.from('tampered'), `${hash}  zipher-cli-darwin-arm64`, 'zipher-cli-darwin-arm64'));
  assert.throws(() => verifyChecksum(bytes, `${hash}  another-file`, 'zipher-cli-darwin-arm64'));
  assert.throws(() => verifyChecksum(bytes, 'invalid', 'zipher-cli-darwin-arm64'));
});

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

test('the public launcher executes the installed native artifact and forwards status', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zipher-launcher-'));
  try {
    fs.mkdirSync(path.join(dir, 'bin'));
    fs.mkdirSync(path.join(dir, 'native'));
    fs.copyFileSync(path.join(__dirname, '../run.js'), path.join(dir, 'run.js'));
    fs.copyFileSync(path.join(__dirname, '../bin/zipher'), path.join(dir, 'bin/zipher'));
    fs.writeFileSync(path.join(dir, 'native/zipher-cli'),
      '#!/usr/bin/env node\nprocess.stdout.write(JSON.stringify(process.argv.slice(2))); process.exit(7);\n', { mode: 0o755 });
    const result = spawnSync(process.execPath, [path.join(dir, 'bin/zipher'), '--version', 'two words'], { encoding: 'utf8' });
    assert.equal(result.status, 7);
    assert.deepEqual(JSON.parse(result.stdout), ['--version', 'two words']);
    fs.unlinkSync(path.join(dir, 'native/zipher-cli'));
    const missing = spawnSync(process.execPath, [path.join(dir, 'bin/zipher')], { encoding: 'utf8' });
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /executable is missing/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('chooses native Apple Silicon even when Node runs through Rosetta', () => {
  assert.equal(getPlatformKey('darwin', 'x64', () => true), 'darwin-arm64');
  assert.equal(getPlatformKey('darwin', 'x64', () => false), 'darwin-x64');
  assert.equal(getPlatformKey('darwin', 'x64', () => { throw new Error('unavailable'); }), 'darwin-x64');
  assert.equal(getPlatformKey('linux', 'x64', () => { throw new Error('must not run'); }), 'linux-x64');
});
