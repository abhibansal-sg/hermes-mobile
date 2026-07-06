'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { EventEmitter } = require('node:events')

const {
  readBackendLifecycleState,
  reapPersistedBackendChildren,
  terminateBackendChild,
  upsertBackendLifecycleRecord
} = require('./backend-lifecycle.cjs')

function tmpStatePath(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-backend-lifecycle-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  return path.join(dir, 'backend-lifecycle.json')
}

function fakeChild(pid = 1234) {
  const child = new EventEmitter()
  child.pid = pid
  child.killed = false
  child.exitCode = null
  child.signalCode = null
  child.signals = []
  child.kill = signal => {
    child.signals.push(signal)
    if (signal === 'SIGTERM') child.killed = true
    return true
  }
  return child
}

test('persisted backend lifecycle state excludes auth tokens', t => {
  const statePath = tmpStatePath(t)

  upsertBackendLifecycleRecord(statePath, {
    pid: 4242,
    role: 'primary',
    profile: 'default',
    baseUrl: 'http://127.0.0.1:49152',
    port: 49152,
    command: '/opt/hermes/hermes',
    args: ['serve', '--host', '127.0.0.1', '--port', '0'],
    token: 'secret-token',
    env: { HERMES_DASHBOARD_SESSION_TOKEN: 'secret-token' },
    startedAt: '2026-07-06T00:00:00.000Z'
  })

  const raw = fs.readFileSync(statePath, 'utf8')
  assert.doesNotMatch(raw, /secret-token/)
  assert.doesNotMatch(raw, /HERMES_DASHBOARD_SESSION_TOKEN/)
  assert.deepEqual(readBackendLifecycleState(statePath).backends, [
    {
      pid: 4242,
      role: 'primary',
      profile: 'default',
      baseUrl: 'http://127.0.0.1:49152',
      port: 49152,
      command: '/opt/hermes/hermes',
      args: ['serve', '--host', '127.0.0.1', '--port', '0'],
      startedAt: '2026-07-06T00:00:00.000Z'
    }
  ])
})

test('stale missing backend pid is ignored and lifecycle state is cleared', async t => {
  const statePath = tmpStatePath(t)
  upsertBackendLifecycleRecord(statePath, {
    pid: 111,
    role: 'primary',
    command: 'hermes',
    args: ['serve']
  })

  const kills = []
  const results = await reapPersistedBackendChildren(statePath, {
    pidExists: () => false,
    killPid: (pid, signal) => kills.push([pid, signal])
  })

  assert.deepEqual(results, [{ pid: 111, action: 'cleared-dead' }])
  assert.deepEqual(kills, [])
  assert.equal(fs.existsSync(statePath), false)
})

test('live recorded backend pid is signaled and escalated after grace', async t => {
  const statePath = tmpStatePath(t)
  upsertBackendLifecycleRecord(statePath, {
    pid: 222,
    role: 'pool',
    profile: 'worker',
    command: '/usr/local/bin/hermes',
    args: ['--profile', 'worker', 'serve', '--host', '127.0.0.1', '--port', '0']
  })

  const kills = []
  const results = await reapPersistedBackendChildren(statePath, {
    pidExists: () => true,
    getProcessCommandLine: () => '/usr/local/bin/hermes --profile worker serve --host 127.0.0.1 --port 49321',
    killPid: (pid, signal) => kills.push([pid, signal]),
    sleep: async () => {}
  })

  assert.deepEqual(kills, [
    [222, 'SIGTERM'],
    [222, 'SIGKILL']
  ])
  assert.deepEqual(results, [{ pid: 222, action: 'reaped', signaled: true, escalated: true }])
  assert.equal(fs.existsSync(statePath), false)
})

test('PID reuse with a non-Hermes command is not killed', async t => {
  const statePath = tmpStatePath(t)
  upsertBackendLifecycleRecord(statePath, {
    pid: 333,
    role: 'primary',
    command: 'hermes',
    args: ['serve']
  })

  const kills = []
  const results = await reapPersistedBackendChildren(statePath, {
    pidExists: () => true,
    getProcessCommandLine: () => '/usr/bin/python -m unrelated_server',
    killPid: (pid, signal) => kills.push([pid, signal])
  })

  assert.deepEqual(kills, [])
  assert.deepEqual(results, [{ pid: 333, action: 'cleared-reused' }])
  assert.equal(fs.existsSync(statePath), false)
})

test('PID reuse after SIGTERM is not escalated', async t => {
  const statePath = tmpStatePath(t)
  upsertBackendLifecycleRecord(statePath, {
    pid: 334,
    role: 'primary',
    command: 'hermes',
    args: ['serve']
  })

  const kills = []
  let commandLine = '/usr/local/bin/hermes serve --host 127.0.0.1 --port 49321'
  const results = await reapPersistedBackendChildren(statePath, {
    pidExists: () => true,
    getProcessCommandLine: () => commandLine,
    killPid: (pid, signal) => {
      kills.push([pid, signal])
      if (signal === 'SIGTERM') {
        commandLine = '/usr/bin/python -m unrelated_server'
      }
    },
    sleep: async () => {}
  })

  assert.deepEqual(kills, [[334, 'SIGTERM']])
  assert.deepEqual(results, [
    { pid: 334, action: 'cleared-reused', signaled: true, escalated: false, cleared: 'reused' }
  ])
  assert.equal(fs.existsSync(statePath), false)
})

test('remote mode with no local lifecycle state does not signal processes', async t => {
  const statePath = tmpStatePath(t)
  const kills = []

  const results = await reapPersistedBackendChildren(statePath, {
    pidExists: () => {
      throw new Error('should not inspect pid without a recorded local backend')
    },
    killPid: (pid, signal) => kills.push([pid, signal])
  })

  assert.deepEqual(results, [])
  assert.deepEqual(kills, [])
  assert.equal(fs.existsSync(statePath), false)
})

test('child shutdown sends SIGTERM then escalates after bounded grace', async () => {
  const child = fakeChild(444)

  const result = await terminateBackendChild(child, {
    graceMs: 1,
    setTimeoutFn: callback => {
      callback()
      return 1
    },
    clearTimeoutFn: () => {}
  })

  assert.deepEqual(child.signals, ['SIGTERM', 'SIGKILL'])
  assert.deepEqual(result, { signaled: true, escalated: true })
})

test('Windows child shutdown escalates with process-tree kill', async () => {
  const child = fakeChild(555)
  const trees = []

  const result = await terminateBackendChild(child, {
    graceMs: 1,
    isWindows: true,
    forceKillProcessTree: pid => trees.push(pid),
    setTimeoutFn: callback => {
      callback()
      return 1
    },
    clearTimeoutFn: () => {}
  })

  assert.deepEqual(child.signals, ['SIGTERM'])
  assert.deepEqual(trees, [555])
  assert.deepEqual(result, { signaled: true, escalated: true })
})
