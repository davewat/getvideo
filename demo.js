// Plays one job through the miniature app in the hero, then loops.
const $ = (id) => document.getElementById(id)
const url = $('demo-url')
const btn = $('demo-btn')
const job = $('demo-job')
const status = $('demo-status')
const file = $('demo-file')
const fills = [...job.querySelectorAll('.seg-bar i')]
const LINK = 'https://www.youtube.com/watch?v=aqz-KE-bpKQ'

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const setText = (t) => { url.firstChild?.nodeType === 3 ? (url.firstChild.data = t) : url.prepend(t) }

// run fills one segment over `ms`, reporting progress through `label(percent)`.
function run(i, ms, label) {
  return new Promise((done) => {
    const t0 = performance.now()
    const tick = (now) => {
      const p = Math.min(1, (now - t0) / ms)
      fills[i].style.width = `${p * 100}%`
      status.textContent = label(Math.round(p * 100))
      p < 1 ? requestAnimationFrame(tick) : done()
    }
    requestAnimationFrame(tick)
  })
}

function finished() {
  setText('')
  fills.forEach((f) => { f.style.width = '100%' })
  job.dataset.state = 'done'
  status.textContent = 'Done'
  file.dataset.show = 'true'
}

async function play() {
  for (;;) {
    setText('')
    job.dataset.state = ''
    file.dataset.show = ''
    fills.forEach((f) => { f.style.width = '0' })
    await sleep(900)
    for (let i = 1; i <= LINK.length; i++) { setText(LINK.slice(0, i)); await sleep(22) }
    await sleep(350)
    btn.dataset.press = 'true'
    await sleep(220)
    btn.dataset.press = ''
    setText('')
    job.dataset.state = 'running'
    status.textContent = 'Waiting'
    await sleep(500)
    await run(0, 2600, (p) => `Downloading ${p}% · 6.1MiB/s`)
    await run(1, 3800, (p) => `Converting ${p}% · 212 fps`)
    await run(2, 500, () => 'Saving')
    finished()
    await sleep(4200)
  }
}

if (matchMedia('(prefers-reduced-motion: reduce)').matches) finished()
else play()

// Show the current version next to the download button.
fetch('https://api.github.com/repos/davewat/getvideo/releases/latest')
  .then((r) => (r.ok ? r.json() : null))
  .then((rel) => { if (rel?.tag_name) $('version').textContent = rel.tag_name })
  .catch(() => {})
