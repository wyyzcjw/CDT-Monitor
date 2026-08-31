import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { LoaderCircle, RefreshCw } from 'lucide-react'

type Targets = {
  button: HTMLElement
  status: HTMLElement
}

type CheckResult = {
  current: string
  base: string
  upstream: string
  relation: 'current' | 'behind' | 'ahead' | 'unknown'
}

function parseSemver(value: string) {
  const match = value.trim().match(/^v?(\d+)\.(\d+)\.(\d+)/)
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] as const : null
}

function compareSemver(left: string, right: string) {
  const a = parseSemver(left)
  const b = parseSemver(right)
  if (!a || !b) return null
  for (let index = 0; index < 3; index += 1) {
    if (a[index] > b[index]) return 1
    if (a[index] < b[index]) return -1
  }
  return 0
}

function upstreamBase(version: string) {
  const match = version.trim().match(/^(v?\d+\.\d+\.\d+)(?:-mod(?:\.\d+)?)?$/)
  return match?.[1] || version.trim()
}

async function fetchJSON<T>(url: string, init: RequestInit = {}) {
  const response = await fetch(url, init)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json() as Promise<T>
}

async function checkUpstream(): Promise<CheckResult> {
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), 5_000)
  try {
    const [info, release] = await Promise.all([
      fetchJSON<{ version?: string }>('/api/v1/system/info', { credentials: 'same-origin', cache: 'no-store', signal: controller.signal }),
      fetchJSON<{ tag_name?: string }>('https://api.github.com/repos/wang4386/CDT-Monitor/releases/latest', {
        headers: { Accept: 'application/vnd.github+json' },
        credentials: 'omit',
        cache: 'no-store',
        signal: controller.signal,
      }),
    ])
    const current = info.version?.trim() || 'unknown'
    const upstream = release.tag_name?.trim() || ''
    if (!upstream) throw new Error('GitHub Release 未返回版本号')
    const base = upstreamBase(current)
    const compared = compareSemver(base, upstream)
    return {
      current,
      base,
      upstream,
      relation: compared === null ? 'unknown' : compared === 0 ? 'current' : compared < 0 ? 'behind' : 'ahead',
    }
  } finally {
    window.clearTimeout(timeout)
  }
}

export default function UpstreamVersionCheck() {
  const [targets, setTargets] = useState<Targets | null>(null)
  const [checking, setChecking] = useState(false)
  const [result, setResult] = useState<CheckResult | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    const attach = () => {
      const about = document.querySelector<HTMLElement>('.about-section')
      const version = about?.querySelector<HTMLElement>('.about-version')
      const links = about?.querySelector<HTMLElement>('.about-links')
      if (!about || !version || !links) {
        setTargets(null)
        return
      }

      let buttonHost = version.querySelector<HTMLElement>('[data-upstream-check-button]')
      if (!buttonHost) {
        buttonHost = document.createElement('div')
        buttonHost.dataset.upstreamCheckButton = 'true'
        buttonHost.style.display = 'contents'
        version.appendChild(buttonHost)
      }

      let statusHost = about.querySelector<HTMLElement>('[data-upstream-check-status]')
      if (!statusHost) {
        statusHost = document.createElement('div')
        statusHost.dataset.upstreamCheckStatus = 'true'
        about.insertBefore(statusHost, links)
      }
      setTargets({ button: buttonHost, status: statusHost })
    }

    attach()
    const root = document.getElementById('root')
    const observer = new MutationObserver(attach)
    if (root) observer.observe(root, { childList: true, subtree: true })
    return () => observer.disconnect()
  }, [])

  const runCheck = async () => {
    setChecking(true)
    setError('')
    try {
      setResult(await checkUpstream())
    } catch (cause) {
      setResult(null)
      setError(cause instanceof Error ? cause.message : '源头版本检查失败')
    } finally {
      setChecking(false)
    }
  }

  if (!targets) return null

  const button = createPortal(
    <button className="button button--secondary button--small" type="button" onClick={() => void runCheck()} disabled={checking}>
      {checking ? <LoaderCircle className="spin" /> : <RefreshCw />}
      检查源头更新
    </button>,
    targets.button,
  )

  let status: React.ReactNode = null
  if (error) {
    status = <p className="inline-hint">源头仓库检查失败：{error}</p>
  } else if (result) {
    const suffix = result.relation === 'current'
      ? `当前 MOD 已基于最新源头 ${result.upstream}`
      : result.relation === 'behind'
        ? `当前 MOD 基于 ${result.base}，发现源头新版本，建议同步`
        : result.relation === 'ahead'
          ? `当前 MOD 基于 ${result.base}，版本高于源头 Release`
          : `当前 MOD 基于 ${result.base}`
    status = <p className="inline-hint">源头仓库最新版本：{result.upstream}，{suffix}</p>
  }

  return <>{button}{status && createPortal(status, targets.status)}</>
}
