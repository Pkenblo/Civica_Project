const {readFileSync}=require('node:fs');
const {runInNewContext}=require('node:vm');
const assert=require('node:assert/strict');
const code=readFileSync(require('node:path').join(__dirname,'../delitos.js'),'utf8');
const shared=readFileSync(require('node:path').join(__dirname,'../socio.js'),'utf8');
runInNewContext(code+shared+`
const metric={key:'income',flag:'censored'},assignments=new Map([['A',0],['B',2]]);
const a={cp:'A',income:50000,censored:false},b={cp:'B',income:200000,censored:false},top={cp:'C',income:null,censored:true};
assert.equal(CrimeEconomy.matches(undefined,metric,assignments,'','',''),true);
assert.equal(CrimeEconomy.matches(undefined,metric,assignments,'0','',''),false);
assert.equal(CrimeEconomy.matches(a,metric,assignments,'0','',''),true);
assert.equal(CrimeEconomy.matches(b,metric,assignments,'0','',''),false);
assert.equal(CrimeEconomy.matches(top,metric,assignments,'sin','',''),true);
assert.equal(CrimeEconomy.matches(top,metric,assignments,'',100,300000),false);
assert.equal(CrimeEconomy.matches(a,metric,assignments,'',50000,50000),true);
assert.equal(CrimeEconomy.matches(a,metric,assignments,'',50001,''),false);
const rows=[{cp:'A',year:2024,has_postal_reference:true,nibrs_category:'Drogas',nibrs_code:'35A',nibrs_description:'DRUGS',crime_count:2},
 {cp:'A',year:2024,has_postal_reference:true,nibrs_category:'Otros',nibrs_code:'90Z',nibrs_description:'OTHER',crime_count:3},
 {cp:'B',year:2025,has_postal_reference:true,nibrs_category:'Drogas',nibrs_code:'35A',nibrs_description:'DRUGS',crime_count:4},
 {cp:null,year:2024,has_postal_reference:false,nibrs_category:'Drogas',nibrs_code:'35A',nibrs_description:'DRUGS',crime_count:5},
 {cp:'A',year:2023,has_postal_reference:true,nibrs_category:'Drogas',nibrs_code:'35A',nibrs_description:'DRUGS',crime_count:10}];
const all=CrimeEconomy.annualCounts(rows),category=CrimeEconomy.annualCounts(rows,JSON.stringify(['category','Drogas'])),type=CrimeEconomy.annualCounts(rows,JSON.stringify(['type','35A','DRUGS']));
assert.equal(all.get(2024).get('A'),5);assert.equal(category.get(2024).get('A'),2);assert.equal(type.get(2025).get('B'),4);assert.equal(type.has(2023),false);
const grouping={assignments:new Map([['A',0],['B',0],['C',1]])};
const summary=SocioData.summary(grouping,type.get(2024));assert.equal(summary[0].zones,2);assert.equal(summary[0].mean,1);assert.equal(summary[1].mean,0);
`,{$:()=>({}),VIEW_YEARS:[2024,2025,2026],DEFAULT_YEAR:2024,assert});
console.log('OK: puntos sin contexto por defecto, niveles y rangos combinados, límites inclusivos y censura sin imputar.');
