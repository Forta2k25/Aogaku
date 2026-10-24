// Synthetic image-only regression assets; generated data stays under ignored build/.
const fs=require('node:fs'),path=require('node:path');
const {createCanvas,PDFDocument}=require('../functions/node_modules/@napi-rs/canvas'),old=require('./visual_router_fixtures.cjs'),prod=require('./production_visual_router_assets.cjs');
function relation(two=false){const canvas=createCanvas(800,1000),ctx=canvas.getContext('2d');ctx.fillStyle='white';ctx.fillRect(0,0,800,1000);ctx.fillStyle='black';ctx.textAlign='center';const words=[],text=[];
 function line(s,y,size){ctx.font=size+'px Arial';const width=ctx.measureText(s).width;ctx.fillText(s,400,y);words.push({x:(400-width/2)/800,y:(y-size)/1000,w:width/800,h:(size+5)/1000});text.push(s);}
 line('Synthetic Scientific Method',55,26);const labels=two?['Observation','Question']:['Observation','Question','Hypothesis','Experiment','Conclusion','Result'];
 labels.forEach((s,i)=>{line(s,140+i*135,28);if(i<labels.length-1){ctx.font='50px Arial';ctx.fillText('↓',400,215+i*135);}});
 // Oracle deliberately omits every arrow, like the actual Vision failure.
 return {bytes:canvas.toBuffer('image/png'),probe:{text:text.join('\n'),words,blocks:words,confidence:.99}};
}
function generate(dir){fs.mkdirSync(dir,{recursive:true});prod.generate(dir);const cases=[];
 for(const [key,kind,expected]of [['plain','plain','vision_ocr'],['paragraph','screenshot','vision_ocr'],['nodes','arrows','multimodal_ai'],['concept','diagram','multimodal_ai'],['chart','chart','multimodal_ai'],['photo-text','mixed','multimodal_ai'],['table','table','multimodal_ai']]){const v=old.image(kind),file=key+'.png';fs.writeFileSync(path.join(dir,file),v.bytes);cases.push({key,file,expected,probe:v.probe});}
 for(const [key,two]of [['two-label-arrow',true],['short-arrow-flow',false]]){const v=relation(two),file=key+'.png';fs.writeFileSync(path.join(dir,file),v.bytes);cases.push({key,file,expected:'multimodal_ai',probe:v.probe});}
 // Same pixels as the failed production diagram, never re-upload the old source.
 if(!fs.readFileSync(path.join(dir,'flow.png')).equals(fs.readFileSync(path.join(dir,'short-arrow-flow.png'))))throw Error('Failed fixture pixels changed');
 cases.push({key:'mixed-pdf',file:'mixed.pdf',type:'pdf',expected:['native_text','vision_ocr','multimodal_ai'],probe:old.image('scanned').probe});return cases;
}
module.exports={generate,relation};
