const {readFileSync}=require('node:fs');
const {runInNewContext}=require('node:vm');
const assert=require('node:assert/strict');
const code=readFileSync(require('node:path').join(__dirname,'../curiosidades.js'),'utf8');
runInNewContext(code+`
const result=CuriousData.weekend(500,250);
assert.equal(result.weekday,100);assert.equal(result.weekend,125);assert.equal(result.change,25);
assert.equal(CuriousData.weekend(100,0).change,-100);
assert.equal(CuriousData.weekend(0,10).change,null);
assert.equal(CuriousData.weekend(0,0).change,null);
assert.equal(CuriousData.weekend(5,2).change,0);
assert.equal(CuriousData.percent(2,5),40);
assert.equal(CuriousData.percent(0,5),0);
assert.equal(CuriousData.percent(0,0),null);
`,{$:()=>({}),assert});
console.log('OK: totales /5 y /2 comparados, no sumados; porcentajes y denominadores cero.');
