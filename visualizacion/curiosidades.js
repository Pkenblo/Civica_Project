'use strict';
const CuriousData={
  weekend(weekdayCount,weekendCount){
    const weekday=weekdayCount/5,weekend=weekendCount/2;
    return {weekday,weekend,change:weekday>0?100*(weekend-weekday)/weekday:null};
  },
  percent(part,total){return total>0?100*part/total:null}
};
(() => {
  const cards=[
    ['nombres','Los nombres de mascota más populares','M9 12c-3-4-7 1-4 4l7 4 7-4c3-3-1-8-4-4l-3 3-3-3ZM4 7V5m5 1V3m6 3V3m5 4V5'],
    ['horas','La hora con más delitos','M12 7v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z'],
    ['vehiculos','El bloque con más robos de coches','M3 14h18v5H3v-5Zm2 0 2-7h10l2 7M6 19v2m12-2v2M6 16h1m10 0h1'],
    ['semana','¿Más detenciones en fin de semana?','M4 5h16v16H4V5Zm0 5h16M8 3v4m8-4v4M8 14h2m4 0h2m-8 4h2'],
    ['tiroteos','Tiroteos e informes con detenciones','M12 3 3 7v6c0 4 9 8 9 8s9-4 9-8V7l-9-4Zm-4 9 3 3 5-6'],
    ['agentes','El agente con más detenciones','M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM4 21v-3c0-5 16-5 16 0v3']
  ];
  const cache=new Map(),number=n=>Number(n).toLocaleString('es-ES',{maximumFractionDigits:2});
  const sources={nombres:'DIM_LICENSES',horas:'FACT_CRIMES',vehiculos:'FACT_CRIMES, DIM_NIBRS y DIM_ADDRESS',semana:'FACT_ARRESTS y DIM_DATE',tiroteos:'FACT_CRIMES, BRIDGE_CRIME_SHOOTING_TYPES, DIM_SHOOTING_TYPE y FACT_ARRESTS',agentes:'FACT_ARRESTS y DIM_AGENT'};
  let loading=false;
  const value=(box,text,long=false)=>{const e=element(box,'p',text);e.className='fact-value'+(long?' fact-value-text':'');return e};
  const note=(box,text)=>{const e=element(box,'p',text);e.className='note';return e};
  const methodology=(box,text)=>{const details=element(box,'details');details.className='methodology';element(details,'summary','Fuente y cálculo');element(details,'p',text)};
  function shell(key,title,path){
    const card=element($('facts-grid'),'article');card.className='fact-card';card.id='fact-'+key;
    const heading=element(card,'div');heading.className='fact-heading';
    const icon=document.createElementNS('http://www.w3.org/2000/svg','svg');icon.setAttribute('viewBox','0 0 24 24');icon.setAttribute('aria-hidden','true');
    const shape=document.createElementNS(icon.namespaceURI,'path');shape.setAttribute('d',path);icon.append(shape);heading.append(icon);
    element(heading,'h3',title);return card;
  }
  function renderNames(card,rows){
    const pair=element(card,'div');pair.className='pet-name-pair';
    for(const [species,label] of [['DOG','Perros'],['CAT','Gatos']]){
      const winners=rows.filter(r=>r.species===species),first=winners[0],box=element(pair,'div');
      element(box,'h4',label);
      value(box,winners.filter(r=>r.animal_name).map(r=>r.animal_name).join(' / ')||'Sin nombres',true);
      note(box,first?.animal_name?`${number(first.license_count)} licencias${winners.length>1?' por nombre · empate':''}`:'No hay licencias con nombre en este periodo.');
    }
    methodology(card,'DIM_LICENSES. Licencias emitidas en el periodo, no animales únicos. Se excluyen nombres vacíos y se conservan los empates. '+['DOG','CAT'].map(s=>{const r=rows.find(r=>r.species===s);return `${s==='DOG'?'Perros':'Gatos'}: ${number(r?.total_licenses??0)} licencias, ${number(r?.unnamed_licenses??0)} sin nombre; ${number(r?.undated_licenses??0)} sin fecha en todo Gold.`}).join(' '));
  }
  function renderHours(card,rows){
    const peaks=rows.filter(r=>r.position===1&&r.hour!==null),first=rows[0];
    const hour=n=>String(n).padStart(2,'0')+':00';
    value(card,peaks.map(r=>`${hour(r.hour)}–${hour((r.hour+1)%24)}`).join(' / ')||'Sin delitos fechados',true);
    const pct=CuriousData.percent(peaks[0]?.crime_count??0,first?.total_crimes??0);
    note(card,pct===null?'No hay registros con fecha y hora en este periodo.':`${number(peaks[0].crime_count)} delitos · ${number(pct)} % del total${peaks.length>1?' por franja · empate':''}`);
    if(peaks.length){
      const histogram=element(card,'div');histogram.className='hour-histogram';histogram.setAttribute('role','img');histogram.setAttribute('aria-label','Distribución de delitos por hora; las franjas con más casos aparecen resaltadas.');
      const max=peaks[0].crime_count;
      for(let h=0;h<24;h++){const row=rows.find(r=>r.hour===h),bar=element(histogram,'span');bar.style.height=100*(row?.crime_count??0)/max+'%';bar.classList.toggle('is-peak',row?.position===1);bar.title=`${hour(h)}: ${number(row?.crime_count??0)} delitos`}
      const axis=element(card,'div');axis.className='hour-axis';for(const h of [0,6,12,18,23])element(axis,'span',hour(h));
    }
    methodology(card,`FACT_CRIMES. Cada crime_id cuenta una vez; se agrupa por la hora de ocurrencia, no por la de registro del informe. Se conserva la referencia horaria del origen sin asumir zona horaria. ${number(first?.total_crimes??0)} delitos fechados en el periodo; ${number(first?.undated_crimes??0)} sin fecha en todo Gold.`);
  }
  function renderVehicles(card,rows){
    const first=rows[0],winners=rows.filter(r=>r.block_address);
    value(card,winners.length?number(first.crime_count):'Sin bloque disponible');
    if(winners.length){element(card,'p','robos de vehículos'+(winners.length>1?' por bloque · empate':'' )).className='fact-unit';note(card,winners.map(r=>r.block_address).join(' / '))}
    methodology(card,`FACT_CRIMES + DIM_NIBRS + DIM_ADDRESS. Código NIBRS 240; delitos distintos por block_address. Es un bloque publicado, no la calle completa. ${number(first?.excluded_thefts??0)} de ${number(first?.total_thefts??0)} robos quedan fuera del ranking por dirección ausente u ocultada.`);
  }
  function renderWeek(card,rows){
    const r=rows[0]||{},weekday=r.weekday_count??0,weekend=r.weekend_count??0;
    const result=CuriousData.weekend(weekday,weekend),total=weekday+weekend;
    value(card,!total?(r.unclassified_arrests?'Sin días clasificables':'Sin detenciones en el periodo'):result.weekend===result.weekday?'Empate':result.weekend>result.weekday?'Fin de semana':'Entre semana',true);
    note(card,'Comparación con el ajuste propuesto: totales ÷ 5 y ÷ 2.');
    const bars=element(card,'div');bars.className='week-comparison';const max=Math.max(result.weekday,result.weekend,1);
    for(const [label,n] of [['Lun–vie ÷ 5',result.weekday],['Sáb–dom ÷ 2',result.weekend]]){
      const row=element(bars,'div'),caption=element(row,'div');caption.className='week-caption';element(caption,'span',label);element(caption,'strong',number(n));
      const track=element(row,'div');track.className='bar';const bar=element(track,'i');bar.style.width=100*n/max+'%';
    }
    if(result.change!==null)note(card,`${number(Math.abs(result.change))} % ${result.change>=0?'más':'menos'} en fin de semana con este ajuste.`);
    methodology(card,`FACT_ARRESTS + DIM_DATE. ${number(weekday)} detenciones de lunes a viernes y ${number(weekend)} en sábado o domingo. Se cuentan arrest_number distintos por fecha de ocurrencia. Son índices total/5 y total/2, no medias diarias del periodo: en semanas incompletas pueden sesgar la comparación. Para una media diaria habría que dividir por el número real de días de cada grupo, incluidos los días sin detenciones. ${number(r.unclassified_arrests??0)} sin clasificación en el calendario; ${number(r.undated_arrests??0)} sin fecha en todo Gold.`);
  }
  function renderShootings(card,rows){
    const r=rows[0]||{},total=r.shooting_count??0,linked=r.with_arrest??0,pct=CuriousData.percent(linked,total);
    value(card,pct===null?'Sin tiroteos registrados':`${number(linked)} de ${number(total)}`,pct===null);
    note(card,pct===null?'No hay delitos etiquetados como tiroteo en este periodo.':`${number(pct)} % comparten informe con alguna detención.`);
    element(card,'p','Informe compartido ≠ delito resuelto').className='fact-caution';
    methodology(card,`FACT_CRIMES + BRIDGE_CRIME_SHOOTING_TYPES + DIM_SHOOTING_TYPE + FACT_ARRESTS. Se cuenta cada delito con etiqueta de tiroteo una vez. Se comprueba si su report_id tiene alguna detención en todo el histórico, no necesariamente posterior ni por ese delito. No es una tasa de resolución. ${number(r.missing_report??0)} tiroteos sin informe no pueden cruzarse; permanecen en el denominador.`);
  }
  function renderAgents(card,rows){
    const first=rows[0],winners=rows.filter(r=>r.officer_id);
    value(card,winners.length?winners.map(r=>r.officer_id).join(' / '):'Sin agente identificado',true);
    note(card,winners.length?`${number(first.arrest_count)} detenciones${winners.length>1?' por agente · empate':''}`:'No hay detenciones con agente identificado en este periodo.');
    element(card,'p','Identificador del agente; el nombre no está publicado en Gold.').className='fact-unit';
    methodology(card,`FACT_ARRESTS + DIM_AGENT. arrest_number distintos agrupados por officer_id, no por características demográficas. ${number(first?.unidentified_arrests??0)} de ${number(first?.total_arrests??0)} detenciones sin agente identificado quedan fuera del ranking. El resultado no mide rendimiento ni implica que fuera el único agente participante.`);
  }
  const renderers={nombres:renderNames,horas:renderHours,vehiculos:renderVehicles,semana:renderWeek,tiroteos:renderShootings,agentes:renderAgents};
  function render(result){
    $('facts-grid').replaceChildren();
    for(const [key,title,path] of cards){
      const card=shell(key,title,path);
      if(!result){note(card,'Consultando…');continue}
      if(result.avisos?.[key]||!Array.isArray(result.datos?.[key])){value(card,'No disponible',true);note(card,result.avisos?.[key]||'Este dato no llegó en la consulta. Pulsa «Actualizar datos» para reintentarlo.');methodology(card,'Fuentes requeridas en DEV_GOLD.GOLD: '+sources[key]+'. Comprueba que estén publicadas y que tu rol tenga permisos SELECT.');continue}
      renderers[key](card,result.datos[key]);
    }
  }
  async function load(force=false){
    if(loading)return;
    const year=$('facts-year').value;
    if(!force&&cache.has(year)){render(cache.get(year));status(cache.get(year));return}
    loading=true;$('facts-year').disabled=$('facts-reload').disabled=true;$('facts-grid').setAttribute('aria-busy','true');
    $('facts-status').textContent='Consultando los seis datos en Gold…';render(null);
    try{
      const response=await fetch('/curiosidades/'+encodeURIComponent(year),{method:'POST',cache:'no-store',headers:{'X-Civica':'panel'}});
      const result=await response.json();if(!response.ok)throw Error(result.aviso);
      cache.set(year,result);render(result);status(result);
    }catch(error){$('facts-grid').replaceChildren();$('facts-status').textContent=(error.message||'No se pudieron cargar los datos.')+' Pulsa «Actualizar datos» para reintentar.'}
    finally{loading=false;$('facts-year').disabled=$('facts-reload').disabled=false;$('facts-grid').setAttribute('aria-busy','false')}
  }
  function status(result){
    const period=result.anio==='todos'?'2024–2026':result.anio,failed=Object.keys(result.avisos||{}).length;
    $('facts-status').textContent=`Periodo: ${period} · Lectura: ${result.fecha||'sin fecha'}`+(failed?` · ${failed} ${failed===1?'dato no disponible':'datos no disponibles'}; revisa el aviso de cada tarjeta.`:'');
  }
  $('open-facts').onclick=()=>{activateView('facts');load()};
  $('facts-year').onchange=()=>load();$('facts-reload').onclick=()=>load(true);
})();
