'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const BACKEND_LIFECYCLE_SCHEMA_VERSION = 1

function normalizeArgs(args) {
  return Array.isArray(args) ? args.map(arg => String(arg)) : []
}

function looksLikeHermesBackend(command, args, liveCommandLine = '') {
  const haystack = [command, ...normalizeArgs(args), liveCommandLine].filter(Boolean).join(' ').toLowerCase()
  if (!haystack.includes('hermes')) return false
  if (/\bserve\b/.test(haystack)) return true
  return /\bdashboard\b/.test(haystack) && /--no-open\b/.test(haystack)
}

function sanitizeRecord(record) {
  const pid = Number(record?.pid)
  if (!Number.isInteger(pid) || pid <= 0) return null
  const args = normalizeArgs(record.args)
  return {
    pid,
    role: record.role === 'pool' ? 'pool' : 'primary',
    profile: record.profile ? String(record.profile) : null,
    baseUrl: record.baseUrl ? String(record.baseUrl) : null,
    port: Number.isInteger(Number(record.port)) ? Number(record.port) : null,
    command: record.command ? String(record.command) : '',
    args,
    startedAt: record.startedAt ? String(record.startedAt) : new Date().toISOString()
  }
}

function readBackendLifecycleState(statePath, fsImpl = fs) {
  try {
    const raw = fsImpl.readFileSync(statePath, 'utf8')
    const parsed = JSON.parse(raw)
    if (parsed?.schemaVersion !== BACKEND_LIFECYCLE_SCHEMA_VERSION) {
      return { schemaVersion: BACKEND_LIFECYCLE_SCHEMA_VERSION, backends: [] }
    }
    const backends = Array.isArray(parsed.backends) ? parsed.backends.map(sanitizeRecord).filter(Boolean) : []
    return { schemaVersion: BACKEND_LIFECYCLE_SCHEMA_VERSION, backends }
  } catch {
    return { schemaVersion: BACKEND_LIFECYCLE_SCHEMA_VERSION, backends: [] }
  }
}

function writeBackendLifecycleState(statePath, state, fsImpl = fs) {
  const backends = Array.isArray(state?.backends) ? state.backends.map(sanitizeRecord).filter(Boolean) : []
  fsImpl.mkdirSync(path.dirname(statePath), { recursive: true })
  fsImpl.writeFileSync(
    statePath,
    `${JSON.stringify({ schemaVersion: BACKEND_LIFECYCLE_SCHEMA_VERSION, backends }, null, 2)}\n`,
    'utf8'
  )
}

function upsertBackendLifecycleRecord(statePath, record, fsImpl = fs) {
  const sanitized = sanitizeRecord(record)
  if (!sanitized) return
  const state = readBackendLifecycleState(statePath, fsImpl)
  const rest = state.backends.filter(existing => existing.pid !== sanitized.pid)
  writeBackendLifecycleState(statePath, { backends: [...rest, sanitized] }, fsImpl)
}

function removeBackendLifecycleRecord(statePath, pid, fsImpl = fs) {
  const numericPid = Number(pid)
  if (!Number.isInteger(numericPid) || numericPid <= 0) return
  const state = readBackendLifecycleState(statePath, fsImpl)
  const backends = state.backends.filter(existing => existing.pid !== numericPid)
  if (backends.length === 0) {
    try {
      fsImpl.unlinkSync(statePath)
    } catch {
      void 0
    }
    return
  }
  writeBackendLifecycleState(statePath, { backends }, fsImpl)
}

function defaultPidExists(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function defaultProcessCommandLine(pid, isWindows = process.platform === 'win32') {
  try {
    if (isWindows) {
      return execFileSync(
        'powershell.exe',
        ['-NoProfile', '-Command', `(Get-CimInstance Win32_Process -Filter "ProcessId=${pid}").CommandLine`],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true }
      ).trim()
    }
    return execFileSync('ps', ['-p', String(pid), '-o', 'args='], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim()
  } catch {
    return ''
  }
}

function childHasExited(child) {
  return !child || child.exitCode !== null || child.signalCode !== null
}

async function terminateBackendChild(child, options = {}) {
  if (!child || childHasExited(child)) return { signaled: false, escalated: false }

  const {
    graceMs = 5000,
    isWindows = process.platform === 'win32',
    forceKillProcessTree = () => {},
    setTimeoutFn = setTimeout,
    clearTimeoutFn = clearTimeout
  } = options

  let signaled = false
  try {
    child.kill('SIGTERM')
    signaled = true
  } catch {
    return { signaled: false, escalated: false }
  }

  const exited = await new Promise(resolve => {
    const timer = setTimeoutFn(() => resolve(false), graceMs)
    if (typeof timer?.unref === 'function') timer.unref()
    child.once('exit', () => {
      clearTimeoutFn(timer)
      resolve(true)
    })
  })

  if (exited || childHasExited(child)) return { signaled, escalated: false }

  try {
    if (isWindows && Number.isInteger(child.pid)) {
      forceKillProcessTree(child.pid)
    } else {
      child.kill('SIGKILL')
    }
    return { signaled, escalated: true }
  } catch {
    return { signaled, escalated: false }
  }
}

async function terminateRecordedPid(pid, options = {}) {
  const {
    graceMs = 5000,
    isWindows = process.platform === 'win32',
    forceKillProcessTree = () => {},
    killPid = (targetPid, signal) => process.kill(targetPid, signal),
    sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
  } = options

  try {
    killPid(pid, 'SIGTERM')
  } catch {
    return { signaled: false, escalated: false }
  }

  await sleep(graceMs)

  try {
    if (isWindows) {
      forceKillProcessTree(pid)
    } else {
      killPid(pid, 'SIGKILL')
    }
    return { signaled: true, escalated: true }
  } catch {
    return { signaled: true, escalated: false }
  }
}

async function reapPersistedBackendChildren(statePath, options = {}) {
  const {
    fsImpl = fs,
    pidExists = defaultPidExists,
    getProcessCommandLine = pid => defaultProcessCommandLine(pid, options.isWindows),
    logger = () => {}
  } = options

  const state = readBackendLifecycleState(statePath, fsImpl)
  const results = []

  for (const record of state.backends) {
    if (!pidExists(record.pid)) {
      results.push({ pid: record.pid, action: 'cleared-dead' })
      continue
    }

    const liveCommandLine = getProcessCommandLine(record.pid)
    if (!liveCommandLine || !looksLikeHermesBackend('', [], liveCommandLine)) {
      results.push({ pid: record.pid, action: 'cleared-reused' })
      continue
    }

    logger(`Reaping prior desktop-managed Hermes backend pid ${record.pid} (${record.role})`)
    const terminated = await terminateRecordedPid(record.pid, options)
    results.push({ pid: record.pid, action: 'reaped', ...terminated })
  }

  try {
    fsImpl.unlinkSync(statePath)
  } catch {
    void 0
  }
  return results
}

module.exports = {
  BACKEND_LIFECYCLE_SCHEMA_VERSION,
  looksLikeHermesBackend,
  readBackendLifecycleState,
  reapPersistedBackendChildren,
  removeBackendLifecycleRecord,
  terminateBackendChild,
  upsertBackendLifecycleRecord
}
