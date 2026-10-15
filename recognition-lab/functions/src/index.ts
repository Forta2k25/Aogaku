import {onCall,HttpsError} from "firebase-functions/v2/https";
import {defineSecret,defineString} from "firebase-functions/params";
import {assertAccess,compareImage,payload,LabError,IMAGE_MODEL,AUDIO_MODEL,ImageMode} from "./domain";
import {VisionOCR,GroqImageInterpreter,groqAudio} from "./providers";
const key=defineSecret("GROQ_API_KEY"),enabled=defineString("RECOGNITION_LAB_ENABLED",{default:"false"}),allowed=defineString("RECOGNITION_LAB_ALLOWED_UIDS",{default:"[]"});
// Separate Dev codebase: no imports/exports from production AI, no DB, bucket, queue or scheduler writes.
export const recognitionLabRun=onCall({region:"asia-northeast1",timeoutSeconds:180,memory:"1GiB",maxInstances:1,concurrency:1,secrets:[key]},async request=>{
  try {
    assertAccess(process.env.GCLOUD_PROJECT||process.env.GOOGLE_CLOUD_PROJECT,enabled.value(),request.auth?.uid,allowed.value());
    const data=request.data;
    if(data?.kind==="capabilities") {
      const models=await new GroqImageInterpreter(key.value()).availableModels();return {imageModel:IMAGE_MODEL,visionAvailable:models.includes(IMAGE_MODEL),audioModel:AUDIO_MODEL,audioAvailable:models.includes(AUDIO_MODEL)};
    }
    if(data?.kind==="image") {
      const bytes=payload(data.base64,"image",data.mime);
      return await compareImage(data.mode as ImageMode,bytes,data.mime,new VisionOCR(),new GroqImageInterpreter(key.value()));
    }
    if(data?.kind==="audio"&&data.mode==="groq_asr") {const result=await groqAudio(payload(data.base64,"audio",data.mime),data.mime,key.value());return {method:"groq_asr",results:[result],ocrTextProvidedToAI:null,finalEvidenceText:result.normalizedText,warnings:[]};}
    throw new LabError("LAB_INVALID_INPUT");
  } catch(e) {
    const code=e instanceof LabError?e.code:"LAB_PROVIDER_FAILED";
    throw new HttpsError(code==="LAB_AUTH_REQUIRED"?"unauthenticated":code.startsWith("LAB_UID")||code==="LAB_DEV_ONLY"||code==="LAB_CLOSED"?"permission-denied":"failed-precondition",code);
  }
});
