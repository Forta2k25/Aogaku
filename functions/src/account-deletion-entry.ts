import * as admin from "firebase-admin";
if (!admin.apps.length) admin.initializeApp();
export {preDeleteCleanup, deleteAccountServerSide, onAuthUserDelete} from "./legacy-account";
