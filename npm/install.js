#!/usr/bin/env node
"use strict";

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const https = require("https");

const REPO = "EvanL1/aitoolsync";
const BIN_DIR = path.join(__dirname, "bin");
const BIN_NAME = process.platform === "win32" ? "aisync.exe" : "aisync";
const BIN_PATH = path.join(BIN_DIR, BIN_NAME);

function getPlatformName() {
  const platform = process.platform;
  const arch = process.arch;

  const key = `${platform}_${arch}`;
  const map = {
    darwin_arm64: "aisync-darwin-aarch64",
    darwin_x64: "aisync-darwin-x86_64",
    linux_x64: "aisync-linux-x86_64",
    linux_arm64: "aisync-linux-aarch64",
    win32_x64: "aisync-windows-x86_64",
  };

  const name = map[key];
  if (!name) {
    console.error(`Unsupported platform: ${platform} ${arch}`);
    process.exit(1);
  }
  return name;
}

function fetch(url) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { "User-Agent": "aisync-npm" } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return fetch(res.headers.location).then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        return reject(new Error(`HTTP ${res.statusCode} for ${url}`));
      }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve(Buffer.concat(chunks)));
      res.on("error", reject);
    }).on("error", reject);
  });
}

async function main() {
  const name = getPlatformName();
  const isWindows = process.platform === "win32";
  const ext = isWindows ? "zip" : "tar.gz";

  // Get latest release tag
  const apiUrl = `https://api.github.com/repos/${REPO}/releases/latest`;
  const releaseData = await fetch(apiUrl);
  const release = JSON.parse(releaseData.toString());
  const tag = release.tag_name;

  const assetUrl = `https://github.com/${REPO}/releases/download/${tag}/${name}.${ext}`;
  console.log(`Downloading aisync ${tag} for ${process.platform} ${process.arch}...`);

  const data = await fetch(assetUrl);

  // Write archive to temp file and extract
  fs.mkdirSync(BIN_DIR, { recursive: true });
  const tmpFile = path.join(__dirname, `tmp-aisync.${ext}`);
  fs.writeFileSync(tmpFile, data);

  try {
    if (isWindows) {
      execSync(`powershell -Command "Expand-Archive -Path '${tmpFile}' -DestinationPath '${BIN_DIR}' -Force"`, { stdio: "pipe" });
    } else {
      execSync(`tar xzf "${tmpFile}" -C "${BIN_DIR}"`, { stdio: "pipe" });
      fs.chmodSync(BIN_PATH, 0o755);
    }
  } finally {
    fs.unlinkSync(tmpFile);
  }

  console.log(`✓ aisync ${tag} installed`);
}

main().catch((err) => {
  console.error("Failed to install aisync:", err.message);
  process.exit(1);
});
