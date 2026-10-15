// Environment-only GCF revisions can rebuild and copy the identical source ZIP.
// Allow those generated references only after a full installed source manifest
// (including package-lock.json) matches the previously approved artifact.
const assert=require('node:assert/strict'),c=require('./production_phase5a_common.cjs');
function assertRevision(before,after,environment,installedSourceSha256){
 assert.equal(installedSourceSha256,c.SHA,'Installed full source does not match approved artifact');
 assert.equal(after.state,'ACTIVE');assert.deepEqual(after.serviceConfig.environmentVariables,environment);
 const build=structuredClone(after.buildConfig),old=before.buildConfig;
 assert(build.build.startsWith(`projects/${c.N}/locations/${c.R}/builds/`));
 for(const source of [build.source.storageSource,build.sourceProvenance.resolvedStorageSource])assert(/^\d+$/.test(source.generation));
 assert.deepEqual(build.source.storageSource,build.sourceProvenance.resolvedStorageSource,'Source provenance mismatch');
 build.build=old.build;build.source.storageSource.generation=old.source.storageSource.generation;build.sourceProvenance.resolvedStorageSource.generation=old.sourceProvenance.resolvedStorageSource.generation;
 assert.deepEqual(build,old,'Unapproved build configuration change');
 const compared=structuredClone(after);compared.buildConfig=old;compared.updateTime=before.updateTime;compared.serviceConfig.environmentVariables=before.serviceConfig.environmentVariables;compared.serviceConfig.revision=before.serviceConfig.revision;
 assert.deepEqual(compared,before,'Unapproved non-environment Function change');
 return {installedSourceSha256,fullSourceUnchanged:true,buildConfigSha256:c.metadataHash(after.buildConfig),generatedBuildReferencesChanged:c.metadataHash(after.buildConfig)!==c.metadataHash(old)};
}
module.exports={assertRevision};
