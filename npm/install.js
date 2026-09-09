#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const https = require("https");
const crypto = require("crypto");
const { execFileSync } = require("node:child_process");

const REPO = "atmospherelabs-dev/zipher-app";
const BIN_DIR = path.join(__dirname, "native");

const BINARIES = [
  { name: "zipher-cli", prefix: "zipher-cli" },
  { name: "zipher-mcp-server", prefix: "zipher-mcp-server" },
];

const PLATFORM_MAP = {
  "darwin-arm64": "darwin-arm64",
  "darwin-x64": "darwin-x64",
  "linux-x64": "linux-x64",
  "linux-arm64": "linux-arm64",
};

function getPlatformKey(platform = process.platform, arch = process.arch,
  isAppleSilicon = () => execFileSync('/usr/sbin/sysctl', ['-n', 'hw.optional.arm64'], { encoding: 'utf8', timeout: 5000 }).trim() === '1') {
  // An Intel Node installation under Rosetta can still launch native ARM binaries.
  if (platform === 'darwin' && arch === 'x64') {
    try { if (isAppleSilicon()) arch = 'arm64'; } catch (_) { /* Fall back to the runtime architecture. */ }
  }
  return `${platform}-${arch}`;
}

function getVersion() {
  return require("./package.json").version;
}

function downloadFile(url, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (!url.startsWith("https://") || redirects > 5) {
      return reject(new Error("Invalid download URL or too many redirects"));
    }
    const request = https.get(url, (resp) => {
      if (resp.statusCode >= 300 && resp.statusCode < 400 && resp.headers.location) {
        resp.resume();
        return downloadFile(new URL(resp.headers.location, url).href, redirects + 1).then(resolve, reject);
      }
      if (resp.statusCode !== 200) {
        return reject(new Error(`HTTP ${resp.statusCode} from ${url}`));
      }
      const chunks = [];
      let size = 0;
      resp.on("data", (chunk) => {
        size += chunk.length;
        if (size > 256 * 1024 * 1024) request.destroy(new Error("Artifact exceeds size limit"));
        else chunks.push(chunk);
      });
      resp.on("end", () => resolve(Buffer.concat(chunks)));
      resp.on("error", reject);
    }).on("error", reject);
    request.setTimeout(60_000, () => request.destroy(new Error("Download timed out")));
  });
}

async function main() {
  const key = getPlatformKey();
  const suffix = PLATFORM_MAP[key];

  if (!suffix) {
    console.error(`Unsupported platform: ${key}`);
    console.error(`Supported: ${Object.keys(PLATFORM_MAP).join(", ")}`);
    process.exit(1);
  }

  const version = getVersion();
  const tag = `cli-v${version}`;

  fs.mkdirSync(BIN_DIR, { recursive: true });

  for (const bin of BINARIES) {
    const artifact = `${bin.prefix}-${suffix}`;
    const url = `https://github.com/${REPO}/releases/download/${tag}/${artifact}`;
    const dest = path.join(BIN_DIR, bin.name);

    console.log(`Downloading ${bin.name} ${version} for ${key}...`);

    try {
      const [data, checksum] = await Promise.all([
        downloadFile(url), downloadFile(`${url}.sha256`),
      ]);
      verifyChecksum(data, checksum.toString("utf8"), artifact);
      fs.writeFileSync(dest, data);
      fs.chmodSync(dest, 0o755);
      console.log(`  Installed ${bin.name}`);
    } catch (err) {
        console.error(`Failed to download ${bin.name}: ${err.message}`);
        console.error(`\nDownload manually: https://github.com/${REPO}/releases`);
        console.error(`Or build from source: cargo build --release -p ${bin.name}`);
        process.exit(1);
    }
  }

  console.log("\nSetup: zipher wallet init");
}

function verifyChecksum(data, checksum, artifact) {
  const match = checksum.trim().match(/^([a-f0-9]{64})\s+\*?([^\s]+)$/i);
  if (!match || match[2] !== artifact || crypto.createHash("sha256").update(data).digest("hex") !== match[1].toLowerCase()) {
    throw new Error(`Checksum verification failed for ${artifact}`);
  }
}

module.exports = { verifyChecksum, getPlatformKey };
if (require.main === module) main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
