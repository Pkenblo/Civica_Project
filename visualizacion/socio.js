'use strict';
// Contexto único por CP; detenciones agregadas por CP-año sin sumar tasas ni totales repetidos.
const SocioData={
  metrics:[
    {key:'median_household_income',flag:'income_top_coded',bound:'income_lower_bound',label:'Renta mediana del hogar'},
    {key:'median_monthly_rent',flag:'rent_top_coded',bound:'rent_lower_bound',label:'Alquiler mensual mediano'},
    {key:'median_home_value',flag:'home_value_top_coded',bound:'home_value_lower_bound',label:'Precio mediano de vivienda'}
  ],
  grouping(zones,metric){
    const eligible=zones.filter(z=>z.geometry&&polygons(z.geometry).length&&
      !z[metric.flag]&&typeof z[metric.key]==='number'&&Number.isFinite(z[metric.key])&&z[metric.key]>=0);
    const values=eligible.map(z=>z[metric.key]).sort((a,b)=>a-b);
    const low=values.length?values[Math.ceil(values.length/3)-1]:null;
    const high=values.length?values[Math.ceil(2*values.length/3)-1]:null;
    const assignments=new Map(eligible.map(z=>[z.cp,z[metric.key]<=low?0:z[metric.key]<=high?1:2]));
    return {low,high,assignments};
  },
  counts(rows){
    const counts=new Map();
    for(const r of rows){if(!VIEW_YEARS.includes(r.year)||!r.has_postal_reference||r.cp===null)continue;
      if(!counts.has(r.year))counts.set(r.year,new Map());
      const y=counts.get(r.year);y.set(r.cp,(y.get(r.cp)||0)+r.arrest_count);
    }
    return counts;
  },
  summary(grouping,counts){
    const groups=[0,1,2].map(()=>({zones:0,total:0,mean:null}));
    for(const [cp,i] of grouping.assignments){const g=groups[i];g.zones++;g.total+=counts?.get(cp)||0}
    for(const g of groups)g.mean=g.zones?g.total/g.zones:null;
    return groups;
  },
  coverage(rows,year){
    let total=0,hidden=0,noCP=0,noDate=0;
    for(const r of rows){if(r.year===null){noDate+=r.arrest_count;continue}if(r.year!==year)continue;
      total+=r.arrest_count;if(!r.has_point)hidden+=r.arrest_count;if(!r.has_postal_reference)noCP+=r.arrest_count;
    }
    return {total,hidden,noCP,noDate};
  }
};

(() => {
  let map,roads,areas,points,snapshot,counts,groups,loading=false;
  const colors=['#bc6727','#8e9c8e','#16828a'],labels=['Bajo','Medio','Alto'];
  const id=name=>$('socio-'+name);
  const number=n=>n===null||n===undefined?'—':n.toLocaleString('es-ES',{maximumFractionDigits:2});
  const money=n=>n===null||n===undefined?'Sin dato':n.toLocaleString('es-ES',{style:'currency',currency:'USD',maximumFractionDigits:0});
  const estimate=(zone,metric)=>zone[metric.flag]?'Más de '+money(zone[metric.bound]):money(zone[metric.key]);
  const metric=()=>SocioData.metrics.find(m=>m.key===id('color').value);

  function init(){
    map=L.map('socio-map',{maxZoom:19,preferCanvas:true}).setView([47.61,-122.33],11);
    map.createPane('arrests');map.getPane('arrests').style.zIndex=450;
    roads=L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,
      attribution:'&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
    }).on('tileerror',()=>{id('selection').textContent='No se han podido cargar todas las calles.'}).addTo(map);
    areas=L.featureGroup().addTo(map);points=L.layerGroup().addTo(map);
    id('year').replaceChildren(...VIEW_YEARS.map(y=>new Option(y,y)));id('year').value=DEFAULT_YEAR;
    id('load').onclick=()=>load(id('year').value||String(DEFAULT_YEAR));id('year').onchange=()=>load(id('year').value);
    id('color').onchange=drawAreas;
    id('opacity').oninput=()=>areas.setStyle({fillOpacity:Number(id('opacity').value)/100});
    id('center').onclick=()=>map.setView([47.61,-122.33],11);
    id('fit').onclick=()=>{const b=areas.getBounds();if(b.isValid())map.fitBounds(b,{padding:[15,15]})};
    id('roads').onchange=()=>id('roads').checked?roads.addTo(map):roads.remove();
    id('points').onchange=()=>id('points').checked?points.addTo(map):points.remove();
  }

  async function load(year){
    if(loading)return;
    if(location.protocol==='file:'){id('status').textContent='Abre el lanzador para consultar el mart.';return}
    loading=true;id('load').disabled=id('year').disabled=true;
    snapshot=null;areas.clearLayers();points.clearLayers();id('comparisons').replaceChildren();id('legend').replaceChildren();id('selection').textContent='';
    id('status').textContent='Consultando las detenciones y el contexto económico…';
    try{
      const response=await fetch('/socio/'+encodeURIComponent(year),{method:'POST',cache:'no-store',headers:{'X-Civica':'panel'}});
      const result=await response.json();if(!response.ok)throw Error(result.aviso);
      snapshot=result;
      if(result.anio!==null)id('year').value=result.anio;
      if(result.anio===null){id('status').textContent='No hay detenciones fechadas para ese año.';return}
      counts=SocioData.counts(result.recuentos);
      groups=new Map(SocioData.metrics.map(m=>[m.key,SocioData.grouping(result.zonas,m)]));
      drawAreas();drawPoints();drawComparisons();
      const c=SocioData.coverage(result.recuentos,result.anio);
      id('status').textContent=`${result.anio} · ${number(c.total)} detenciones · ${number(c.total-c.hidden)} con punto utilizable · ${number(c.hidden)} sin ubicación dibujable · ${number(c.noCP)} sin CP referenciado para las estadísticas zonales. En todo el histórico hay ${number(c.noDate)} sin año; no entran en las gráficas. Lectura: ${result.fecha||'sin fecha'}.`;
    }catch(error){snapshot=null;areas.clearLayers();points.clearLayers();id('comparisons').replaceChildren();id('status').textContent=error.message||'No se pudo consultar el mart.'}
    finally{loading=false;id('load').disabled=id('year').disabled=false}
  }

  function zonePopup(z){
    const box=document.createElement('div'),m=metric(),g=groups.get(m.key).assignments.get(z.cp);
    element(box,'strong','CP '+z.cp+' · '+(g===undefined?'Sin nivel comparable':labels[g]));
    element(box,'div',`${number(counts.get(snapshot.anio)?.get(z.cp)||0)} detenciones en ${snapshot.anio}`);
    for(const m of SocioData.metrics)element(box,'div',m.label+': '+estimate(z,m));
    element(box,'div','Población ACS: '+number(z.population));
    element(box,'div','Margen de error renta (90 %): '+money(z.income_margin_of_error));
    element(box,'div',`${z.zcta_name||'Sin nombre ZCTA'} · ACS 2020–2024`);
    return box;
  }

  function drawAreas(){
    if(!snapshot||snapshot.anio===null)return;
    areas.clearLayers();const m=metric(),grouping=groups.get(m.key);let drawn=0;
    for(const z of snapshot.zonas){const poly=z.geometry?polygons(z.geometry):[];if(!poly.length)continue;drawn++;
      const i=grouping.assignments.get(z.cp);
      L.geoJSON({type:'MultiPolygon',coordinates:poly},{style:{color:i===undefined?'#89938d':colors[i],weight:1.5,fillColor:i===undefined?'#bfc5c0':colors[i],fillOpacity:Number(id('opacity').value)/100}}).bindPopup(()=>zonePopup(z)).addTo(areas);
    }
    id('legend').replaceChildren();
    for(const [i,label] of labels.entries()){const item=element(id('legend'),'span','■ '+label+'  ');item.style.color=colors[i]}
    element(id('legend'),'span',`· ${m.label}. Gris: sin valor comparable. Azul: detenciones, siempre en sus coordenadas publicadas.`);
    id('selection').textContent=`${drawn} polígonos; ${grouping.assignments.size} con valor comparable. Pulsa un punto o una zona para consultar su detalle.`;
  }

  function drawPoints(){
    points.clearLayers();const sites=new Map();
    for(const p of snapshot.puntos){const key=JSON.stringify([p.latitude,p.longitude]);
      if(!sites.has(key))sites.set(key,{lat:p.latitude,lon:p.longitude,n:0,details:[]});
      const s=sites.get(key);s.n+=p.arrest_count;s.details.push(p);
    }
    for(const s of sites.values()){
      // Agrupar solo puntos idénticos: sin redondeo extra, desplazamiento ni centros postales.
      L.circleMarker([s.lat,s.lon],{pane:'arrests',radius:Math.min(15,3+2*Math.log2(s.n)),weight:1,color:'#fff',fillColor:'#1249b0',fillOpacity:.85}).bindPopup(()=>{
        const box=document.createElement('div');element(box,'strong',`${number(s.n)} detenciones en esta ubicación · ${snapshot.anio}`);
        for(const p of s.details){element(box,'div',`${p.block_address||'Sin dirección de bloque'} · ${p.neighborhood||'Sin barrio'} · ${p.cp?'CP '+p.cp:'Sin CP asignado'} · ${number(p.arrest_count)} detenciones`)}
        element(box,'small','Ubicación publicada, aproximada por bloque.');return box;
      }).addTo(points);
    }
  }

  function drawComparisons(){
    const container=id('comparisons');container.replaceChildren();
    for(const m of SocioData.metrics){
      const section=element(container,'section');section.style.marginTop='18px';element(section,'h3',m.label+' · detenciones por zona');
      const grouping=groups.get(m.key),summary=SocioData.summary(grouping,counts.get(snapshot.anio));
      element(section,'p',grouping.low===null?'No hay zonas con valor económico comparable.':`Bajo: hasta ${money(grouping.low)}. Medio: más de ${money(grouping.low)} y hasta ${money(grouping.high)}. Alto: más de ${money(grouping.high)}. Cortes fijos para todos los años.`);
      const wrap=element(section,'div');wrap.style.overflowX='auto';const table=element(wrap,'table'),head=element(element(table,'thead'),'tr');
      ['Nivel de la zona',`CP comparables`, `Detenciones ${snapshot.anio}`,'Media de detenciones por zona'].forEach(h=>element(head,'th',h));
      const body=element(table,'tbody'),max=Math.max(1,...summary.map(g=>g.mean??0));
      summary.forEach((g,i)=>{const tr=element(body,'tr');element(tr,'th',labels[i]).scope='row';element(tr,'td',number(g.zones));element(tr,'td',number(g.total));
        const cell=element(tr,'td',number(g.mean));if(g.mean===null)return;const track=element(cell,'div');track.className='bar';track.style.background='#eef1ed';const fill=element(track,'i');fill.style.background=colors[i];fill.style.width=100*g.mean/max+'%';
      });
      element(section,'h3','Evolución anual · media de detenciones por zona');
      element(section,'p','Cada año usa únicamente sus detenciones. La muestra y los grupos económicos son fijos: también cuentan los CP con cero eventos ese año. Un guion indica que el grupo no tiene zonas comparables.');
      const chart=element(section,'div');chart.className='years-chart';
      const series=VIEW_YEARS.map(y=>[y,snapshot.anios.includes(y)?SocioData.summary(grouping,counts.get(y)):[0,1,2].map(()=>({zones:0,total:0,mean:null}))]);
      const cap=Math.max(1,...series.flatMap(([,gs])=>gs.map(g=>g.mean??0)));
      for(const [y,gs] of series){const col=element(chart,'div');col.className='year-column';col.style.flexBasis='106px';if(y===snapshot.anio)col.style.background='#edf3ed';
        const bars=element(col,'div');bars.className='columns';
        gs.forEach((g,i)=>{const bar=element(bars,'span');bar.style.width='25px';bar.style.background=colors[i];bar.style.height=130*(g.mean??0)/cap+'px';element(bar,'b',number(g.mean));
          bar.title=`${y} · ${labels[i]} · ${g.zones} CP · ${g.total} detenciones · media: ${number(g.mean)}`;bar.setAttribute('aria-label',bar.title);bar.setAttribute('role','img');
        });element(col,'strong',y);
      }
      element(section,'p',`${grouping.assignments.size} CP con polígono y valor no censurado; ${snapshot.zonas.length-grouping.assignments.size} CP fuera de esta comparación por falta de polígono o valor económico comparable. La media normaliza el número de zonas, no la población.`).className='note';
    }
  }

  $('open-socio').onclick=()=>{
    for(const name of ['zones','points','socio']){$(name+'-view').hidden=name!=='socio';$('open-'+name).setAttribute('aria-pressed',name==='socio')}
    if(!map)init();map.invalidateSize();if(!snapshot&&!loading)load(String(DEFAULT_YEAR));
  };
})();
