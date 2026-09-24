import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SvgUtil } from './gen/SvgUtil.ts';

const here = dirname(fileURLToPath(import.meta.url));
const oldDocExample = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none"\n     stroke="#1B2330" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\n  <path d="M5 12h14M13 6l6 6-6 6"/>\n</svg>';
const fixed = SvgUtil.normalize(oldDocExample, 512);
console.log('--- normalize output ---');
console.log(fixed);
console.log('--- aspect ---');
console.log(JSON.stringify(SvgUtil.aspect(oldDocExample)));
const vOnly = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"></svg>';
console.log('--- validate viewBox-only ---');
console.log(JSON.stringify(SvgUtil.validate(vOnly)));
console.log('--- validate no-size ---');
console.log(JSON.stringify(SvgUtil.validate('<svg xmlns="http://www.w3.org/2000/svg"></svg>')));
