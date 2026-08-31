export class APIError extends Error {
  status: number
  code: string
  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

let lastKnownVersion = ''

function cookie(name: string) {
  const prefix = `${name}=`
  const value = document.cookie.split('; ').find((part) => part.startsWith(prefix))
  return value ? decodeURIComponent(value.slice(prefix.length)) : ''
}

export function normalizeLatestForMod(currentVersion: string, upstreamLatest: string) {
  const current = currentVersion.trim()
  const latest = upstreamLatest.trim()
  const match = current.match(/^(v?\d+\.\d+\.\d+)-mod(?:\.\d+)?$/)
  if (!match || !latest) return latest
  if (latest === match[1]) return current
  return /-mod(?:\.\d+)?$/.test(latest) ? latest : `${latest}-mod`
}

function normalizeSystemInfo(path: string, body: unknown) {
  if (!path.startsWith('/api/v1/system/info') || !body || typeof body !== 'object') return body
  const info = body as { version?: unknown; latest_version?: unknown }
  if (typeof info.version === 'string') lastKnownVersion = info.version
  if (typeof info.latest_version === 'string' && lastKnownVersion) {
    info.latest_version = normalizeLatestForMod(lastKnownVersion, info.latest_version)
  }
  return body
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  if (init.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json')
  if (init.method && init.method !== 'GET' && init.method !== 'HEAD') {
    const csrf = cookie('cdt_csrf')
    if (csrf) headers.set('X-CDT-CSRF', csrf)
  }
  const response = await fetch(path, { ...init, headers, credentials: 'same-origin' })
  if (response.status === 204) return undefined as T
  const body = await response.json().catch(() => ({}))
  if (!response.ok) {
    const detail = body?.error
    throw new APIError(response.status, detail?.code ?? 'request_failed', detail?.message ?? `HTTP ${response.status}`)
  }
  return normalizeSystemInfo(path, body) as T
}

export async function fetchLatestReleaseFromGitHub() {
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), 4_000)
  try {
    const response = await fetch('https://api.github.com/repos/wang4386/CDT-Monitor/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' },
      credentials: 'omit',
      cache: 'no-store',
      signal: controller.signal,
    })
    const payload = await response.json().catch(() => null) as { tag_name?: unknown } | null
    if (!response.ok) throw new Error(`GitHub API 请求失败（HTTP ${response.status}）`)
    if (!payload || typeof payload.tag_name !== 'string' || !payload.tag_name.trim()) throw new Error('GitHub Release 响应无版本号')
    return normalizeLatestForMod(lastKnownVersion, payload.tag_name)
  } finally {
    window.clearTimeout(timeout)
  }
}

export async function waitForJob(jobId: string, onProgress?: (status: string) => void) {
  const deadline = Date.now() + 70_000
  while (Date.now() < deadline) {
    const job = await api<{ status: string; result?: string; error?: string }>(`/api/v1/jobs/${jobId}`)
    onProgress?.(job.status)
    if (job.status === 'completed') return job
    if (job.status === 'failed') throw new Error(job.error || '任务执行失败')
    await new Promise((resolve) => window.setTimeout(resolve, 900))
  }
  throw new Error('任务仍在后台执行，请稍后刷新')
}
