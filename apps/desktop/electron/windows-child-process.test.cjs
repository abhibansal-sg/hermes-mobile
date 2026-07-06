'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const ELECTRON_DIR = __dirname

function readElectronFile(name) {
  return fs.readFileSync(path.join(ELECTRON_DIR, name), 'utf8').replace(/\r\n/g, '\n')
}

function requireHiddenChildOptions(source, needle) {
  const match = needle instanceof RegExp ? needle.exec(source) : null
  const index = needle instanceof RegExp ? (match?.index ?? -1) : source.indexOf(needle)
  assert.notEqual(index, -1, `missing call site: ${needle}`)
  const snippet = source.slice(index, index + 700)
  assert.match(
    snippet,
    /hiddenWindowsChildOptions\(/,
    `expected ${needle} to wrap child-process options with hiddenWindowsChildOptions`
  )
}

test('desktop background child processes opt into hidden Windows consoles', () => {
  const source = readElectronFile('main.cjs')

  assert.match(source, /function hiddenWindowsChildOptions\(options = \{\}\)/)

  requireHiddenChildOptions(source, "execFileSync(\n          'reg'")
  requireHiddenChildOptions(source, /execFileSync\(\s*pyExe/)
  requireHiddenChildOptions(source, /spawn\(\s*resolveGitBinary\(\)/)
  requireHiddenChildOptions(source, "execFileSync('taskkill'")
  requireHiddenChildOptions(source, /spawn\(\s*command,\s*args/)
  requireHiddenChildOptions(source, "spawn('curl'")
  requireHiddenChildOptions(source, /spawn\(\s*backend\.command,\s*backend\.args/)
  requireHiddenChildOptions(source, /hermesProcess = spawn\(\s*backend\.command,\s*backend\.args/)
  requireHiddenChildOptions(source, /spawn\(\s*py,\s*\['-m', 'hermes_cli\.main', 'uninstall', '--gui-summary'\]/)

  assert.match(source, /function unwrapWindowsVenvHermesCommand\(command, backendArgs\)/)
  assert.match(source, /function getVenvSitePackagesEntries\(venvRoot\)/)
  assert.match(source, /path\.join\(venvRoot, 'Lib', 'site-packages'\)/)
  assert.match(source, /args: \['-m', 'hermes_cli\.main', \.\.\.backendArgs\]/)
})

test('desktop backend launches console python so child consoles are inherited, not pythonw', () => {
  const source = readElectronFile('main.cjs')

  // The flash fix is structural: the backend runs as a console-subsystem
  // python.exe under hiddenWindowsChildOptions() (-> CREATE_NO_WINDOW), so it
  // owns ONE windowless console that every descendant spawn inherits. Launching
  // it as GUI-subsystem pythonw.exe is what made each child allocate (and flash)
  // its own console, so the backend command must never be pythonw.
  assert.doesNotMatch(source, /pythonw\.exe'\)/, 'backend must not be launched via pythonw.exe')
  assert.doesNotMatch(
    source,
    /function getNoConsoleVenvPython\b/,
    'pythonw-conversion helper should be gone; console python is launched directly'
  )
  assert.doesNotMatch(
    source,
    /function applyWindowsNoConsoleSpawnHints\b/,
    'pythonw spawn-hint rewriter should be gone'
  )

  // Console python restores stdout, so the port is announced on the normal
  // HERMES_DASHBOARD_READY stdout line — no ready-file side channel is set.
  assert.doesNotMatch(source, /readyFile: true/, 'no backend should opt into the pythonw ready-file path')

  // Both desktop backend launches must still go through hiddenWindowsChildOptions
  // so the single backend console is created windowless.
  requireHiddenChildOptions(source, /spawn\(\s*backend\.command,\s*backend\.args/)
  requireHiddenChildOptions(source, /hermesProcess = spawn\(\s*backend\.command,\s*backend\.args/)
})

test('desktop backend teardown tree-kills Windows backend descendants', () => {
  const source = readElectronFile('main.cjs')

  assert.match(source, /require\('\.\/backend-lifecycle\.cjs'\)/)

  const helperIndex = source.indexOf('async function stopBackendChildAndWait(child')
  assert.notEqual(helperIndex, -1, 'missing backend teardown helper')
  const helperSnippet = source.slice(helperIndex, helperIndex + 700)
  assert.match(helperSnippet, /terminateBackendChild\(child/)
  assert.match(helperSnippet, /isWindows: IS_WINDOWS/)
  assert.match(helperSnippet, /forceKillProcessTree/)

  const resetIndex = source.indexOf('function resetHermesConnection()')
  assert.notEqual(resetIndex, -1, 'missing resetHermesConnection')
  const resetSnippet = source.slice(resetIndex, resetIndex + 300)
  assert.match(resetSnippet, /stopBackendChild\(hermesProcess\)/)
  assert.doesNotMatch(resetSnippet, /hermesProcess\.kill\('SIGTERM'\)/)

  const quitIndex = source.indexOf("app.on('before-quit'")
  assert.notEqual(quitIndex, -1, 'missing before-quit handler')
  const quitSnippet = source.slice(quitIndex, quitIndex + 1100)
  assert.match(quitSnippet, /finishQuitAfterManagedBackendShutdown\(event\)/)
  assert.doesNotMatch(quitSnippet, /hermesProcess\.kill\('SIGTERM'\)/)

  const willQuitIndex = source.indexOf("app.on('will-quit'")
  assert.notEqual(willQuitIndex, -1, 'missing will-quit handler')
  const willQuitSnippet = source.slice(willQuitIndex, willQuitIndex + 250)
  assert.match(willQuitSnippet, /finishQuitAfterManagedBackendShutdown\(event\)/)

  const finishIndex = source.indexOf('function finishQuitAfterManagedBackendShutdown(event)')
  assert.notEqual(finishIndex, -1, 'missing shared quit lifecycle helper')
  const finishSnippet = source.slice(finishIndex, finishIndex + 800)
  assert.match(finishSnippet, /event\.preventDefault\(\)/)
  assert.match(finishSnippet, /shutdownManagedBackends\(\)/)
  assert.doesNotMatch(finishSnippet, /hermesProcess\.kill\('SIGTERM'\)/)
})

test('desktop termination signals use lifecycle shutdown path', () => {
  const source = readElectronFile('main.cjs')

  const handlerIndex = source.indexOf('function registerBackendTerminationSignalHandlers()')
  assert.notEqual(handlerIndex, -1, 'missing backend termination signal handler registration')
  const handlerSnippet = source.slice(handlerIndex, handlerIndex + 900)
  assert.match(handlerSnippet, /process\.once\(signal/)
  assert.match(handlerSnippet, /shutdownManagedBackends\(\)/)
  assert.match(handlerSnippet, /process\.exit\(0\)/)
  assert.doesNotMatch(handlerSnippet, /hermesProcess\.kill\('SIGTERM'\)/)
  assert.match(source, /registerBackendTerminationSignalHandlers\(\)/)
})

test('intentional or interactive desktop child processes stay documented', () => {
  const source = readElectronFile('main.cjs')

  assert.match(source, /windowsHide: false/)
  assert.match(source, /handOffWindowsBootstrapRecovery/)
  assert.match(source, /'--repair', '--branch'/)
  assert.match(source, /'--update', '--branch'/)
  assert.match(source, /nodePty\.spawn\(command, args/)
  assert.match(source, /spawn\('cmd\.exe', \['\/c', 'start'/)
})

test('bootstrap PowerShell runner hides Windows console children', () => {
  const source = readElectronFile('bootstrap-runner.cjs')

  assert.match(source, /function hiddenWindowsChildOptions\(options = \{\}\)/)
  requireHiddenChildOptions(source, /spawn\(\s*ps,\s*fullArgs/)
})
