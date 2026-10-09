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
  document.querySelectorAll('.seg button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.mode === m)))
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
      input = h('input', { type: 'text', value: state[f.key], placeholder: f.placeholder,
        oninput: (e) => set(e.target.value) })
      wrap = h('label', { class: 'field' }, h('span', {}, f.label), h('div', { class: 'inline' }, input,
        h('button', { type: 'button', class: 'btn', onclick: async () => {
          const { path, message } = await api.pickFolder()
          if (path) { input.value = path; set(path) }
          else if (message) alert(message)
        } }, 'Choose folder')))
      break
    default: // text, number
      input = h('input', { type: f.type === 'number' ? 'number' : 'text', min: f.type === 'number' ? 0 : null,
        value: state[f.key], placeholder: f.placeholder,
        oninput: (e) => set(f.type === 'number' ? Number(e.target.value) || 0 : e.target.value) })
      wrap = h('label', { class: 'field' }, h('span', {}, f.label), input)
  }
  input?.setAttribute('spellcheck', 'false')

  if (f.hint) wrap.append(h('span', { class: 'hint' }, f.hint))
  if (f.wide || f.type === 'chips') wrap.classList.add('wide')
  syncers.push(() => {
    const off = f.off?.(form) ?? false
    wrap.classList.toggle('off', off)
    wrap.querySelectorAll('input, select, button').forEach((el) => { el.disabled = off })
    wrap.hidden = f.show ? !f.show(form) : false
  })
  return wrap
}

// group lays a section's fields out as: full-width switches, then inputs, then the remaining switches.
function group(section, fields) {
  const is = (f, check, wide) => (f.type === 'check') === check && (wide === undefined || !!f.wide === wide)
  const lead = fields.filter((f) => is(f, true, true)).map((f) => field(section, f))
  const inputs = fields.filter((f) => is(f, false)).map((f) => field(section, f))
  const toggles = fields.filter((f) => is(f, true, false)).map((f) => field(section, f))
  return [
    ...lead,
    inputs.length ? h('div', { class: 'grid' }, inputs) : null,
    toggles.length ? h('div', { class: 'grid toggles' }, toggles) : null,
  ]
}

// plan describes what a set of options will do, one phrase per stage.
function plan(v) {
  const d = v.download
  const t = v.transcode
  const converts = !d.audioOnly && !t.skip
  return [
    { stage: 'download', label: 'Download', text: d.audioOnly ? `audio only, ${d.audioFormat}` : d.maxHeight ? `up to ${d.maxHeight}p` : 'best quality' },
    converts && { stage: 'transcode', label: 'Convert', text: [t.preset || 'custom settings', t.container].filter(Boolean).join(', ') },
    { stage: 'output', label: 'Save', text: v.output.dir || '~/Downloads' },
  ].filter(Boolean)
}

let submitBtn = null

function buildForm() {
  const url = h('textarea', { rows: 2, placeholder: 'https://www.youtube.com/watch?v=…', required: true, id: 'url' })
  url.setAttribute('spellcheck', 'false')
  const error = h('p', { class: 'error', role: 'alert', hidden: true })
  submitBtn = h('button', { class: 'btn primary', type: 'submit' }, 'Get video')

  const steps = sections.map((s) => h('section', { class: 'step', 'data-stage': s.key },
    h('h3', {}, h('span', { class: 'swatch' }), s.title, h('span', { class: 'tool-name' }, s.tool)),
    group(s, s.fields.filter((f) => !f.advanced)),
    s.fields.some((f) => f.advanced)
      ? h('details', { class: 'more' }, h('summary', {}, 'More options'), group(s, s.fields.filter((f) => f.advanced)))
      : null))

  // Easy mode: what will happen, one phrase per stage, and the way into Advanced.
  const planEl = h('div', { class: 'plan' })
  const easy = h('div', { class: 'easy-only plan-row' }, planEl,
    h('button', { class: 'link', type: 'button', onclick: () => setMode('advanced') }, 'Change settings'))

  // Advanced mode: every option, plus saving them as the defaults Easy mode uses.
  const saveState = h('span', { class: 'hint' })
  const save = h('button', { class: 'btn', type: 'button', onclick: async () => {
    error.hidden = true
    try {
      saved = withoutTransient(await api.saveSettings(withoutTransient(form)))
      hasSaved = true
      changed()
    } catch (x) {
      error.textContent = `Defaults not saved: ${x.message}`
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
    planEl.replaceChildren(...plan(saved).map((p) => h('span', { class: 'plan-item', 'data-stage': p.stage },
      h('span', { class: 'swatch' }), h('b', {}, p.label), ' ', p.text)))
    save.disabled = !dirty()
    saveState.textContent = dirty() ? 'Not saved yet. Easy mode keeps using your previous defaults.'
      : hasSaved ? 'Saved. Easy mode uses these settings.' : 'These are the built-in defaults.'
    reset.hidden = !hasSaved
  })

  const el = $('#form')
  el.append(
    h('label', { class: 'url' }, h('span', { class: 'url-label' }, 'Video link'), url,
      h('span', { class: 'hint' }, 'Paste one link, or several on separate lines.')),
    easy, h('div', { class: 'adv-only steps' }, steps), defaultsBar, error, submitBtn)

  url.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) el.requestSubmit()
  })
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
      error.textContent = `Not added: ${x.message}`
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
    const status = t.busy ? 'Installing…' : !t.installed ? 'Not installed' : t.updateAvailable ? `${t.version} → ${t.latest}` : t.version
    const action = !t.installed ? 'Install' : t.updateAvailable ? 'Update' : 'Reinstall'
    return h('div', { class: 'tool', 'data-state': state },
      h('span', { class: 'dot' }),
      h('div', { class: 'tool-text' }, h('b', {}, t.name), h('span', { class: 'mono' }, status),
        t.error && !t.busy ? h('span', { class: 'error' }, t.error) : null),
      h('button', { class: state === 'ok' ? 'link' : 'btn small', type: 'button', disabled: t.busy,
        onclick: async () => { await api.install(t.name); refreshTools() } }, action))
  }))
}

// autoUpdate is Easy mode's start-up step: install whatever is missing and update what is stale.
async function autoUpdate() {
  await refreshTools()
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
  const names = (ts) => ts.map((t) => t.name).join(', ')
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
      h('b', {}, first ? 'Setting up GetVideo' : 'Updating app'),
      h('span', {}, first ? `Installing ${names(busy)}. This takes about a minute the first time.`
        : `Updating ${names(busy)}. You can keep adding videos.`))
    el.hidden = false
  } else if (failed.length) {
    el.dataset.kind = 'bad'
    el.replaceChildren(h('b', {}, `${names(failed)} did not ${missing.length ? 'install' : 'update'}`),
      h('span', {}, failed[0].error),
      h('button', { class: 'btn small', type: 'button', onclick: async () => {
        await Promise.all(failed.map((t) => api.install(t.name).catch(() => {})))
        refreshTools()
      } }, 'Try again'))
    el.hidden = false
  } else if (missing.length && mode === 'advanced') {
    el.dataset.kind = 'bad'
    el.replaceChildren(h('b', {}, `${names(missing)} not installed`), h('span', {}, 'Install it from the Tools panel.'))
    el.hidden = false
  } else {
    el.hidden = true
  }
}

// ---- jobs -----------------------------------------------------------------

const rows = new Map() // job id -> { el, update, job }
const REVEAL = /Mac/.test(navigator.platform) ? 'Show in Finder' : /Win/.test(navigator.platform) ? 'Show in Explorer' : 'Show in folder'
const STAGES = ['downloading', 'transcoding', 'moving']
const LABEL = { queued: 'Waiting', downloading: 'Downloading', transcoding: 'Converting', moving: 'Saving', done: 'Done', failed: 'Failed', canceled: 'Canceled' }
const isActive = (s) => s === 'queued' || STAGES.includes(s)

// A row is built once and updated in place, so a click is never lost to a re-render mid-progress.
function makeRow(job) {
  const title = h('div', { class: 'job-title' })
  const status = h('div', { class: 'job-status mono' })
  // The track is the job's timeline: one segment per stage, filled as that stage runs.
  const segs = [['download', 'Download'], ['transcode', 'Convert'], ['output', 'Save']].map(([stage, label]) =>
    h('div', { class: 'seg-stage', 'data-stage': stage }, h('div', { class: 'seg-bar' }, h('i', {})), h('span', {}, label)))
  const track = h('div', { class: 'track-line' }, segs)
  const error = h('div', { class: 'error', role: 'alert' })
  const kept = h('div', { class: 'muted small' })
  const outputs = h('div', { class: 'outputs' })
  const actions = h('div', { class: 'actions' })
  const log = h('pre', { class: 'log', hidden: true })
  const el = h('article', { class: 'job' }, h('div', { class: 'job-head' }, title, status), track, error, kept, outputs, actions, log)

  let lastStatus = null
  let lastOutputs = ''
  const row = { el, job }

  row.update = (j) => {
    row.job = j
    title.textContent = j.title
    title.title = j.url
    el.dataset.status = j.status

    const at = STAGES.indexOf(j.status)
    status.textContent = at >= 0 && at < 2
      ? [`${LABEL[j.status]} ${j.percent.toFixed(0)}%`, j.speed, j.eta && `${j.eta} left`].filter(Boolean).join(' · ')
      : LABEL[j.status]
    segs.forEach((s, i) => {
      const fill = j.status === 'done' || at > i ? 100 : at === i ? (i === 2 ? 100 : Math.min(100, j.percent)) : 0
      s.querySelector('i').style.width = `${fill}%`
      s.dataset.state = fill >= 100 && at !== i ? 'done' : at === i ? 'active' : ''
    })
    segs[1].hidden = j.transcode.skip || j.download.audioOnly

    error.hidden = !j.error
    error.textContent = j.error ?? ''
    // A download kept for a conversion that did not finish: "Try again" continues from it.
    const keptFile = !isActive(j.status) && j.status !== 'done' ? j.downloads?.[0] : null
    kept.hidden = !keptFile
    kept.textContent = keptFile ? `Download kept (${keptFile.split(/[\\/]/).pop()}). Try again continues from the conversion.` : ''

    const outs = (j.outputs ?? []).join('\n')
    if (outs !== lastOutputs) {
      lastOutputs = outs
      outputs.replaceChildren(...(j.outputs ?? []).map((o) => {
        const cut = o.lastIndexOf('/') + 1
        return h('div', { class: 'output' },
          h('div', { class: 'path', title: o }, h('b', {}, o.slice(cut)), h('span', {}, o.slice(0, cut))),
          h('button', { class: 'btn small', type: 'button', onclick: () => api.reveal(o) }, REVEAL))
      }))
    }

    if (j.status !== lastStatus) {
      lastStatus = j.status
      const btn = (label, fn, cls = 'btn small') => h('button', { class: cls, type: 'button', onclick: fn }, label)
      actions.replaceChildren(...[
        isActive(j.status) && btn('Cancel', () => api.cancel(j.id)),
        (j.status === 'failed' || j.status === 'canceled') && btn('Try again', () => api.retry(j.id)),
        !isActive(j.status) && btn('Remove', () => api.remove(j.id), 'link'),
        btn('Details', () => { log.hidden = !log.hidden; log.scrollTop = log.scrollHeight }, 'link details'),
      ].filter(Boolean))
      updateClear()
    }

    const pinned = log.scrollTop + log.clientHeight >= log.scrollHeight - 20
    log.textContent = j.log.join('\n') || 'No output yet.'
    if (pinned) log.scrollTop = log.scrollHeight
  }
  row.update(job)
  return row
}

function updateClear() {
  $('#clear').hidden = ![...rows.values()].some((r) => !isActive(r.job.status))
  $('#empty').hidden = rows.size > 0
}

function upsertJob(j) {
  let row = rows.get(j.id)
  if (row) row.update(j)
  else {
    row = makeRow(j)
    rows.set(j.id, row)
    $('#jobs').prepend(row.el) // newest first
  }
  updateClear()
}

function removeJob(id) {
  rows.get(id)?.el.remove()
  rows.delete(id)
  updateClear()
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
  document.querySelectorAll('.seg button').forEach((b) => b.addEventListener('click', () => setMode(b.dataset.mode)))
  $('#check').addEventListener('click', () => refreshTools(true))
  $('#clear').addEventListener('click', () => {
    for (const r of rows.values()) if (!isActive(r.job.status)) api.remove(r.job.id).catch(() => {})
  })
  setMode(mode)
  listen()
  autoUpdate()
}

start()
