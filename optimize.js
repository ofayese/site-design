/**
 * Temporary image optimizer — run once: npm i sharp && node optimize.js
 * Outputs WebP variants into olutechsys/assets/
 */
const fs = require("fs");
const path = require("path");
const sharp = require("sharp");

const ASSETS = path.join(__dirname, "olutechsys", "assets");

const JOBS = [
  { input: "olutech-final.png", output: "olutech-final.webp", width: 800 },
  { input: "olutech-dev-hub.png", output: "olutech-dev-hub.webp", width: 1200 },
  { input: "olutech-yoruba.jpg", output: "olutech-yoruba.webp", width: 1200 },
];

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

async function run() {
  for (const job of JOBS) {
    const inputPath = path.join(ASSETS, job.input);
    const outputPath = path.join(ASSETS, job.output);

    if (!fs.existsSync(inputPath)) {
      console.error(`Missing: ${inputPath}`);
      process.exit(1);
    }

    const inputSize = fs.statSync(inputPath).size;
    await sharp(inputPath)
      .resize({ width: job.width, withoutEnlargement: true })
      .webp({ quality: 80 })
      .toFile(outputPath);

    const outputSize = fs.statSync(outputPath).size;
    const saved = ((1 - outputSize / inputSize) * 100).toFixed(1);
    console.log(
      `${job.input} → ${job.output}: ${formatBytes(inputSize)} → ${formatBytes(outputSize)} (${saved}% smaller)`
    );
  }
  console.log("Done.");
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
