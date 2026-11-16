#!/usr/bin/env node
// Preserve a real screenshot byte-for-byte and clip only its outer corners.
// An SVG wrapper retains transparency without resampling the screenshot.
import { readFile, writeFile } from 'node:fs/promises';
const [source, destination, widthText, heightText] = process.argv.slice(2);
const width = Number(widthText), height = Number(heightText);
if (!source || !destination?.endsWith('.svg') || !Number.isInteger(width) || !Number.isInteger(height) || width <= 32 || height <= 32) {
  throw new Error('Usage: node scripts/wrap-screenshot.mjs source.jpg output.svg width height');
}
const bytes = await readFile(source);
if (bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new Error('Expected a JPEG screenshot');
await writeFile(destination, `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="DWS Assistant">
  <title>DWS Assistant</title>
  <defs><clipPath id="window"><rect width="${width}" height="${height}" rx="16"/></clipPath></defs>
  <image width="${width}" height="${height}" clip-path="url(#window)" href="data:image/jpeg;base64,${bytes.toString('base64')}"/>
</svg>
`);
