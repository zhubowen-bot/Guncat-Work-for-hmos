import { PathMatcher } from './gen/PathMatcher.ts';

const P = PathMatcher;
const regs = P.compileList('output/{docx,xlsx}/*.docx', null);
console.log('n regs:', regs.length);
for (const r of regs) {
  console.log('reg:', r.source);
}
console.log('matchAny output/docx/r.docx:', P.matchAny('output/docx/r.docx', regs));
const re = P.compile('output/{docx,xlsx}/*.docx', null);
console.log('single compile:', re.source, re.test('output/docx/r.docx'));

