'use strict';
const CrimeEconomy={
  annualCounts(rows,selection=''){
    const filter=selection?JSON.parse(selection):null,years=new Map();
    for(const r of rows){
      if(!VIEW_YEARS.includes(r.year)||!r.has_postal_reference||r.cp===null)continue;
      if(filter?.[0]==='category'&&r.nibrs_category!==filter[1])continue;
      if(filter?.[0]==='type'&&(r.nibrs_code!==filter[1]||r.nibrs_description!==filter[2]))continue;
      if(!years.has(r.year))years.set(r.year,new Map());const counts=years.get(r.year);
      counts.set(r.cp,(counts.get(r.cp)||0)+r.crime_count);
    }
    return years;
  },
  matches(zone,metric,assignments,level,min,max){
    const group=zone?assignments.get(zone.cp):undefined;
    if(level==='sin'&&group!==undefined)return false;
    if(level!==''&&level!=='sin'&&group!==Number(level))return false;
    if(min===''&&max==='')return true;
    const value=zone?.[metric.key];
    return !zone?.[metric.flag]&&typeof value==='number'&&Number.isFinite(value)&&
      (min===''||value>=Number(min))&&(max===''||value<=Number(max));
  }
};
(() => {
  let map, markers, areas, snapshot, zones, groups, countsByCP, loading=false;
  const chartSelections=new Map();
  const economyColors=['#bc6727','#8e9c8e','#16828a'],levels=['Bajo','Medio','Alto'];
  const colors=new Map([
    ['Violencia y agresiones','#b91c1c'],['Robos y hurtos a personas','#e66b12'],
    ['Delitos sexuales','#9d174d'],['Hurtos generales','#ad8a00'],
    ['Delitos contra vehículos','#2563eb'],['Allanamientos y accesos ilegales','#6d28d9'],
    ['Vandalismo e incendios','#c2410c'],['Fraudes y delitos económicos','#0d9488'],
    ['Drogas','#65a30d'],['Armas','#334155'],['Prostitución y trata','#c026d3'],
    ['Orden público, alcohol y juego','#0284c7'],['Convivencia y órdenes de protección','#8b5e34'],
    ['Maltrato animal','#15803d'],['Otros y registros especiales','#64748b'],['Sin clasificar','#858585']
  ]);
  const color=category=>colors.get(category)||'#858585';
  const typeKey=row=>JSON.stringify([row[3],row[4]]);
  const metric=()=>SocioData.metrics.find(m=>m.key===$('points-economy').value);
  const money=n=>n===null||n===undefined?'Sin dato':n.toLocaleString('es-ES',{style:'currency',currency:'USD',maximumFractionDigits:0});
  const estimate=(z,m)=>z?.[m.flag]?'Más de '+money(z[m.bound]):money(z?.[m.key]);
  function matches(zone){return CrimeEconomy.matches(zone,metric(),groups.get(metric().key).assignments,$('points-level').value,$('points-min').value,$('points-max').value)}
  function economicRows(){return snapshot.filas.filter(r=>matches(zones.get(r[6])))}
  function options(select,rows,label){
    const previous=select.value,previousLabel=select.selectedOptions[0]?.textContent;select.replaceChildren(new Option(label,''));
    for(const [key,text] of rows)select.add(new Option(text,key));
    if(previous&&!rows.some(([key])=>key===previous))select.add(new Option((previousLabel||previous).replace(/\s\([^)]*\)$/,'')+' (0)',previous));
    select.value=previous;
  }

  function show(points){
    $('socio-view').hidden=true;$('open-socio').setAttribute('aria-pressed',false);
    $('zones-view').hidden=points;$('points-view').hidden=!points;
    $('open-zones').setAttribute('aria-pressed',!points);$('open-points').setAttribute('aria-pressed',points);
    if(!points){if(streetMap)streetMap.invalidateSize();return}
    if(!map){
      map=L.map('points-map',{maxZoom:19,preferCanvas:true}).setView([47.61,-122.33],12);
      L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,
        attribution:'&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
      }).on('tileerror',()=>{$('points-tiles').textContent='No se han podido cargar todas las calles.'}).addTo(map);
      areas=L.featureGroup().addTo(map);markers=L.layerGroup().addTo(map);
      $('points-center').onclick=()=>map.setView([47.61,-122.33],12);
      $('points-areas').onchange=()=>{$('points-areas').checked?areas.addTo(map):areas.remove()};
      $('points-opacity').oninput=()=>areas.setStyle({fillOpacity:Number($('points-opacity').value)/100});
    }
    map.invalidateSize();if(!snapshot&&!loading)load($('points-month').value||'2024-01');
  }

  async function load(month){
    if(loading)return;
    if(!/^202[4-6]-(0[1-9]|1[0-2])$/.test(month)){$('points-status').textContent='Selecciona un mes entre enero de 2024 y diciembre de 2026.';return}
    if(location.protocol==='file:'){$('points-status').textContent='Abre el lanzador para consultar Gold.';return}
    loading=true;disableControls(true);snapshot=null;map.closePopup();
    markers.clearLayers();areas.clearLayers();$('points-key').replaceChildren();$('points-economy-key').replaceChildren();$('points-comparisons').replaceChildren();$('points-status').textContent='Consultando los delitos y el contexto económico…';
    try{
      const response=await fetch('/puntos/'+encodeURIComponent(month),{method:'POST',cache:'no-store',headers:{'X-Civica':'panel'}});
      const next=await response.json();if(!response.ok)throw Error(next.aviso);
      snapshot=next;$('points-month').value=next.mes||'';
      zones=new Map(next.zonas.map(z=>[z.cp,z]));
      groups=new Map(SocioData.metrics.map(m=>[m.key,SocioData.grouping(next.zonas,m)]));
      refresh();drawComparisons();
    }catch(err){snapshot=null;markers.clearLayers();areas.clearLayers();$('points-key').replaceChildren();$('points-comparisons').replaceChildren();$('points-status').textContent=err.message||'No se pudieron consultar las ubicaciones.'}
    finally{loading=false;disableControls(false)}
  }

  function disableControls(disabled){
    $('points-load').disabled=$('points-month').disabled=disabled;
    for(const name of ['category','type','economy','level','min','max','reset'])$('points-'+name).disabled=disabled||!snapshot;
  }

  function refresh(){
    if(!snapshot)return;
    const totals=new Map();for(const [,,category,,,n] of economicRows())totals.set(category,(totals.get(category)||0)+n);
    options($('points-category'),[...totals].sort((a,b)=>b[1]-a[1]).map(([cat,n])=>[cat,`${cat} (${fmt(n)})`]),'Todas las categorías');
    updateTypes();render();
  }

  function updateTypes(){
    const category=$('points-category').value,totals=new Map();
    for(const row of economicRows()){if(category&&row[2]!==category)continue;
      const key=typeKey(row);if(!totals.has(key))totals.set(key,{n:0,label:`${row[3]??'Sin código'} · ${row[4]??'Sin descripción'}`});totals.get(key).n+=row[5];
    }
    options($('points-type'),[...totals].sort((a,b)=>b[1].n-a[1].n).map(([key,{n,label}])=>[key,`${label} (${fmt(n)})`]),'Todos los tipos');
  }

  function drawAreas(){
    areas.clearLayers();const m=metric(),grouping=groups.get(m.key);
    for(const z of snapshot.zonas){const poly=z.geometry?polygons(z.geometry):[];if(!poly.length||!matches(z))continue;
      const i=grouping.assignments.get(z.cp);
      L.geoJSON({type:'MultiPolygon',coordinates:poly},{style:{color:i===undefined?'#89938d':economyColors[i],weight:1.5,
        fillColor:i===undefined?'#bfc5c0':economyColors[i],fillOpacity:Number($('points-opacity').value)/100}}).bindPopup(()=>{
        const box=document.createElement('div');element(box,'strong','CP '+z.cp+' · '+(i===undefined?'Sin nivel comparable':levels[i]));
        element(box,'div',`${fmt(countsByCP.get(z.cp)||0)} delitos de la selección en ${snapshot.mes}`);
        for(const metric of SocioData.metrics)element(box,'div',metric.label+': '+estimate(z,metric));
        element(box,'div','Población ACS: '+(z.population==null?'Sin dato':fmt(z.population)));
        element(box,'div','ACS 2020–2024; ubicación del delito, no renta de sus autores.');return box;
      }).addTo(areas);
    }
    const legend=$('points-economy-key');legend.replaceChildren();
    for(const [i,label] of levels.entries()){const span=element(legend,'span','■ '+label+'  ');span.style.color=economyColors[i]}
    element(legend,'span',`· ${m.label}. Gris: sin valor comparable. `+(grouping.low===null?'Sin importes comparables.':`Bajo ≤ ${money(grouping.low)}; medio ≤ ${money(grouping.high)}; alto > ${money(grouping.high)}.`));
  }

  function drawComparisons(){
    const container=$('points-comparisons');container.replaceChildren();
    if(!Array.isArray(snapshot.recuentos)){element(container,'p','Recarga el panel para cargar los recuentos anuales.');return}
    const categories=new Set(),types=new Map(),available=new Set(snapshot.recuentos.map(r=>r.year));
    for(const r of snapshot.recuentos){categories.add(r.nibrs_category);types.set(JSON.stringify(['type',r.nibrs_code,r.nibrs_description]),`${r.nibrs_code??'Sin código'} · ${r.nibrs_description??'Sin descripción'}`)}
    for(const m of SocioData.metrics){
      const section=element(container,'section');section.style.marginTop='18px';element(section,'h3',m.label+' · delitos por zona');
      const label=element(section,'label','Tipo de delito '),select=element(label,'select');select.className='crime-chart-type';
      select.setAttribute('aria-label',`Tipo de delito para ${m.label.toLowerCase()}`);select.add(new Option('Todos los tipos',''));
      const categoryGroup=element(select,'optgroup');categoryGroup.label='Categorías del proyecto';
      for(const cat of [...categories].sort((a,b)=>a.localeCompare(b)))categoryGroup.append(new Option(cat,JSON.stringify(['category',cat])));
      const typeGroup=element(select,'optgroup');typeGroup.label='Tipos NIBRS';
      for(const [key,text] of [...types].sort((a,b)=>a[1].localeCompare(b[1])))typeGroup.append(new Option(text,key));
      const saved=chartSelections.get(m.key)||'';if([...select.options].some(o=>o.value===saved))select.value=saved;
      const content=element(section,'div');
      function draw(){
        chartSelections.set(m.key,select.value);content.replaceChildren();
        const counts=CrimeEconomy.annualCounts(snapshot.recuentos,select.value),grouping=groups.get(m.key),year=Number(snapshot.mes.slice(0,4));
        const summary=y=>SocioData.summary(grouping,counts.get(y)).map(g=>available.has(y)?g:{...g,total:null,mean:null});
        const yearGroups=summary(year),number=n=>n===null?'—':n.toLocaleString('es-ES',{maximumFractionDigits:2});
        element(content,'p',grouping.low===null?'Sin zonas con valor económico comparable.':`Bajo: hasta ${money(grouping.low)}. Medio: más de ${money(grouping.low)} y hasta ${money(grouping.high)}. Alto: más de ${money(grouping.high)}.`);
        const wrap=element(content,'div');wrap.style.overflowX='auto';const table=element(wrap,'table'),head=element(element(table,'thead'),'tr');
        ['Nivel de zona','CP comparables',`Delitos ${year}`,'Media de delitos por zona'].forEach(text=>element(head,'th',text));
        const body=element(table,'tbody'),max=Math.max(1,...yearGroups.map(g=>g.mean??0));
        yearGroups.forEach((g,i)=>{const tr=element(body,'tr');element(tr,'th',levels[i]).scope='row';element(tr,'td',number(g.zones));element(tr,'td',number(g.total));
          const cell=element(tr,'td',number(g.mean));if(g.mean===null)return;
          const track=element(cell,'div');track.className='bar';track.style.background='#eef1ed';const fill=element(track,'i');fill.style.background=economyColors[i];fill.style.width=100*g.mean/max+'%';
        });
        element(content,'h3','Evolución anual · media de delitos por zona');
        const chart=element(content,'div');chart.className='years-chart';const series=VIEW_YEARS.map(y=>[y,summary(y)]),cap=Math.max(1,...series.flatMap(([,gs])=>gs.map(g=>g.mean??0)));
        for(const [y,gs] of series){const col=element(chart,'div');col.className='year-column';col.style.flexBasis='106px';if(y===year)col.style.background='#edf3ed';const bars=element(col,'div');bars.className='columns';
          gs.forEach((g,i)=>{const bar=element(bars,'span');bar.style.width='25px';bar.style.height=130*(g.mean??0)/cap+'px';bar.style.background=economyColors[i];element(bar,'b',number(g.mean));
            bar.title=`${y} · ${levels[i]} · ${g.zones} CP · ${number(g.total)} delitos · media: ${number(g.mean)}`;bar.setAttribute('aria-label',bar.title);bar.setAttribute('role','img');
          });element(col,'strong',y);
        }
        element(content,'p',`${grouping.assignments.size} CP con polígono y valor comparable, con grupos fijos entre años. Selección: ${select.selectedOptions[0].textContent}. Un cero indica ausencia de registros del tipo en esas zonas; un guion, año sin registros en el mart o grupo sin zonas. La media normaliza el número de zonas, no su población. Se excluyen los delitos sin CP referenciado y las zonas sin contexto comparable.`).className='note';
      }
      select.onchange=draw;draw();
    }
  }

  function render(){
    if(!snapshot)return;
    map.closePopup();markers.clearLayers();const selected=$('points-type').value,category=$('points-category').value,sites=new Map(),totals=new Map();let count=0,unknown=0;
    countsByCP=new Map();
    const eligible=economicRows();
    for(const row of eligible){
      const [lat,lon,cat,code,description,n,cp,block,neighborhood]=row;
      if((selected&&typeKey(row)!==selected)||(category&&cat!==category))continue;
      const key=`${lat},${lon}`;if(!sites.has(key))sites.set(key,{lat,lon,types:new Map(),details:new Map(),n:0});
      const site=sites.get(key);site.n+=n;site.types.set(cat,(site.types.get(cat)||0)+n);count+=n;
      totals.set(cat,(totals.get(cat)||0)+n);if(cp)countsByCP.set(cp,(countsByCP.get(cp)||0)+n);
      if(!zones.get(cp)?.has_socioeconomic_data)unknown+=n;
      const context=zones.get(cp),detail=`${cat} · ${code??'Sin código'} · ${description??'Sin descripción'} · ${block||'Sin bloque publicado'} · ${neighborhood||'Sin barrio'} · ${cp?'CP '+cp:'Sin CP'} · ${metric().label}: ${estimate(context,metric())}`;
      site.details.set(detail,(site.details.get(detail)||0)+n);
    }
    for(const {lat,lon,types,details,n} of sites.values()){
      const parts=[];let start=0;const entries=[...types].sort(([a],[b])=>a.localeCompare(b));
      for(const [cat,v] of entries){const end=start+360*v/n;parts.push(`${color(cat)} ${start}deg ${end}deg`);start=end}
      const size=Math.min(28,9+3*Math.log2(n)),dot=document.createElement('div');
      dot.style.cssText=`width:100%;height:100%;border-radius:50%;border:1px solid #fff;box-shadow:0 0 2px #163432;background:${entries.length===1?color(entries[0][0]):`conic-gradient(${parts.join(',')})`}`;
      const icon=L.divIcon({className:'crime-point',html:dot,iconSize:[size,size],iconAnchor:[size/2,size/2]});
      L.marker([lat,lon],{icon,title:`${fmt(n)} delitos`,keyboard:false}).bindPopup(()=>{
        const box=document.createElement('div');element(box,'strong',`${fmt(n)} delitos en esta ubicación`);
        for(const [label,v] of details)element(box,'div',`${label}: ${fmt(v)}`);return box;
      }).addTo(markers);
    }
    $('points-key').replaceChildren();for(const [cat,n] of [...totals].sort((a,b)=>b[1]-a[1])){
      const row=element($('points-key'),'div');element(row,'span','● ').style.color=color(cat);row.append(`${cat}: ${fmt(n)}`);
    }
    drawAreas();
    const economicExcluded=snapshot.filas.reduce((sum,r)=>sum+r[5],0)-eligible.reduce((sum,r)=>sum+r[5],0);
    $('points-status').textContent=`${snapshot.mes} · ${fmt(count)} delitos en ${fmt(sites.size)} ubicaciones · ${fmt(unknown)} de los mostrados sin correspondencia ACS · ${fmt(economicExcluded)} excluidos por el filtro económico. Los colores de puntos corresponden a nibrs_category; los polígonos, al indicador económico.`;
  }
  $('open-zones').onclick=()=>show(false);$('open-points').onclick=()=>show(true);
  $('points-load').onclick=()=>load($('points-month').value||'2024-01');$('points-type').onchange=render;
  $('points-category').onchange=()=>{$('points-type').value='';updateTypes();render()};
  $('points-economy').onchange=()=>{$('points-min').value=$('points-max').value='';refresh()};
  $('points-level').onchange=refresh;
  $('points-min').oninput=$('points-max').oninput=refresh;
  $('points-reset').onclick=()=>{for(const key of ['category','type','level','min','max'])$('points-'+key).value='';refresh()};
})();
