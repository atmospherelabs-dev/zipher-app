#!/usr/bin/env node

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const https = require("https");
const http = require("http");

const REPO = "atmospherelabs-dev/zipher-app";
const BIN_DIR = path.join(__dirname, "bin");
const BIN_PATH = path.join(BIN_DIR, process.platform === "win32" ? "zipher-cli.exe" : "zipher-cli");

const PLATFORM_MAP = {
  "darwin-arm64": "zipher-cli-darwin-arm64",
  "darwin-x64": "zipher-cli-darwin-x64",
  "linux-x64": "zipher-cli-linux-x64",
  "linux-arm64": "zipher-cli-linux-arm64",
};

function getPlatformKey() {
  return `${process.platform}-${process.arch}`;
}

function getVersion() {
  const pkg = require("./package.json");
  return pkg.version;
}

function downloadFile(url) {
  return new Promise((resolve, reject) => {
    const get = url.startsWith("https") ? https.get : http.get;
    get(url, (resp) => {
      if (resp.statusCode >= 300 && resp.statusCode < 400 && resp.headers.location) {
        return downloadFile(resp.headers.location).then(resolve, reject);
      }
      if (resp.statusCode !== 200) {
        return reject(new Error(`Download failed: HTTP ${resp.statusCode} from ${url}`));
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
  const artifact = PLATFORM_MAP[key];

  if (!artifact) {
    console.error(`Unsupported platform: ${key}`);
    console.error(`Supported: ${Object.keys(PLATFORM_MAP).join(", ")}`);
    process.exit(1);
  }

  const version = getVersion();
  const tag = `cli-v${version}`;
  const url = `https://github.com/${REPO}/releases/download/${tag}/${artifact}`;

  console.log(`Downloading zipher-cli ${version} for ${key}...`);
  console.log(`  ${url}`);

  try {
    const data = await downloadFile(url);

    fs.mkdirSync(BIN_DIR, { recursive: true });
    fs.writeFileSync(BIN_PATH, data);
    fs.chmodSync(BIN_PATH, 0o755);

    console.log(`Installed zipher-cli to ${BIN_PATH}`);
  } catch (err) {
    console.error(`Failed to download zipher-cli: ${err.message}`);
    console.error("");
    console.error("You can manually download from:");
    console.error(`  https://github.com/${REPO}/releases`);
    console.error("");
    console.error("Or build from source:");
    console.error("  cd rust && cargo build --release -p zipher-cli");
    process.exit(1);
  }
}

main();
