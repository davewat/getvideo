import { api } from './api.js'
import { $, h } from './dom.js'
import { defaults, sections } from './schema.js'

const STORE = 'getvideo.form.v2'

// ---- form state -----------------------------------------------------------

const form = structuredClone(defaults)
try {
  const saved = JSON.parse(localStorage.getItem(STORE) ?? '{}')
  for (const k of Object.keys(form)) Object.assign(form[k], saved[k] ?? {})
} catch { /* storage unavailable */ }

const syncers = [] // re-evaluate each field's disabled/hidden state after any change

function changed() {
  for (const s of syncers) s()
  const keep = structuredClone(form)
  for (const s of sections) for (const f of s.fields) if (f.transient) delete keep[s.key][f.key]
  try { localStorage.setItem(STORE, JSON.stringify(keep)) } catch { /* storage unavailable */ }
}

// ---- field rendering ------------------------------------------------------

let presetSelect = null

function fillPresets(groups) {
  if (!presetSelect) return
  const cur = form.transcode.preset
  const known = groups.some((g) => g.presets.includes(cur))
  presetSelect.replaceChildren(...[
    h('option', { value: '' }, '(none)'),
    cur && !known && h('option', { value: cur }, cur),
    ...groups.map((g) => h('optgroup', { label: g.category }, g.presets.map((p) => h('option', { value: p }, p)))),
  ].filter(Boolean))
  presetSelect.value = cur
}

function field(section, f) {
  const state = form[section.key]
  const set = (v) => { state[f.key] = v; changed() }
  let input
  let wrap

  switch (f.type) {
    case 'check':
      input = h('input', { type: 'checkbox', checked: !!state[f.key], onchange: (e) => set(e.target.checked) })
      wrap = h('label', { class: 'switch' }, input, h('span', { class: 'track' }), h('span', {}, f.label))
      break
    case 'select':
    case 'preset':
      input = h('select', { onchange: (e) => set(f.number ? Number(e.target.value) : e.target.value) },
        (f.options ?? []).map(([v, l]) => h('option', { value: String(v) }, l)))
      if (f.type === 'preset') {
        presetSelect = input
        fillPresets([])
      } else {
        input.value = String(state[f.key])
      }
      wrap = h('label', { class: 'field' }, h('span', {}, f.label), input)
      break
    case 'range': {
      const out = h('output', {}, String(state[f.key]))
      input = h('input', { type: 'range', min: f.min, max: f.max, step: f.step, value: state[f.key],
        oninput: (e) => { out.textContent = e.target.value; set(Number(e.target.value)) } })
      wrap = h('label', { class: 'field' }, h('span', {}, f.label, ' ', out), input)
      break
    }
    case 'chips': {
      const chips = f.options.map((o) => {
        const b = h('button', { type: 'button', class: 'chip', 'aria-pressed': String(state[f.key].includes(o)),
          onclick: () => {
            const on = !state[f.key].includes(o)
            b.setAttribute('aria-pressed', String(on))
            set(on ? [...state[f.key], o] : state[f.key].filter((x) => x !== o))
          } }, o)
        return b
      })
      wrap = h('div', { class: 'field' }, h('span', {}, f.label), h('div', { class: 'chips' }, chips))
      break
    }
    case 'folder':
      input = h('input', { type: 'text', value: state[f.key], placeholder: f.placeholder, spellcheck: false,
        oninput: (e) => set(e.target.value) })
      wrap = h('label', { class: 'field' }, h('span', {}, f.label), h('div', { class: 'inline' }, input,
        h('button', { type: 'button', class: 'btn', onclick: async () => {
          const { path } = await api.pickFolder()
          if (path) { input.value = path; set(path) }
        } }, 'Choose…')))
      break
    default: // text, number
      input = h('input', { type: f.type === 'number' ? 'number' : 'text', min: f.type === 'number' ? 0 : null,
        value: state[f.key], placeholder: f.placeholder, spellcheck: false,
        oninput: (e) => set(f.type === 'number' ? Number(e.target.value) || 0 : e.target.value) })
      wrap = h('label', { class: 'field' }, h('span', {}, f.label), input)
  }

  if (f.wide) wrap.classList.add('wide')
  syncers.push(() => {
    const off = f.off?.(form) ?? false
    wrap.classList.toggle('off', off)
    wrap.querySelectorAll('input, select, button').forEach((el) => { el.disabled = off })
    wrap.hidden = f.show ? !f.show(form) : false
  })
  return wrap
}

function buildForm() {
  const url = h('textarea', { rows: 2, placeholder: 'Paste one or more YouTube links…', spellcheck: false, required: true })
  const error = h('p', { class: 'error', hidden: true })
  const submit = h('button', { class: 'btn primary', type: 'submit' }, 'Add to queue')

  const steps = sections.map((s, i) => {
    const basic = s.fields.filter((f) => !f.advanced).map((f) => field(s, f))
    const adv = s.fields.filter((f) => f.advanced).map((f) => field(s, f))
    return h('details', { class: 'step', open: true },
      h('summary', {}, h('span', { class: 'num' }, String(i + 1)), h('span', { class: 'step-title' }, s.title),
        h('span', { class: 'muted' }, s.tool)),
      h('div', { class: 'grid' }, basic),
      adv.length ? h('details', { class: 'more' }, h('summary', {}, 'More options'), h('div', { class: 'grid' }, adv)) : null)
  })

  const el = $('#form')
  el.append(h('div', { class: 'url' }, url), ...steps, error, submit)
  el.addEventListener('submit', async (e) => {
    e.preventDefault()
    const urls = url.value.split(/\s+/).filter(Boolean)
    if (!urls.length) return
    error.hidden = true
    submit.disabled = true
    try {
      for (const u of urls) await api.addJob({ url: u, ...structuredClone(form) })
      url.value = ''
    } catch (x) {
      error.textContent = x.message
      error.hidden = false
    } finally {
      submit.disabled = false
    }
  })
  changed()
}

// ---- tools ----------------------------------------------------------------

let tools = []
let pollTimer = null
let presetsLoadedFor = null

async function refreshTools(check = false) {
  try { tools = await api.tools(check) } catch { return }
  renderTools()
  const busy = tools.some((t) => t.busy)
  if (busy && !pollTimer) pollTimer = setInterval(() => refreshTools(false), 1000)
  if (!busy && pollTimer) { clearInterval(pollTimer); pollTimer = null }

  const hb = tools.find((t) => t.name === 'HandBrakeCLI')
  if (hb?.installed && !hb.busy && presetsLoadedFor !== hb.version) {
    presetsLoadedFor = hb.version
    api.presets().then(fillPresets).catch(() => { presetsLoadedFor = null })
  }
}

function renderTools() {
  $('#tools').replaceChildren(...tools.map((t) => {
    const state = t.busy ? 'busy' : !t.installed ? 'missing' : t.updateAvailable ? 'update' : 'ok'
    const action = t.busy ? 'Installing…' : !t.installed ? 'Install' : t.updateAvailable ? `Update to ${t.latest}` : 'Reinstall'
    return h('button', {
      class: `tool ${state}`, type: 'button', disabled: t.busy,
      title: t.error ? `Last attempt failed: ${t.error}` : `${action} ${t.name}`,
      onclick: async () => { await api.install(t.name); refreshTools() },
    }, h('span', { class: 'dot' }), h('strong', {}, t.name),
    h('span', { class: 'ver' }, t.busy ? 'installing…' : !t.installed ? 'click to install' : t.updateAvailable ? `${t.version} → ${t.latest}` : t.version),
    t.error && !t.busy ? h('span', { class: 'ver bad' }, 'failed') : null)
  }), h('button', { class: 'tool ghost', type: 'button', onclick: () => refreshTools(true) }, 'Check for updates'))
}

// ---- jobs -----------------------------------------------------------------

const rows = new Map() // job id -> { el, update }
const STAGES = ['downloading', 'transcoding', 'moving']
const LABEL = { queued: 'Queued', downloading: 'Downloading', transcoding: 'Transcoding', moving: 'Saving', done: 'Done', failed: 'Failed', canceled: 'Canceled' }
const isActive = (s) => s === 'queued' || STAGES.includes(s)

// A row is built once and updated in place, so a click is never lost to a re-render mid-progress.
function makeRow(job) {
  const title = h('div', { class: 'job-title' })
  const badge = h('span', { class: 'badge' })
  const steps = ['Download', 'Transcode', 'Save'].map((s) => h('span', { class: 'stage' }, s))
  const bar = h('div', { class: 'bar' }, h('div', { class: 'fill' }))
  const meta = h('div', { class: 'muted small' })
  const error = h('div', { class: 'error' })
  const outputs = h('div', { class: 'outputs' })
  const actions = h('div', { class: 'actions' })
  const log = h('pre', { class: 'log', hidden: true })
  const el = h('article', { class: 'job' }, h('div', { class: 'job-head' }, title, badge),
    h('div', { class: 'stages' }, steps), bar, meta, error, outputs, actions, log)

  let lastStatus = null
  let lastOutputs = ''

  const update = (j) => {
    title.textContent = j.title
    title.title = j.url
    badge.textContent = LABEL[j.status]
    el.dataset.status = j.status

    const at = STAGES.indexOf(j.status)
    const skipTranscode = j.transcode.skip || j.download.audioOnly
    steps.forEach((s, i) => {
      s.dataset.state = j.status === 'done' || (at > i) ? 'done' : at === i ? 'active' : ''
      if (i === 1) s.hidden = skipTranscode
    })

    const running = at >= 0
    bar.hidden = meta.hidden = !running
    bar.firstChild.style.width = `${Math.min(100, j.percent)}%`
    meta.textContent = [`${j.percent.toFixed(1)}%`, j.speed, j.eta && `ETA ${j.eta}`].filter(Boolean).join(' · ')

    error.hidden = !j.error
    error.textContent = j.error ?? ''

    const outs = (j.outputs ?? []).join('\n')
    if (outs !== lastOutputs) {
      lastOutputs = outs
      outputs.replaceChildren(...(j.outputs ?? []).map((o) => h('div', { class: 'output' },
        h('code', {}, o), h('button', { class: 'link', type: 'button', onclick: () => api.reveal(o) }, 'Show in Finder'))))
    }

    if (j.status !== lastStatus) {
      lastStatus = j.status
      const btn = (label, fn, cls = 'btn small') => h('button', { class: cls, type: 'button', onclick: fn }, label)
      actions.replaceChildren(...[
        isActive(j.status) && btn('Cancel', () => api.cancel(j.id)),
        (j.status === 'failed' || j.status === 'canceled') && btn('Retry', () => api.retry(j.id)),
        !isActive(j.status) && btn('Remove', () => api.remove(j.id)),
        btn('Log', () => { log.hidden = !log.hidden; log.scrollTop = log.scrollHeight }, 'link'),
      ].filter(Boolean))
    }

    if (!log.hidden || j.log.length !== log._n) {
      const pinned = log.scrollTop + log.clientHeight >= log.scrollHeight - 20
      log.textContent = j.log.join('\n') || '(no output yet)'
      log._n = j.log.length
      if (pinned) log.scrollTop = log.scrollHeight
    }
  }
  update(job)
  return { el, update }
}

function upsertJob(j) {
  let row = rows.get(j.id)
  if (row) row.update(j)
  else {
    row = makeRow(j)
    rows.set(j.id, row)
    $('#jobs').prepend(row.el) // newest first
  }
  $('#empty').hidden = rows.size > 0
}

function removeJob(id) {
  rows.get(id)?.el.remove()
  rows.delete(id)
  $('#empty').hidden = rows.size > 0
}

async function loadJobs() {
  const jobs = await api.jobs()
  const ids = new Set(jobs.map((j) => j.id))
  for (const id of [...rows.keys()]) if (!ids.has(id)) removeJob(id)
  jobs.forEach(upsertJob)
}

function listen() {
  const es = new EventSource('/api/events')
  es.onmessage = (e) => {
    const m = JSON.parse(e.data)
    if (m.removed) removeJob(m.id)
    else upsertJob(m)
  }
  es.onopen = () => loadJobs().catch(() => {}) // also resyncs after a dropped stream reconnects
}

buildForm()
refreshTools().then(() => refreshTools(true)) // show installed state at once, then look for updates
listen()
