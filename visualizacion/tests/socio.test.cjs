const {readFileSync}=require('node:fs');
const {runInNewContext}=require('node:vm');
const assert=require('node:assert/strict');
const code=readFileSync(require('node:path').join(__dirname,'../socio.js'),'utf8');
const tests=`
const geometry={type:'Polygon'};
const zones=[
 {cp:'A',geometry,median_household_income:10},
 {cp:'B',geometry,median_household_income:20},
 {cp:'C',geometry,median_household_income:30},
 {cp:'D',geometry,median_household_income:10},
 {cp:'E',geometry,median_household_income:null,income_top_coded:true},
 {cp:'F',geometry:null,median_household_income:40}];
const g=SocioData.grouping(zones,SocioData.metrics[0]);
assert.equal(g.assignments.size,4);assert.equal(g.low,10);assert.equal(g.high,20);
assert.equal(g.assignments.get('A'),g.assignments.get('D'));assert.equal(g.assignments.get('E'),undefined);
const rows=[{cp:'A',year:2025,has_postal_reference:true,has_point:true,arrest_count:4},
 {cp:'A',year:2025,has_postal_reference:true,has_point:false,arrest_count:2},
 {cp:'B',year:2026,has_postal_reference:true,has_point:true,arrest_count:3},
 {cp:null,year:2025,has_postal_reference:false,has_point:true,arrest_count:1},
 {cp:'A',year:null,has_postal_reference:true,has_point:true,arrest_count:8}];
const counts=SocioData.counts(rows),summary=SocioData.summary(g,counts.get(2025));
assert.equal(summary[0].zones,2);assert.equal(summary[0].total,6);assert.equal(summary[0].mean,3);
assert.equal(summary[1].mean,0);assert.equal(summary[2].zones,1);assert.equal(counts.get(2025).size,1);
assert.equal(SocioData.summary(g,counts.get(2026))[0].mean,0);
const c=SocioData.coverage(rows,2025);assert.equal(c.total,7);assert.equal(c.hidden,2);assert.equal(c.noCP,1);assert.equal(c.noDate,8);
assert.equal(SocioData.summary(SocioData.grouping([],SocioData.metrics[0]),counts.get(2025))[0].mean,null);
`;
runInNewContext(code+tests,{$:()=>({}),polygons:()=>[[]],VIEW_YEARS:[2024,2025,2026],DEFAULT_YEAR:2024,assert});
console.log('OK: grupos fijos con empates, cero anual incluido, sin censura imputada, normalización y cobertura.');
