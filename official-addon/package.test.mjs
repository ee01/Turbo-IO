import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {validateOptions,entitlementsFor,validateResearchPair,memorySyncPackagingNotes,MEMORY_SYNC_SESSION_ID} from './package.mjs';
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
