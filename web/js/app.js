import { api } from './api.js'
import { $, h } from './dom.js'
import { defaults, sections } from './schema.js'

const MODE = 'getvideo.mode'

// ---- form state -----------------------------------------------------------
// `saved` is the defaults stored by the service: Easy mode always runs with them.
// `form` is the Advanced form's working copy; it only becomes `saved` on "Save as default".

const withoutTransient = (v) => {
  const keep = structuredClone(v)
  for (const s of sections) for (const f of s.fields) if (f.transient) keep[s.key][f.key] = defaults[s.key][f.key]
  return keep
}

let saved = structuredClone(defaults)
const form = structuredClone(defaults)
let hasSaved = false // false = still on the built-in defaults

const syncers = [] // re-evaluate each field's disabled/hidden state after any change
const dirty = () => JSON.stringify(withoutTransient(form)) !== JSON.stringify(saved)

function changed() {
  for (const s of syncers) s()
}

let mode = 'easy'
try { if (localStorage.getItem(MODE) === 'advanced') mode = 'advanced' } catch { /* storage unavailable */ }

function setMode(m) {
  mode = m
  try { localStorage.setItem(MODE, m) } catch { /* storage unavailable */ }
  document.body.dataset.mode = m
  $('#mode').textContent = m === 'easy' ? 'Advanced' : 'Easy mode'
  $('#mode').title = m === 'easy' ? 'Show every download and transcode option' : 'Back to the simple view'
  changed()
  renderNotice()
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

// describe sums up the saved defaults in one line for Easy mode.
function describe(v) {
  const d = v.download
  const t = v.transcode
  const parts = [d.audioOnly ? `Audio only (${d.audioFormat})` : d.maxHeight ? `Up to ${d.maxHeight}p` : 'Best quality']
  if (!d.audioOnly) parts.push(t.skip ? 'no transcoding' : [t.preset || 'HandBrake', t.container].filter(Boolean).join(' · '))
  parts.push(`saved to ${v.output.dir || '~/Downloads'}`)
  return parts.join(' → ')
}

let submitBtn = null

function buildForm() {
  const url = h('textarea', { rows: 2, placeholder: 'Paste one or more YouTube links…', required: true })
  const error = h('p', { class: 'error', hidden: true })
  submitBtn = h('button', { class: 'btn primary', type: 'submit' }, 'Get video')

  const steps = sections.map((s, i) => {
    const basic = s.fields.filter((f) => !f.advanced).map((f) => field(s, f))
    const adv = s.fields.filter((f) => f.advanced).map((f) => field(s, f))
    return h('details', { class: 'step', open: true },
      h('summary', {}, h('span', { class: 'num' }, String(i + 1)), h('span', { class: 'step-title' }, s.title),
        h('span', { class: 'muted' }, s.tool)),
      h('div', { class: 'grid' }, basic),
      adv.length ? h('details', { class: 'more' }, h('summary', {}, 'More options'), h('div', { class: 'grid' }, adv)) : null)
  })

  // Easy mode: one line saying what will happen, and the way into Advanced.
  const summary = h('span', {})
  const easy = h('p', { class: 'easy-only summary muted' }, summary, ' ',
    h('button', { class: 'link', type: 'button', onclick: () => setMode('advanced') }, 'Change'))

  // Advanced mode: every option, plus saving them as the defaults Easy mode uses.
  const saveState = h('span', { class: 'muted small' })
  const save = h('button', { class: 'btn', type: 'button', onclick: async () => {
    error.hidden = true
    try {
      saved = withoutTransient(await api.saveSettings(withoutTransient(form)))
      hasSaved = true
      changed()
    } catch (x) {
      error.textContent = x.message
      error.hidden = false
    }
  } }, 'Save as default')
  const reset = h('button', { class: 'link', type: 'button', onclick: async () => {
    if (!confirm('Discard your saved defaults and go back to the built-in ones?')) return
    await api.resetSettings()
    location.reload()
  } }, 'Reset to built-in defaults')
  const defaultsBar = h('div', { class: 'adv-only defaults-bar' }, save, saveState, reset)

  syncers.push(() => {
    summary.textContent = describe(saved)
    save.disabled = !dirty()
    saveState.textContent = dirty() ? 'Unsaved changes: Easy mode still uses your previous defaults.'
      : hasSaved ? 'These are your saved defaults.' : 'These are the built-in defaults.'
    reset.hidden = !hasSaved
  })

  const el = $('#form')
  el.append(h('div', { class: 'url' }, url), easy, h('div', { class: 'adv-only steps' }, steps), error, defaultsBar, submitBtn)
  el.addEventListener('submit', async (e) => {
    e.preventDefault()
    const urls = url.value.split(/\s+/).filter(Boolean)
    if (!urls.length) return
    error.hidden = true
    submitBtn.disabled = true
    try {
      // Easy mode never sends unsaved Advanced edits.
      const opts = structuredClone(mode === 'easy' ? saved : form)
      for (const u of urls) await api.addJob({ url: u, ...opts })
      url.value = ''
    } catch (x) {
      error.textContent = x.message
      error.hidden = false
    } finally {
      renderNotice()
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
  renderNotice()
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

// autoUpdate is Easy mode's start-up step: install whatever is missing and update what is stale.
async function autoUpdate() {
  await refreshTools()
  renderNotice()
  await refreshTools(true) // asks GitHub and the ffmpeg server for the latest versions
  if (mode !== 'easy') return
  const todo = tools.filter((t) => !t.busy && (!t.installed || t.updateAvailable))
  if (!todo.length) return
  await Promise.all(todo.map((t) => api.install(t.name).catch(() => {})))
  await refreshTools()
}

// renderNotice shows the "Updating app" banner and holds the button until every tool is present.
function renderNotice() {
  const el = $('#notice')
  const busy = tools.filter((t) => t.busy)
  const missing = tools.filter((t) => !t.installed)
  const failed = tools.filter((t) => t.error && !t.busy && (!t.installed || t.updateAvailable))
  const ready = tools.length > 0 && missing.length === 0
  if (submitBtn) {
    submitBtn.disabled = !ready
    submitBtn.textContent = ready ? (mode === 'easy' ? 'Get video' : 'Add to queue') : 'Getting ready…'
  }
  el.dataset.kind = ''
  if (busy.length) {
    const first = busy.some((t) => !t.installed)
    el.replaceChildren(h('span', { class: 'spinner' }),
      h('strong', {}, first ? 'Setting up GetVideo…' : 'Updating app…'),
      h('span', {}, ` ${first ? 'Installing' : 'Updating'} ${busy.map((t) => t.name).join(', ')}. ${first ? 'This takes a minute the first time.' : 'You can keep using the app.'}`))
    el.hidden = false
  } else if (failed.length) {
    el.dataset.kind = 'bad'
    el.replaceChildren(h('strong', {}, `Could not ${missing.length ? 'install' : 'update'} ${failed.map((t) => t.name).join(', ')}. `),
      h('span', {}, failed[0].error + ' '),
      h('button', { class: 'link', type: 'button', onclick: async () => {
        await Promise.all(failed.map((t) => api.install(t.name).catch(() => {})))
        refreshTools()
      } }, 'Try again'))
    el.hidden = false
  } else if (missing.length && mode === 'advanced') {
    el.dataset.kind = 'bad'
    el.replaceChildren(h('strong', {}, `${missing.map((t) => t.name).join(', ')} not installed. `),
      h('span', {}, 'Click the red tool above to install it.'))
    el.hidden = false
  } else {
    el.hidden = true
  }
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

async function start() {
  try {
    const v = await api.settings()
    if (v) {
      hasSaved = true
      for (const k of Object.keys(saved)) Object.assign(saved[k], v[k] ?? {})
      saved = withoutTransient(saved)
      Object.assign(form, structuredClone(saved))
    }
  } catch { /* fall back to the built-in defaults */ }
  buildForm()
  $('#mode').addEventListener('click', () => setMode(mode === 'easy' ? 'advanced' : 'easy'))
  setMode(mode)
  listen()
  autoUpdate()
}

start()
