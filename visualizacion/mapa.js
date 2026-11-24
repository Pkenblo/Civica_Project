'use strict';
let streetMap, roads, postal, bubbles;
const areas=new Map(), years=new Map();
const enoughLicenses=counts=>counts.reduce((sum,n)=>sum+n,0)>=50;
const edges={cats:{name:'Más gatos que perros',color:'#7053b0'},dogs:{name:'Más perros que gatos',color:'#c35d15'},neutral:{name:'Empate o sin datos',color:'#687573'}};
function majority(row){if(!row)return 'neutral';const [dogs,cats]=licenses(row);return dogs===cats?'neutral':dogs>cats?'dogs':'cats'}
const marts={
  vehiculos:{label:'Robos de vehículos',index:3,definition:'Robos de vehículos de motor (NIBRS 240).'},
  hurtos:{label:'Robos y hurtos seleccionados',index:8,definition:'Incluye atracos y hurtos seleccionados (120, 23A, 23B y 23H); el mart no distingue el tipo de víctima.'},
  homicidios:{label:'Tiroteos u homicidios',index:13,definition:'Delitos con etiqueta de tiroteo o clasificados como homicidio (09A, 09B o 09C). Cada delito cuenta una sola vez. No es un recuento de víctimas.'}
};
let activeMart=marts.vehiculos;
const martLabel=()=>activeMart.label;
const crimeCount=row=>row[activeMart.index];
// Un mismo recuento alimenta los círculos, los bordes y los grupos de la tabla.
function licenses(row){return $('modo').checked?row.slice(9,13):row.slice(4,8)}
function licensePeriod(y){return $('modo').checked?`hasta ${y} inclusive`:`de ${y}`}

function initMap(){
  streetMap=L.map('map',{minZoom:7,maxZoom:19,preferCanvas:true}).setView([47.61,-122.33],11);
  roads=L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{
    maxZoom:19,attribution:'&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
  }).on('tileerror',()=>{$('tile-note').textContent='No se han podido cargar todas las calles. Los datos por CP siguen disponibles.'}).addTo(streetMap);
  postal=L.featureGroup().addTo(streetMap);bubbles=L.layerGroup().addTo(streetMap);
  for(const r of data.rows){
    if(r[0]==='geo'){
      const parts=polygons(r[2]);if(!parts.length)continue;
      const area=L.geoJSON({type:'MultiPolygon',coordinates:parts}).addTo(postal);
      areas.set(r[1],area);
    }else if(r[0]==='comparacion'&&VIEW_YEARS.includes(r[2])){
      if(!years.has(r[2]))years.set(r[2],new Map());years.get(r[2]).set(r[1],r);
    }
  }
  for(const y of VIEW_YEARS)for(const id of ['anio','group-year'])element($(id),'option',y);
  for(const id of ['anio','group-year'])$(id).value=DEFAULT_YEAR;
  if(years.size)element($('group-year'),'option','Todos (2024–2026)').value='todos';
  const hasHistory=years.size>0&&data.rows.every(r=>r[0]!=='comparacion'||r.length>=13);
  $('modo').disabled=!hasHistory;
  $('modo').checked=hasHistory;
  for(const [view,mart] of Object.entries(marts))$('serie').querySelector(`[value="${view}"]`).disabled=!data.rows.some(r=>r[0]==='comparacion'&&Number.isInteger(r[mart.index]));
  $('mart-status').hidden=!$('serie').querySelector('[value="homicidios"]').disabled;
  $('mart-status').textContent=data.aviso_homicidios||'Esta lectura no incluye tiroteos u homicidios. Reinicia el panel y comprueba el acceso al mart.';
  function updateMart(){
    activeMart=marts[$('serie').value];
    const label=martLabel();$('map-title').textContent=label+' y licencias de mascotas';
    $('mart-note').textContent=activeMart.definition;
    renderMap();renderGroups();
  }
  $('serie').onchange=updateMart;
  $('modo').onchange=updateMart;
  $('seattle').onclick=()=>streetMap.setView([47.61,-122.33],11);
  $('extent').onclick=()=>{const bounds=postal.getBounds();if(bounds.isValid())streetMap.fitBounds(bounds,{padding:[8,8]})};
  $('calles').onchange=()=>{if($('calles').checked)roads.addTo(streetMap);else roads.remove();$('tile-note').textContent=''};
  $('animal').onchange=renderMap;
  for(const id of ['map-min-licenses','min-licenses'])$(id).onchange=()=>{
    $('min-licenses').checked=$('map-min-licenses').checked=$(id).checked;renderMap();renderGroups();
  };
  $('anio').onchange=()=>{
    if($('group-year').value!=='todos')$('group-year').value=$('anio').value;
    renderMap();renderGroups();
  };
  $('group-year').onchange=()=>{
    if($('group-year').value!=='todos'){$('anio').value=$('group-year').value;renderMap()}
    renderGroups();
  };
  updateMart();
}

function summarize(year,mart,annual){
  const groups={cats:{...edges.cats,n:0,sum:0},dogs:{...edges.dogs,n:0,sum:0}};
  const filter=$('min-licenses').checked;
  let ties=0,empty=0,below=0;
  for(const [cp,row] of year||[]){if(!areas.has(cp))continue;
    const counts=annual?row.slice(4,8):licenses(row);
    if(filter&&!enoughLicenses(counts)){below++;continue}
    const [dogs,cats]=counts;
    if(cats===dogs){if(cats===0)empty++;else ties++;continue}
    const g=groups[cats>dogs?'cats':'dogs'];g.n++;g.sum+=row[mart.index];
  }
  return {groups,ties,empty,below};
}

function drawTable(body,groups){
  const max=Math.max(...Object.values(groups).map(g=>g.n?g.sum/g.n:0));
  for(const g of Object.values(groups)){const tr=element(body,'tr');element(tr,'th',g.name).scope='row';element(tr,'td',fmt(g.n));element(tr,'td',fmt(g.sum));
    const cell=element(tr,'td');if(!g.n){cell.textContent='Sin zonas';continue}
    const mean=g.sum/g.n;cell.textContent=mean.toLocaleString('es-ES',{maximumFractionDigits:2});
    const track=element(cell,'div');track.className='bar';track.style.background='#edf0ec';track.setAttribute('aria-hidden','true');
    const fill=element(track,'i');fill.style.background=g.color;fill.style.width=`${max?100*mean/max:0}%`;
  }
}

function drawYears(chart,mart){
  const series=VIEW_YEARS.map(y=>[y,Object.values(summarize(years.get(y),mart,true).groups)]);
  const max=Math.max(1,...series.flatMap(([,gs])=>gs.map(g=>g.n?g.sum/g.n:0)));
  for(const [y,groups] of series){const col=element(chart,'div');col.className='year-column';const bars=element(col,'div');bars.className='columns';
    for(const g of groups){const mean=g.n?g.sum/g.n:null,text=mean===null?'—':mean.toLocaleString('es-ES',{maximumFractionDigits:2});
      const bar=element(bars,'span');bar.style.height=`${130*(mean??0)/max}px`;bar.style.background=g.color;element(bar,'b',text);
      bar.title=`${y} · ${g.name} · ${g.n} zonas · ${g.sum} casos · media: ${text}`;bar.setAttribute('aria-label',bar.title);bar.setAttribute('role','img');
    }element(col,'strong',y);
  }
}

function allYearsByCP(){
  const combined=new Map();
  for(const year of years.values())for(const [cp,row] of year){
    // Solo 2024–2026; sumar emisiones anuales, nunca los saldos acumulados.
    if(!combined.has(cp)){combined.set(cp,[])}
    const sum=combined.get(cp);for(const i of [4,5,6,7,...Object.values(marts).map(m=>m.index)]){
      if(Number.isInteger(row[i]))sum[i]=(sum[i]??0)+row[i];
    }
  }
  return combined;
}

function renderGroups(){
  const out=$('comparativas'),y=$('group-year').value,all=y==='todos',year=all?allYearsByCP():years.get(+y);out.replaceChildren();
  for(const mart of Object.values(marts)){
    const block=$('comparativa').content.firstElementChild.cloneNode(true);out.append(block);
    block.querySelector('.comparison-title').textContent=mart.label;
    if(!year||!Number.isInteger(year.values().next().value?.[mart.index])){block.querySelector('.definition').textContent='Sin datos del indicador. Recarga con conexión.';continue}
    block.querySelector('.definition').textContent=mart.definition;
    const {groups,ties,empty,below}=summarize(year,mart,all);drawTable(block.querySelector('tbody'),groups);
    const period=all?`Periodo 2024–2026. Se suman los casos y licencias anuales disponibles por CP. Cada CP se clasifica una sola vez según la especie mayoritaria en todo el periodo. La media es el total de casos del periodo por zona.`:`Tabla: licencias ${licensePeriod(y)} y casos de ${y}.`;
    const sample=$('min-licenses').checked?`${below} CP excluidos por tener menos de 50 licencias. `:'';
    block.querySelector('.scope').textContent=`${period} La media incluye las zonas con cero casos. ${sample}Otras exclusiones: ${ties} CP con empate y ${empty} sin licencias de gatos ni perros. Solo se comparan CP con polígono.`;
    drawYears(block.querySelector('.years-chart'),mart);
  }
}

function petIcon(ratios,maxRatio,kinds){
  const diameters=ratios.map(r=>52*Math.sqrt(r/maxRatio));
  const box=document.createElement('div');box.style.cssText='display:flex;align-items:center;gap:2px;height:100%';
  diameters.forEach((d,i)=>{if(!d)return;const image=element(box,'span'),cat=kinds[i]==='cat';
    image.style.cssText=`width:${d}px;height:${d}px;flex:none;filter:drop-shadow(0 1px 1px #fff)`;
    // SVG local: el mismo dibujo y tamaño en todos los equipos, sin imágenes externas.
    image.innerHTML=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="${cat?'Gato':'Perro'}" style="display:block;width:100%;height:100%">
      ${cat?'<path d="M10 31 7 7 25 18Q32 14 39 18L57 7 54 31Q59 57 32 59 5 57 10 31Z" fill="#c9b8ef" stroke="#7053b0" stroke-width="3"/><path d="m12 14 3 13 8-6M52 14l-3 13-8-6" fill="#efb9d1"/>':'<path d="M19 14Q3 10 4 37 5 49 17 43L25 20M45 14Q61 10 60 37 59 49 47 43L39 20" fill="#ae5926" stroke="#753706" stroke-width="2"/><path d="M17 25Q17 10 32 11 47 10 47 25L50 42Q49 59 32 59 15 59 14 42Z" fill="#f1b36f" stroke="#ad571d" stroke-width="3"/>'}
      <ellipse cx="32" cy="44" rx="13" ry="9" fill="#fff2e5"/><circle cx="22" cy="32" r="3" fill="#252d35"/><circle cx="42" cy="32" r="3" fill="#252d35"/>
      <path d="M27 40Q32 36 37 40L32 45Z" fill="#463447"/><path d="M32 45v4m-6-1q6 7 12 0" fill="none" stroke="#463447" stroke-width="2"/>
      ${cat?'<path d="m21 43-16-3m16 8L4 50m39-7 16-3m-16 8 17 2" stroke="#7053b0" stroke-width="2"/>':'<path d="M29 51v3q3 5 6 0v-3" fill="#dc7b8d"/>'}</svg>`;
  });
  const w=diameters[0]+diameters[1]+(diameters.every(d=>d>0)?2:0),h=Math.max(...diameters);
  return L.divIcon({className:'paired-marker',html:box,iconSize:[w,h],iconAnchor:[w/2,h/2]});
}

function renderMap(){
  const year=years.get(Number($('anio').value)),species=$('animal').value,dual=species==='ambos';
  $('period-note').textContent=$('modo').disabled?'Esta copia no contiene acumulados. Reconstruye el mart y recarga con conexión.':`Comparación: licencias emitidas ${licensePeriod($('anio').value)} y casos de ${$('anio').value}. Una licencia histórica no garantiza que el animal siga viviendo en ese CP.`;
  const totals=new Map(),points=[];
  const filter=$('map-min-licenses').checked;
  const shown=new Set([...areas.keys()].filter(cp=>!filter||(year?.has(cp)&&enoughLicenses(licenses(year.get(cp))))));
  if(year)for(const [cp,row] of year){if(!shown.has(cp))continue;
    const pets=licenses(row),ns=dual?[pets[1],pets[0]]:[species==='0'?pets.reduce((a,n)=>a+n,0):pets[Number(species)-4]],thefts=crimeCount(row);
    const labels=dual?['gatos','perros']:[$('animal').selectedOptions[0].textContent.toLowerCase()];
    const ratios=ns.map(n=>thefts?n/thefts:null);
    const details=ns.map((n,i)=>`${fmt(n)} licencias (${labels[i]})`+(thefts?`: ${ratios[i].toLocaleString('es-ES',{maximumSignificantDigits:3})} por caso`:''));
    points.push({cp,ratios,label:[`CP ${cp}`,`${fmt(thefts)} casos`,...details,...(thefts?[]:['Sin casos: cociente no definido'])].join(' · ')});totals.set(cp,thefts);
  }
  const byCP=new Map(points.map(p=>[p.cp,p])),maxRatio=Math.max(0,...points.flatMap(p=>p.ratios));
  const max=Math.max(0,...Array.from(shown,cp=>totals.get(cp)||0));bubbles.clearLayers();
  const key=$('border-key');key.replaceChildren();key.setAttribute('aria-label',`Bordes según las licencias${year?' '+licensePeriod($('anio').value):''}`);
  for(const [kind,edge] of Object.entries(edges)){const item=element(key,'span');item.style.cssText='display:inline-block;margin-right:1em';
    const line=element(item,'span');line.style.cssText=`display:inline-block;width:1.5em;vertical-align:middle;margin-right:.3em;border-top:3px ${kind==='neutral'?'dashed':'solid'} ${edge.color}`;item.append(edge.name)}
  for(const [cp,area] of areas){
    if(!shown.has(cp)){postal.removeLayer(area);continue}
    if(!postal.hasLayer(area))postal.addLayer(area);
    const p=byCP.get(cp),n=totals.get(cp)||0,t=max?n/max:0;
    const color=[224-217*t,239-148*t,232-147*t].map(Math.round);
    const row=year?.get(cp),kind=majority(row),edge=edges[kind];
    area.setStyle({color:edge.color,weight:kind==='neutral'?1.3:3,dashArray:kind==='neutral'?'4 3':null,fillColor:`rgb(${color})`,fillOpacity:n?.58:.12});
    const info=row?(kind==='neutral'?(licenses(row)[0]?'Empate':'Sin licencias de perros ni de gatos'):edge.name):'Sin datos de licencias';
    const msg=(p?p.label:`CP ${cp} · Sin datos comparables`)+' · '+info;
    const select=()=>{$('place').textContent=msg};area.off('mouseover click').on('mouseover click',select);
    if(p?.ratios.some(r=>r>0)){const pos=area.getBounds().getCenter();
      const kinds=dual?['cat','dog']:species==='5'?['cat']:species==='4'?['dog']:null;
      const marker=kinds?L.marker(pos,{icon:petIcon(p.ratios,maxRatio,kinds),title:msg}):L.circleMarker(pos,{radius:26*Math.sqrt(p.ratios[0]/maxRatio),weight:1,color:'#753706',fillColor:'#eb7a32',fillOpacity:.76});
      marker.addTo(bubbles).on('mouseover click',select)}
  }
  $('legend').textContent='0 casos';$('max').textContent=fmt(max);
  $('place').textContent='Selecciona un código postal para consultar sus cifras.';
  const iconLabel=dual?'Gatos morados y perros naranjas':species==='5'?'Gatos morados':species==='4'?'Perros naranjas':null;
  $('counts').textContent=year?(iconLabel?iconLabel: 'Círculos naranjas')+': tamaño según licencias por caso. Sin casos no hay cociente; sin licencias no hay marcador.':`Esta lectura no contiene datos para ${$('anio').value}.`;
  if(filter)element($('counts'),'p',`${shown.size} de ${areas.size} zonas visibles · mínimo 50 licencias.`);
}
