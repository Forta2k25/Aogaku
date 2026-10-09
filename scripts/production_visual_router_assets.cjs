// Synthetic assets only; no provided course PDF or real user's media is uploaded.
const fs=require('node:fs'),path=require('node:path');
const {createCanvas,PDFDocument}=require('../functions/node_modules/@napi-rs/canvas'),fixtures=require('./visual_router_fixtures.cjs');
function flow(ctx){ctx.fillStyle='white';ctx.fillRect(0,0,800,1000);ctx.fillStyle='black';ctx.textAlign='center';ctx.font='26px Arial';ctx.fillText('Synthetic Scientific Method',400,55);
 for(const[i,label]of ['Observation','Question','Hypothesis','Experiment','Conclusion','Result'].entries()){ctx.font='28px Arial';ctx.fillText(label,400,140+i*135);if(i<5){ctx.font='50px Arial';ctx.fillText('↓',400,215+i*135);}}
}
function generate(dir){fs.mkdirSync(dir,{recursive:true});const canvas=createCanvas(800,1000);flow(canvas.getContext('2d'));fs.writeFileSync(path.join(dir,'flow.png'),canvas.toBuffer('image/png'));
 fs.writeFileSync(path.join(dir,'text.png'),fixtures.image('plain').bytes);const pdf=new PDFDocument({title:'Synthetic production Visual Router E2E'});
 let ctx=pdf.beginPage(800,1000);fixtures.draw(ctx,'text');pdf.endPage();ctx=pdf.beginPage(800,1000);ctx.drawImage(fixtures.image('scanned').canvas,0,0,800,1000);pdf.endPage();ctx=pdf.beginPage(800,1000);flow(ctx);pdf.endPage();fs.writeFileSync(path.join(dir,'mixed.pdf'),pdf.close());
}
module.exports={generate};if(require.main===module){generate(process.argv[2]);console.log('Synthetic 3-page PDF, plain image, 5-edge flow image generated');}
