#!/usr/bin/env node
// Extracts the male front/back figure from HichamELBSI/react-native-body-highlighter (MIT, see
// docs/licenses/body-highlighter.md) into ios/GymRollins/Resources/body-map.json, which the app parses into SwiftUI
// paths for the recovery map. Build time only: no npm dependency in the app; the source is pinned to
// BODY_HIGHLIGHTER_SHA, and the upstream files are read as text (never executed).
//
// Output: { source, commit, license, viewBoxes: { front: [x, y, w, h], back: [...] },
//           outlines: { front: "<path>", back: "<path>" },
//           regions: [{ id, view: "front" | "back", path }] }
// `outlines` is the body's edge; it leaves out the head, hands and feet, which upstream draws as parts. Region ids
// are the upstream slug plus "-left" / "-right" (none for "common" parts); the app maps them onto its muscle groups
// and merges the NEUTRAL parts into the silhouette under the muscles (BodyMapShapes.swift). Two parts are split so every
// app muscle group has its own area: the largest "upper-back" piece per side is "lats", the smaller "gluteal" piece
// is "gluteus-medius".
// Every path is rewritten as absolute M/L/C/Z (arcs and quadratics become cubics) so the app's parser stays small.
//
// Usage: node scripts/build-body-map.mjs [--src <checkout of the repository>]
//   Without --src it downloads the three source files at BODY_HIGHLIGHTER_SHA.
// Tests: node --test scripts/build-body-map.test.mjs
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

export const BODY_HIGHLIGHTER_SHA = '8ed39ac2ae9cb46fb79d77eedec7e5b029a75174'
const RAW = `https://raw.githubusercontent.com/HichamELBSI/react-native-body-highlighter/${BODY_HIGHLIGHTER_SHA}/`
const FILES = { front: 'assets/bodyFront.ts', back: 'assets/bodyBack.ts', wrapper: 'components/SvgMaleWrapper.tsx' }

/** Parts the app draws as part of the silhouette, never coloured (BodyMapRegions.neutral). */
export const NEUTRAL = new Set(['head', 'hair', 'hands', 'feet', 'ankles', 'knees', 'neck'])
/** Space around the silhouette in each view box, in source units. */
const PAD = 12

const ROOT = resolve(import.meta.dirname, '..')
const OUT = resolve(ROOT, 'ios/GymRollins/Resources/body-map.json')

// MARK: - Source parsing

/** `{ slug: "chest", ..., path: { left: ["..."], right: [...], common: [...] } }` → [{ slug, left, right, common }]. */
export function parseBodyParts(source) {
  const chunks = source.split(/\bslug:\s*/).slice(1)
  return chunks.map((chunk) => {
    const slug = /^"([a-z-]+)"/.exec(chunk)?.[1]
    if (!slug) throw new Error(`unreadable slug near: ${chunk.slice(0, 40)}`)
    const list = (key) => {
      const m = new RegExp(`\\b${key}:\\s*\\[([^\\]]*)\\]`).exec(chunk)
      return m ? [...m[1].matchAll(/"([^"]+)"/g)].map((s) => s[1].trim()) : []
    }
    return { slug, left: list('left'), right: list('right'), common: list('common') }
  })
}

/** The wrapper's two outline paths: { front, back } (front is the one left of x = 724). */
export function parseOutlines(wrapperSource) {
  const paths = [...wrapperSource.matchAll(/\bd="([^"]+)"/g)].map((m) => m[1])
  if (paths.length !== 2) throw new Error(`expected 2 outline paths, found ${paths.length}`)
  const [a, b] = paths.map((d) => ({ d, box: bounds(normalizePath(d)) }))
  return a.box.minX < b.box.minX ? { front: a.d, back: b.d } : { front: b.d, back: a.d }
}

// MARK: - Path normalisation

const ARG_COUNTS = { M: 2, L: 2, H: 1, V: 1, C: 6, S: 4, Q: 4, T: 2, A: 7, Z: 0 }

/** Commands with their numbers; arc flags may be written without separators ("a1 1 0 01 2 2"). */
export function tokenize(d) {
  const out = []
  const re = /([MmLlHhVvCcSsQqTtAaZz])|([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)/g
  let cmd = null
  let m
  const flagged = () => cmd && (cmd.letter === 'A' || cmd.letter === 'a') && [3, 4].includes(cmd.args.length % 7)
  while ((m = re.exec(d))) {
    if (m[1]) {
      cmd = { letter: m[1], args: [] }
      out.push(cmd)
    } else {
      if (!cmd) throw new Error('path does not start with a command')
      if (flagged() && /^[01]./.test(m[2]) && !m[2].includes('e')) { // "01" = two flags
        cmd.args.push(Number(m[2][0]))
        re.lastIndex = m.index + 1
        continue
      }
      cmd.args.push(Number(m[2]))
    }
  }
  const unknown = d.replace(re, '').replace(/[\s,]/g, '')
  if (unknown) throw new Error(`unsupported path data: ${unknown.slice(0, 20)}`)
  return out
}

/** Absolute [["M", x, y] | ["L", x, y] | ["C", x1, y1, x2, y2, x, y] | ["Z"]] for any SVG path. */
export function normalizePath(d) {
  const out = []
  let cx = 0, cy = 0, sx = 0, sy = 0
  let lastCubic = null, lastQuad = null
  for (const { letter, args } of tokenize(d)) {
    const upper = letter.toUpperCase()
    const rel = letter !== upper
    const n = ARG_COUNTS[upper]
    if (upper === 'Z') {
      out.push(['Z'])
      cx = sx; cy = sy; lastCubic = lastQuad = null
      continue
    }
    if (args.length === 0 || args.length % n !== 0) throw new Error(`${letter}: ${args.length} numbers`)
    for (let i = 0; i < args.length; i += n) {
      const a = args.slice(i, i + n)
      const ox = rel ? cx : 0, oy = rel ? cy : 0
      const kind = upper === 'M' && i > 0 ? 'L' : upper // extra pairs after M are lines
      let cubic = null, quad = null
      switch (kind) {
        case 'M':
          cx = sx = a[0] + ox; cy = sy = a[1] + oy
          out.push(['M', cx, cy])
          break
        case 'L': case 'H': case 'V': {
          const x = kind === 'V' ? cx : a[0] + ox
          const y = kind === 'H' ? cy : (kind === 'V' ? a[0] + oy : a[1] + oy)
          out.push(['L', x, y]); cx = x; cy = y
          break
        }
        case 'C': case 'S': {
          const [x1, y1] = kind === 'C' ? [a[0] + ox, a[1] + oy] : reflect(lastCubic, cx, cy)
          const k = kind === 'C' ? 2 : 0
          const x2 = a[k] + ox, y2 = a[k + 1] + oy, x = a[k + 2] + ox, y = a[k + 3] + oy
          out.push(['C', x1, y1, x2, y2, x, y]); cubic = [x2, y2]; cx = x; cy = y
          break
        }
        case 'Q': case 'T': {
          const [qx, qy] = kind === 'Q' ? [a[0] + ox, a[1] + oy] : reflect(lastQuad, cx, cy)
          const k = kind === 'Q' ? 2 : 0
          const x = a[k] + ox, y = a[k + 1] + oy
          out.push(['C', cx + (2 / 3) * (qx - cx), cy + (2 / 3) * (qy - cy), x + (2 / 3) * (qx - x), y + (2 / 3) * (qy - y), x, y])
          quad = [qx, qy]; cx = x; cy = y
          break
        }
        case 'A': {
          const x = a[5] + ox, y = a[6] + oy
          for (const c of arcToCubics(cx, cy, a[0], a[1], a[2], a[3], a[4], x, y)) out.push(['C', ...c])
          cx = x; cy = y
          break
        }
      }
      lastCubic = cubic; lastQuad = quad
    }
  }
  return out
}

const reflect = (control, cx, cy) => (control ? [2 * cx - control[0], 2 * cy - control[1]] : [cx, cy])

/** SVG endpoint arc → cubic Béziers [x1, y1, x2, y2, x, y] (SVG 1.1 implementation notes F.6.5–F.6.6). */
export function arcToCubics(x0, y0, rx, ry, angleDeg, largeArc, sweep, x, y) {
  if (x0 === x && y0 === y) return []
  rx = Math.abs(rx); ry = Math.abs(ry)
  if (rx === 0 || ry === 0) return [[x0, y0, x, y, x, y]]
  const phi = (angleDeg * Math.PI) / 180
  const cos = Math.cos(phi), sin = Math.sin(phi)
  const dx = (x0 - x) / 2, dy = (y0 - y) / 2
  const x1p = cos * dx + sin * dy, y1p = -sin * dx + cos * dy
  const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
  if (lambda > 1) { rx *= Math.sqrt(lambda); ry *= Math.sqrt(lambda) }
  const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
  const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
  const coef = (largeArc !== sweep ? 1 : -1) * Math.sqrt(Math.max(0, num / den))
  const cxp = (coef * rx * y1p) / ry, cyp = (-coef * ry * x1p) / rx
  const ccx = cos * cxp - sin * cyp + (x0 + x) / 2, ccy = sin * cxp + cos * cyp + (y0 + y) / 2
  const angle = (ux, uy, vx, vy) => Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
  const theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
  let delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
  if (!sweep && delta > 0) delta -= 2 * Math.PI
  if (sweep && delta < 0) delta += 2 * Math.PI
  const segments = Math.ceil(Math.abs(delta) / (Math.PI / 2))
  const step = delta / segments
  const t = (4 / 3) * Math.tan(step / 4)
  const point = (th) => [ccx + rx * Math.cos(th) * cos - ry * Math.sin(th) * sin, ccy + rx * Math.cos(th) * sin + ry * Math.sin(th) * cos]
  const deriv = (th) => [-rx * Math.sin(th) * cos - ry * Math.cos(th) * sin, -rx * Math.sin(th) * sin + ry * Math.cos(th) * cos]
  const out = []
  for (let i = 0; i < segments; i++) {
    const a = theta1 + i * step, b = a + step
    const [ax, ay] = point(a), [bx, by] = i === segments - 1 ? [x, y] : point(b)
    const [dax, day] = deriv(a), [dbx, dby] = deriv(b)
    out.push([ax + t * dax, ay + t * day, bx - t * dbx, by - t * dby, bx, by])
  }
  return out
}

const fmt = (v) => String(Math.round(v * 100) / 100)

/** Normalised commands → compact path data ("M1 2L3 4C...Z"). */
export function serialize(commands) {
  return commands.map(([c, ...n]) => c + n.map(fmt).join(' ')).join('')
}

/** Bounding box of every point, control points included (a slight over-estimate is fine here). */
export function bounds(commands) {
  const xs = [], ys = []
  for (const [, ...n] of commands) for (let i = 0; i < n.length; i += 2) { xs.push(n[i]); ys.push(n[i + 1]) }
  return { minX: Math.min(...xs), minY: Math.min(...ys), maxX: Math.max(...xs), maxY: Math.max(...ys) }
}

/** Area enclosed by a path, from its on-curve points and control points (shoelace; good enough to rank pieces). */
export function approxArea(commands) {
  let area = 0, start = null, prev = null
  const add = (p) => { if (prev) area += prev[0] * p[1] - p[0] * prev[1]; prev = p }
  for (const [c, ...n] of commands) {
    if (c === 'M') { if (start && prev) add(start); start = [n[0], n[1]]; prev = start; continue }
    if (c === 'Z') { if (start) add(start); continue }
    for (let i = 0; i < n.length; i += 2) add([n[i], n[i + 1]])
  }
  if (start && prev) add(start)
  return Math.abs(area) / 2
}

// MARK: - Assembly

/** Upstream slug + piece → exported part name (see the header for why two parts are split). */
export function partNames(slug, pieces) {
  if (slug !== 'upper-back' && slug !== 'gluteal') return pieces.map(() => slug)
  const areas = pieces.map((p) => approxArea(normalizePath(p)))
  const largest = areas.indexOf(Math.max(...areas))
  if (slug === 'upper-back') return pieces.map((_, i) => (i === largest ? 'lats' : 'upper-back'))
  return pieces.map((_, i) => (i === largest ? 'gluteal' : 'gluteus-medius'))
}

/** One region per (part, side): every piece of that part on that side in one path. */
export function regionsOf(parts, view) {
  const regions = new Map()
  for (const part of parts) {
    for (const side of ['left', 'right', 'common']) {
      const pieces = part[side]
      partNames(part.slug, pieces).forEach((name, i) => {
        const id = side === 'common' ? name : `${name}-${side}`
        const region = regions.get(id) ?? { id, view, path: '' }
        region.path += serialize(normalizePath(pieces[i]))
        regions.set(id, region)
      })
    }
  }
  if (regions.size === 0) throw new Error(`no ${view} regions found`)
  return [...regions.values()]
}

/** Same-size boxes for both views, each centred on its figure (outline plus every region of that view, as path
 *  data) with PAD around the larger one. */
export function viewBoxes(figures) {
  const measure = (paths) => bounds(paths.flatMap((d) => normalizePath(d)))
  const front = measure(figures.front), back = measure(figures.back)
  const w = Math.max(front.maxX - front.minX, back.maxX - back.minX) + 2 * PAD
  const h = Math.max(front.maxY - front.minY, back.maxY - back.minY) + 2 * PAD
  const box = (b) => [(b.minX + b.maxX - w) / 2, (b.minY + b.maxY - h) / 2, w, h].map((v) => Math.round(v))
  return { front: box(front), back: box(back) }
}

export function buildBodyMap(frontSource, backSource, wrapperSource) {
  const outlines = parseOutlines(wrapperSource)
  const regions = [...regionsOf(parseBodyParts(frontSource), 'front'), ...regionsOf(parseBodyParts(backSource), 'back')]
  const figure = (view) => [outlines[view], ...regions.filter((r) => r.view === view).map((r) => r.path)]
  return {
    source: 'https://github.com/HichamELBSI/react-native-body-highlighter',
    commit: BODY_HIGHLIGHTER_SHA,
    license: 'MIT',
    viewBoxes: viewBoxes({ front: figure('front'), back: figure('back') }),
    outlines: { front: serialize(normalizePath(outlines.front)), back: serialize(normalizePath(outlines.back)) },
    regions,
  }
}

async function load(args) {
  const i = args.indexOf('--src')
  if (i >= 0) {
    const dir = args[i + 1]
    return Object.values(FILES).map((f) => readFileSync(resolve(dir, f), 'utf8'))
  }
  const get = async (file) => {
    const res = await fetch(RAW + file)
    if (!res.ok) throw new Error(`GET ${file}: ${res.status}`)
    return res.text()
  }
  return Promise.all(Object.values(FILES).map(get))
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [front, back, wrapper] = await load(process.argv.slice(2))
  const map = buildBodyMap(front, back, wrapper)
  writeFileSync(OUT, JSON.stringify(map, null, 1) + '\n')
  const count = (v) => map.regions.filter((r) => r.view === v).length
  console.log(`wrote ${OUT}: ${count('front')} front + ${count('back')} back regions`)
}
