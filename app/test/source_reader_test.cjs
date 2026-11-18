const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const root=path.join(__dirname,'../android/app/src/main');
test('source document-start script blocks modern and legacy clipboard access', async () => {
  const kotlin = fs.readFileSync(path.join(root, 'kotlin/com/gejian/gejian/MainActivity.kt'), 'utf8');
  const script = kotlin.match(/val script="""([\s\S]*?)"""/)[1];
  let nativeReads = 0;
  class Navigator {}
  Object.defineProperty(Navigator.prototype, 'clipboard', {configurable: true, get() {
    nativeReads++; return {readText() {nativeReads++;}};
  }});
  const context = vm.createContext({Navigator, DOMException, document: {execCommand: () => true}});
  context.navigator = new Navigator();
  vm.runInContext(script, context);
  await assert.rejects(context.navigator.clipboard.readText(), {name: 'NotAllowedError'});
  assert.equal(nativeReads, 0);
  assert.equal(context.document.execCommand('paste'), false);
  assert.equal(context.document.execCommand('copy'), false);
  assert.equal(context.document.execCommand('selectAll'), true);
});
