#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const https = require("https");
const http = require("http");

const REPO = "atmospherelabs-dev/zipher-app";
const BIN_DIR = path.join(__dirname, "bin");

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

function getPlatformKey() {
  return `${process.platform}-${process.arch}`;
}

function getVersion() {
  return require("./package.json").version;
}

function downloadFile(url) {
  return new Promise((resolve, reject) => {
    const get = url.startsWith("https") ? https.get : http.get;
    get(url, (resp) => {
      if (resp.statusCode >= 300 && resp.statusCode < 400 && resp.headers.location) {
        return downloadFile(resp.headers.location).then(resolve, reject);
      }
      if (resp.statusCode !== 200) {
        return reject(new Error(`HTTP ${resp.statusCode} from ${url}`));
      }
      const chunks = [];
      resp.on("data", (chunk) => chunks.push(chunk));
      resp.on("end", () => resolve(Buffer.concat(chunks)));
      resp.on("error", reject);
    }).on("error", reject);
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
      const data = await downloadFile(url);
      fs.writeFileSync(dest, data);
      fs.chmodSync(dest, 0o755);
      console.log(`  Installed ${bin.name}`);
    } catch (err) {
      if (bin.name === "zipher-cli") {
        console.error(`Failed to download ${bin.name}: ${err.message}`);
        console.error(`\nDownload manually: https://github.com/${REPO}/releases`);
        console.error(`Or build from source: cargo build --release -p ${bin.name}`);
        process.exit(1);
      }
      console.warn(`  Warning: ${bin.name} not available for this release (${err.message})`);
    }
  }

  console.log("\nSetup: zipher wallet init");
}

main();
