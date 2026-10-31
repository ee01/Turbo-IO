import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {validateOptions,entitlementsFor,validateResearchPair,navigationBuildManifest,readPrivateAmapKey,packageReport,memorySyncPackagingNotes,MEMORY_SYNC_SESSION_ID} from './package.mjs';
const o={app:'/example/Runner.app',addon:'/example/addon.dylib',profile:'/example/profile.mobileprovision',out:'/example/new-output',identity:'A'.repeat(40),device:'synthetic-device',bundle:'com.example.test'};
test('memory sync packaging adds no background mode or entitlement',()=>{
  const notes=memorySyncPackagingNotes();
  assert.equal(MEMORY_SYNC_SESSION_ID,'io.turboio.memory.sync.upload');
  assert.deepEqual(notes,{sessionIdentifier:MEMORY_SYNC_SESSION_ID,backgroundModesAdded:false,entitlementsAdded:false});
  const source=fs.readFileSync(new URL('./memory-sync/MemorySyncProtocol.m',import.meta.url),'utf8');
  assert.match(source,new RegExp(MEMORY_SYNC_SESSION_ID.replaceAll('.','\\.')));
});
test('experimental firmware packaging is explicit and original bundle only',()=>{
  assert.throws(()=>validateOptions({...o,'experimental-ota':'R3'}));
  assert.throws(()=>validateOptions({...o,bundle:'com.rayneo.venus.pub','experimental-ota':'unknown'}));
  validateOptions({...o,bundle:'com.rayneo.venus.pub','experimental-ota':'R3'});
});
test('local packaging requires explicit paths and credentials',()=>{validateOptions(o);for(const bad of [{app:'relative.app'},{out:'/example/bad.app'},{identity:'not-a-cert'},{device:''},{bundle:'bad'},{product:'anything'}])assert.throws(()=>validateOptions({...o,...bad}));});
test('profile authority is preserved, never grant push implicitly',()=>{const p={certs:[o.identity],devices:[o.device],expires:'2099-01-01',entitlements:{'application-identifier':'EXAMPLE.*','keychain-access-groups':['EXAMPLE.*']}};const e=entitlementsFor(p,o);assert.equal(e['application-identifier'],'EXAMPLE.com.example.test');assert(!e['aps-environment']);assert.equal(p.entitlements['application-identifier'],'EXAMPLE.*');for(const bad of [{expires:'2000-01-01'},{certs:[]},{devices:[]},{entitlements:{'application-identifier':'EXAMPLE.com.another'}}])assert.throws(()=>entitlementsFor({...p,...bad},o));});

test('TNV1 packaging cannot cross-wire old firmware or addon',()=>{
  const n={...o,bundle:'com.rayneo.venus.pub','experimental-ota':'TNV1',firmware:'/example/TNV1.zip'};
  validateOptions(n);
  assert.throws(()=>validateOptions({...n,firmware:undefined}));
  assert.throws(()=>validateOptions({...n,'experimental-ota':'R3'}));
  assert.throws(()=>validateResearchPair('_TNVStart','R3'));
  assert.throws(()=>validateResearchPair('','TNV1',Buffer.alloc(0)));
  assert.throws(()=>validateResearchPair('_TNVStart','TNV1',Buffer.alloc(9258094)));
  validateResearchPair('',undefined);
  validateResearchPair('','R3');
});

test('TMU1 needs music and navigation symbols and exact new ZIP',()=>{
  const n={...o,bundle:'com.rayneo.venus.pub','experimental-ota':'TMU1',firmware:'/example/TMU1.zip'};
  validateOptions(n);
  assert.throws(()=>validateOptions({...n,firmware:undefined}));
  for(const symbols of ['', '_TNVStart', '_TMMusicConsume'])assert.throws(()=>validateResearchPair(symbols,'TMU1',Buffer.alloc(0)));
  assert.throws(()=>validateResearchPair('_TNVStart _TMMusicConsume','TNV1',Buffer.alloc(0)));
  assert.throws(()=>validateResearchPair('_TNVStart _TMMusicConsume','TMU1',Buffer.alloc(9468398)));
});

test('TFP1 requires matching focus, music, navigation and exact release',()=>{
 const n={...o,bundle:'com.rayneo.venus.pub','experimental-ota':'TFP1',firmware:'/example/FOCUS04.zip'};
 validateOptions(n);assert.throws(()=>validateOptions({...n,firmware:undefined}));
 const symbols='_TNVStart _TMMusicConsume _TFFocusConsume';
 for(const wrong of ['','_TNVStart','_TNVStart _TMMusicConsume'])assert.throws(()=>validateResearchPair(wrong,'TFP1',Buffer.alloc(0)));
 assert.throws(()=>validateResearchPair(symbols,'TMU1',Buffer.alloc(0)));
 assert.throws(()=>validateResearchPair(symbols,'TFP1',Buffer.alloc(9300112)));
 if(process.env.TIO_FOCUS_RELEASE_ZIP){
  const b=fs.readFileSync(process.env.TIO_FOCUS_RELEASE_ZIP);validateResearchPair(symbols,'TFP1',b);
  const bad=Buffer.from(b);bad[100]^=1;assert.throws(()=>validateResearchPair(symbols,'TFP1',bad));
 }
});


test('daily native client never carries an OTA route or candidate',()=>{
 const daily='_TIODailyNavigationBuild _TNVStart';
 validateResearchPair(daily,undefined);
 for(const extra of [' _TIOOTAFlashBuild',' _TIOTLC1UpgradeBuild',' _TMMusicConsume',' _TFFocusConsume'])assert.throws(()=>validateResearchPair(daily+extra,undefined));
 for(const kind of ['R3','TNV1','TMU1','TFP1','TLC1'])assert.throws(()=>validateResearchPair(daily,kind,Buffer.alloc(1)));
 assert.throws(()=>validateResearchPair('_TIODailyNavigationBuild',undefined));
 assert.throws(()=>validateResearchPair(daily,undefined,Buffer.alloc(1)));
});
test('TLC1 requires its own tool and exact immutable candidate',()=>{
 const n={...o,bundle:'com.rayneo.venus.pub','experimental-ota':'TLC1',firmware:'/example/TLC1.zip'};
 validateOptions(n);
 assert.throws(()=>validateOptions({...n,firmware:undefined}));
 for(const symbols of ['', '_TIOOTAFlashBuild','_TIOTLC1UpgradeBuild','_TIOTLC1UpgradeBuild _TIOOTAFlashBuild _TNVStart'])assert.throws(()=>validateResearchPair(symbols,'TLC1',Buffer.alloc(9322471)));
 assert.throws(()=>validateResearchPair('_TIOTLC1UpgradeBuild _TIOOTAFlashBuild',undefined));
 if(process.env.TIO_TLC1_RELEASE_ZIP){
  const bytes=fs.readFileSync(process.env.TIO_TLC1_RELEASE_ZIP);
  validateResearchPair('_TIOTLC1UpgradeBuild _TIOOTAFlashBuild','TLC1',bytes);
  const corrupt=Buffer.from(bytes);corrupt[100]^=1;
  assert.throws(()=>validateResearchPair('_TIOTLC1UpgradeBuild _TIOOTAFlashBuild','TLC1',corrupt));
 }
});

test('daily manifest records unavailable SDK and control contract honestly',()=>{
 const b=navigationBuildManifest('_TIODailyNavigationBuild',Buffer.from('synthetic'),'a'.repeat(40),'b'.repeat(64));
 assert.equal(b.sdkVersions,null);assert.equal(b.verifiedControlContractVersion,null);
 assert.equal(b.physicalVerified,false);assert.equal(b.otaToolBuild,false);
 assert.equal(b.lifelogPolicy,'pause-restore');
 assert.equal(navigationBuildManifest('',Buffer.alloc(0),'a'.repeat(40),'b'.repeat(64)),null);
 assert.throws(()=>navigationBuildManifest('_TIODailyNavigationBuild',Buffer.alloc(0),'unknown','b'.repeat(64)));
 assert.equal('apiKey' in b,false);
});

test('private AMap key file stays out of the package report',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'amap-key-'));
 const file=path.join(dir,'amap-ios.local.json');
 const secret='0123456789abcdef0123456789abcdef';
 fs.writeFileSync(file,JSON.stringify({bundleIdentifier:'com.rayneo.venus.pub',apiKey:secret})+'\n',{mode:0o600});
 assert.deepEqual(readPrivateAmapKey(file),{bundleIdentifier:'com.rayneo.venus.pub',apiKey:secret});
 fs.chmodSync(file,0o644);assert.throws(()=>readPrivateAmapKey(file),/amap_key_file_private/);
 fs.chmodSync(file,0o600);fs.writeFileSync(file,JSON.stringify({apiKey:'short',bundleIdentifier:'com.rayneo.venus.pub'}));
 assert.throws(()=>readPrivateAmapKey(file),/amap_key_file_private/);
 assert.throws(()=>readPrivateAmapKey('relative.json'),/amap_key_file_required/);
 const report=packageReport({status:'SIGNED_NOT_DEVICE_ACCEPTED',amapKeySeeded:true},secret);
 assert.equal(report.amapKeySeeded,true);assert.equal(JSON.stringify(report).includes(secret),false);
 assert.throws(()=>packageReport({note:secret},secret),/amap_key_leaked_to_report/);
 const ui=fs.readFileSync(new URL('../firmware-research/strix-1.0.4.12/native-navigation/phone/NavigationUI.m',import.meta.url),'utf8');
 assert.match(ui,/BootstrapKey\(\)/);assert.doesNotMatch(ui,/apiKey"\s*:\s*"[0-9a-fA-F]{32}"/);
});
