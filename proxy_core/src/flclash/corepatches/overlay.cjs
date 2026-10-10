// Go overlays keep upstream submodules clean while making app-specific patches reproducible.
const fs = require('node:fs');
const path = require('node:path');
function createCoreOverlay(directory) {
  const replacements = {};
  const patches = JSON.parse(fs.readFileSync(path.join(__dirname, 'patches.json'), 'utf8'));
  for (const patch of patches) {
    const original = path.resolve(__dirname, '../core', patch.file);
    let source;
    if (patch.source) {
      if (fs.existsSync(original)) throw new Error(`Core overlay would hide an upstream file: ${patch.file}`);
      source = fs.readFileSync(path.join(__dirname, patch.source), 'utf8');
    } else {
      source = fs.readFileSync(replacements[original] || original, 'utf8');
      if (!source.includes(patch.before) || source.indexOf(patch.before) !== source.lastIndexOf(patch.before)) {
        throw new Error(`Core patch no longer matches pinned source: ${patch.file}`);
      }
      source = source.replace(patch.before, patch.after);
    }
    const replacement = path.join(directory, 'core', patch.file);
    fs.mkdirSync(path.dirname(replacement), { recursive: true });
    fs.writeFileSync(replacement, source);
    replacements[original] = replacement;
  }
  const overlay = path.join(directory, 'core-overlay.json');
  fs.writeFileSync(overlay, JSON.stringify({ Replace: replacements }));
  return overlay;
}
if (require.main === module) createCoreOverlay(path.resolve(process.argv[2]));
module.exports = { createCoreOverlay };
