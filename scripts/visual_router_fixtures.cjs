// Synthetic local assets only. Generated binaries and OCR oracle stay under ignored build/.
const fs=require('node:fs'),path=require('node:path');
const {createCanvas,PDFDocument}=require('../functions/node_modules/@napi-rs/canvas');
const W=800,H=1000;
function draw(ctx,kind){
 ctx.fillStyle='white';ctx.fillRect(0,0,W,H);ctx.fillStyle='black';ctx.strokeStyle='black';ctx.lineWidth=3;ctx.font='22px Arial';
 const words=[];const text=[];
 const line=(s,x,y)=>{let at=x;text.push(s);for(const word of s.split(' ')){const w=ctx.measureText(word).width;ctx.fillText(word,at,y);words.push({x:at/W,y:(y-23)/H,w:w/W,h:29/H});at+=w+ctx.measureText(' ').width;}};
 const paragraph=()=>{for(let i=0;i<12;i++)line('Synthetic history lecture notes describe a simple experiment.',60,100+i*45);};
 if(kind==='screenshot')line('Lecture notes screenshot',60,55);
 if(['text','plain','screenshot','scanned','handwritten'].includes(kind))paragraph();
 if(kind==='handwritten'){ctx.beginPath();ctx.moveTo(80,680);ctx.bezierCurveTo(300,610,450,750,690,630);ctx.stroke();}
 if(['arrows','diagram'].includes(kind)){
  line('Observation',80,250);line('Question',500,250);line('Conclusion',500,650);line('Experiment',80,650);
  for(const [a,b,c,d]of [[240,240,480,240],[580,290,580,590],[470,640,250,640],[180,590,180,290]]){
   ctx.beginPath();ctx.moveTo(a,b);ctx.lineTo(c,d);ctx.stroke();ctx.beginPath();ctx.moveTo(c,d);ctx.lineTo(c-12,d-12);ctx.moveTo(c,d);ctx.lineTo(c-12,d+12);ctx.stroke();
  }
  if(kind==='diagram')for(let i=0;i<8;i++){ctx.beginPath();ctx.arc(350,460,70+i*4,0,Math.PI*2);ctx.stroke();}
 }
 if(['table','chart','mixed'].includes(kind)){
  if(kind==='mixed'){paragraph();ctx.fillStyle='#437bb8';ctx.fillRect(100,690,230,190);ctx.fillStyle='#b74365';ctx.fillRect(330,690,290,190);}
  else if(kind==='table'){for(let i=0;i<=5;i++){ctx.beginPath();ctx.moveTo(100+i*120,190);ctx.lineTo(100+i*120,790);ctx.stroke();ctx.beginPath();ctx.moveTo(100,190+i*120);ctx.lineTo(700,190+i*120);ctx.stroke();}for(let i=0;i<4;i++)line('Cell A Cell B',125,245+i*120);}
  else{line('Chart of synthetic values',110,100);ctx.beginPath();ctx.moveTo(100,200);ctx.lineTo(100,800);ctx.lineTo(700,800);ctx.stroke();for(let i=0;i<5;i++){ctx.fillStyle='#276ca9';ctx.fillRect(140+i*100,700-i*75,50,100+i*75);}ctx.fillStyle='black';}
 }
 return {text:text.join('\n'),words,blocks:words.length?[{x:.07,y:.07,w:.83,h:.6}]:[],confidence:kind==='handwritten'?.55:.98};
}
function image(kind){const canvas=createCanvas(W,H),probe=draw(canvas.getContext('2d'),kind);return {bytes:canvas.toBuffer('image/png'),probe,canvas};}
function pdf(types){const doc=new PDFDocument({title:'Synthetic Visual Router fixtures'});for(const type of types){const ctx=doc.beginPage(W,H);if(['scanned','mixed'].includes(type)){const img=image(type);ctx.drawImage(img.canvas,0,0,W,H);if(type==='mixed'){ctx.font='22px Arial';ctx.fillStyle='black';ctx.fillText('Synthetic embedded caption for a visual page',60,950);}}else draw(ctx,type);doc.endPage();}return doc.close();}
function generate(dir){fs.mkdirSync(dir,{recursive:true});const manifest={images:[],pdfs:[]};
 for(const [kind,expected]of [['plain','vision_ocr'],['handwritten','multimodal_ai'],['arrows','multimodal_ai'],['diagram','multimodal_ai'],['chart','multimodal_ai'],['screenshot','vision_ocr']]){const v=image(kind),file=kind+'.png';fs.writeFileSync(path.join(dir,file),v.bytes);manifest.images.push({file,kind,expected,probe:v.probe});}
 const types=['text','scanned','diagram','mixed','table'];
 for(const kind of types){const file=kind+'.pdf';fs.writeFileSync(path.join(dir,file),pdf([kind]));manifest.pdfs.push({file,types:[kind],expected:[{text:'native_text',scanned:'vision_ocr',diagram:'multimodal_ai',mixed:'multimodal_ai',table:'multimodal_ai'}[kind]]});}
 const mixed=Array.from({length:30},(_,i)=>[4,15,27].includes(i+1)?'diagram':i+1===6?'scanned':'text');fs.writeFileSync(path.join(dir,'mixed-30.pdf'),pdf(mixed));manifest.pdfs.push({file:'mixed-30.pdf',types:mixed,expected:mixed.map(x=>x==='text'?'native_text':x==='scanned'?'vision_ocr':'multimodal_ai')});
 fs.writeFileSync(path.join(dir,'manifest.json'),JSON.stringify(manifest,null,2));return manifest;
}
module.exports={generate,image,pdf,draw};if(require.main===module){generate(process.argv[2]||'build/visual-router-fixtures');console.log('Synthetic PDF6 / image6 fixtures generated; no cloud calls');}
