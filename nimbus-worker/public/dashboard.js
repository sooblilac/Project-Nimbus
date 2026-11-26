const API='https://nimbus-worker.gozocharlyz.workers.dev/api';
let session=null, towns=[], selected=null, locations=[], map=null, mapMarkers=[], pins=[];
const $=id=>document.getElementById(id);

function notice(text,error=false){const el=$('message');el.textContent=text;el.className='notice'+(error?' error':'');el.classList.remove('hidden');setTimeout(()=>el.classList.add('hidden'),5000)}
function tokenHeaders(){return {'Content-Type':'application/json','Authorization':'Bearer '+session.accessToken}}

async function loadLocations(){
  try{
    const response=await fetch('/philippine_locations.json',{cache:'no-store'});
    locations=await response.json();
  }catch(error){locations=[]}
}
function townName(code){
  const item=locations.find(location=>location.code===code);
  if(item?.name) return item.name+(item.province?' — '+item.province:'');
  if(code==='0401019000') return 'Nasugbu — Batangas';
  return 'Municipality '+code;
}

$('loginForm').addEventListener('submit',async event=>{
  event.preventDefault();$('loginError').classList.add('hidden');
  try{
    await loadLocations();
    const response=await fetch(API+'/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:$('username').value.trim(),password:$('password').value})});
    const data=await response.json();
    if(!response.ok) throw new Error(data.error||'Sign-in failed.');
    session=data;towns=data.townCodes;$('login').classList.add('hidden');$('app').classList.remove('hidden');$('accountName').textContent=data.username;
    renderTowns();
  }catch(error){$('loginError').textContent=error.message;$('loginError').classList.remove('hidden')}
});

function renderTowns(){
  $('towns').replaceChildren();
  for(const code of towns){
    if(code==='*') continue;
    const button=document.createElement('button');button.className='town';button.textContent=townName(code);button.dataset.code=code;button.onclick=()=>selectTown(code);$('towns').append(button);
  }
  if(towns.length && towns[0]!=='*') selectTown(towns[0]);
}

function clearForm(){
  $('classes').value='0';$('notice').value='';$('floods').replaceChildren();$('evacs').replaceChildren();$('roads').replaceChildren();pins=[];renderPins();$('savedTime').textContent='';
}
async function selectTown(code){
  selected=code;clearForm();
  [...document.querySelectorAll('.town')].forEach(button=>button.classList.toggle('active',button.dataset.code===code));
  $('townTitle').textContent=townName(code);
  initializeMap();
  try{
    const response=await fetch(API+'/towns/'+encodeURIComponent(code)+'/updates');
    const data=await response.json();
    if(data.update) loadUpdate(data.update);
    if(data.updatedAt) $('savedTime').textContent='Last saved '+new Date(data.updatedAt).toLocaleString();
  }catch(error){notice(error.message,true)}
}

function loadUpdate(update){
  $('classes').value=String(update.classes??0);$('notice').value=update.notice||'';
  for(const f of update.floodAreas||[]) addFlood(f.name,f.level,f.status);
  for(const e of update.evacuationCenters||[]) addEvac(e.name,e.status,e.percentFull);
  for(const r of update.roadStatuses||[]) addRoad(r.name,r.status);
  pins=(update.mapPins||[]).map(pin=>({category:pin.category,label:pin.label,latitude:Number(pin.latitude),longitude:Number(pin.longitude),status:pin.status,intensity:Number(pin.intensity)}));
  renderPins();
}

function addRow(container,fields){
  const row=document.createElement('div');row.className='entry';
  for(const field of fields){
    const el=document.createElement(field.tag||'input');el.type=field.type||'text';el.placeholder=field.placeholder||'';el.value=field.value||'';
    if(field.tag==='select'){for(const option of field.options||[])el.add(new Option(option.label,option.value));el.value=field.value||field.options?.[0]?.value||''}
    row.append(el);
  }
  const remove=document.createElement('button');remove.type='button';remove.className='remove';remove.textContent='Remove';remove.onclick=()=>row.remove();row.append(remove);container.append(row);
}
function addFlood(name='',level='M',status='C'){addRow($('floods'),[{placeholder:'Area name',value:name},{tag:'select',value:level,options:[{value:'H',label:'High'},{value:'M',label:'Medium'},{value:'L',label:'Low'}]},{tag:'select',value:status,options:[{value:'F',label:'Flooding'},{value:'W',label:'On watch'},{value:'C',label:'Clear'}]}])}
function addEvac(name='',status='O',percent=0){addRow($('evacs'),[{placeholder:'Center name',value:name},{tag:'select',value:status,options:[{value:'O',label:'Open'},{value:'F',label:'Full'},{value:'X',label:'Closed'}]},{placeholder:'Percent full',type:'number',value:String(percent)}])}
function addRoad(name='',status='O'){addRow($('roads'),[{placeholder:'Road name',value:name},{tag:'select',value:status,options:[{value:'O',label:'Open'},{value:'L',label:'Limited'},{value:'X',label:'Closed'}]}])}
$('addFlood').onclick=()=>addFlood();$('addEvac').onclick=()=>addEvac();$('addRoad').onclick=()=>addRoad();

function initializeMap(){
  if(!window.L) return;
  const location=locations.find(item=>item.code===selected);
  const center=location?[location.latitude,location.longitude]:[14.06694,120.63181];
  if(!map){map=L.map('pinMap').setView(center,12);L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; OpenStreetMap'}).addTo(map)}
  else{map.setView(center,12)}
  setTimeout(()=>map.invalidateSize(),100);
  map.off('click');map.on('click',event=>{$('pinLat').value=event.latlng.lat.toFixed(6);$('pinLng').value=event.latlng.lng.toFixed(6)});
  renderPins();
}

function pinStatusText(pin){
  if(pin.category==='flood') return pin.status==='F'?'Flooding':pin.status==='W'?'On watch':'No flooding now';
  if(pin.category==='evacuation') return pin.status==='O'?'Open':pin.status==='F'?'Full':'Closed';
  return pin.status==='O'?'Open':pin.status==='L'?'Limited':'Closed';
}
function markerColor(category){return category==='flood'? '#d23f5e':category==='evacuation'?'#1c9467':'#b7790a'}
function renderPins(){
  if(map){for(const marker of mapMarkers)map.removeLayer(marker);mapMarkers=[]}
  $('pinList').replaceChildren();
  for(let index=0;index<pins.length;index++){
    const pin=pins[index];
    if(map && Number.isFinite(pin.latitude)&&Number.isFinite(pin.longitude)){
      const marker=L.circleMarker([pin.latitude,pin.longitude],{radius:10+pin.intensity/12,color:'#fff',fillColor:markerColor(pin.category),fillOpacity:.95,weight:3}).addTo(map);
      marker.bindPopup(`<b>${escapeHtml(pin.label)}</b><br>${escapeHtml(pinStatusText(pin))}<br>Intensity ${pin.intensity}%`);
      mapMarkers.push(marker);
    }
    const row=document.createElement('div');row.className='pin-row';
    row.innerHTML=`<strong>${escapeHtml(pin.label)}</strong><small>${escapeHtml(pin.category)}</small><small>${pinStatusText(pin)}</small><small>${pin.intensity}%</small>`;
    const remove=document.createElement('button');remove.type='button';remove.className='remove';remove.textContent='Remove';remove.onclick=()=>{pins.splice(index,1);renderPins()};row.append(remove);$('pinList').append(row);
  }
}
function escapeHtml(value){return String(value).replace(/[&<>'"]/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[char]))}

$('pinIntensity').oninput=()=>{$('pinIntensityLabel').textContent=$('pinIntensity').value};
$('pinCategory').onchange=()=>{
  const category=$('pinCategory').value;
  const status=$('pinStatus');status.replaceChildren();
  const options=category==='flood'?[['C','Clear / No flooding'],['F','Flooding'],['W','On watch']]:category==='evacuation'?[['O','Open'],['F','Full'],['X','Closed']]:[['O','Open'],['L','Limited'],['X','Closed']];
  for(const [value,label] of options)status.add(new Option(label,value));
};
$('addPin').onclick=()=>{
  const label=$('pinLabel').value.trim();const latitude=Number($('pinLat').value);const longitude=Number($('pinLng').value);
  if(!label)return notice('Enter a speech-bubble label for the pin.',true);
  if(!Number.isFinite(latitude)||!Number.isFinite(longitude)||latitude<-90||latitude>90||longitude<-180||longitude>180)return notice('Click the map or enter valid coordinates.',true);
  pins.push({category:$('pinCategory').value,label,latitude,longitude,status:$('pinStatus').value,intensity:Number($('pinIntensity').value)});
  $('pinLabel').value='';$('pinLat').value='';$('pinLng').value='';renderPins();notice('Pin added. Publish to send it to the app.');
};

function collectFloods(){return [...$('floods').children].map(row=>{const i=row.querySelectorAll('input,select');return{name:i[0].value.trim(),level:i[1].value,status:i[2].value}}).filter(x=>x.name)}
function collectEvacs(){return [...$('evacs').children].map(row=>{const i=row.querySelectorAll('input,select');return{name:i[0].value.trim(),status:i[1].value,percentFull:Number(i[2].value)}}).filter(x=>x.name)}
function collectRoads(){return [...$('roads').children].map(row=>{const i=row.querySelectorAll('input,select');return{name:i[0].value.trim(),status:i[1].value}}).filter(x=>x.name)}

$('publish').onclick=async()=>{
  if(!selected)return notice('Select a municipality first.',true);
  const body={classes:Number($('classes').value),notice:$('notice').value,floodAreas:collectFloods(),evacuationCenters:collectEvacs(),roadStatuses:collectRoads(),mapPins:pins};
  try{const response=await fetch(API+'/towns/'+encodeURIComponent(selected)+'/updates',{method:'POST',headers:tokenHeaders(),body:JSON.stringify(body)});const data=await response.json();if(!response.ok)throw new Error(data.error||'Publish failed.');$('savedTime').textContent='Published '+new Date(data.update.updatedAt).toLocaleString();notice('Update and map pins published to NIMBUS.')}catch(error){notice(error.message,true)}
};
$('delete').onclick=async()=>{if(!selected||!confirm('Clear the published update for '+townName(selected)+'?'))return;try{const response=await fetch(API+'/towns/'+encodeURIComponent(selected)+'/updates',{method:'DELETE',headers:tokenHeaders()});const data=await response.json();if(!response.ok)throw new Error(data.error||'Clear failed.');clearForm();notice('Published municipality update cleared.')}catch(error){notice(error.message,true)}};
$('logout').onclick=async()=>{if(session)await fetch(API+'/auth/logout',{method:'POST',headers:tokenHeaders()}).catch(()=>{});session=null;location.reload()};
