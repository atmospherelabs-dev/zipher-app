const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

module.exports = function run(name) {
  const executable = path.join(__dirname, 'native', name);
  if (!fs.existsSync(executable)) {
    console.error('Zipher executable is missing. Reinstall the package or run npm install in this package directory.');
    process.exit(1);
  }
  const result = spawnSync(executable, process.argv.slice(2), { stdio: 'inherit' });
  if (result.error) {
    console.error(`Unable to start Zipher: ${result.error.message}`);
    process.exit(1);
  }
  if (result.signal) process.kill(process.pid, result.signal);
  process.exit(result.status ?? 1);
};
