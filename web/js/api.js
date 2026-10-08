async function call(method, path, body) {
  const res = await fetch(path, {
    method,
    // The server rejects writes without this header (keeps other sites from driving it).
    headers: { 'X-GetVideo': '1', ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error ?? res.statusText)
  return data
}

export const api = {
  tools: (check = false) => call('GET', `/api/tools${check ? '?check=1' : ''}`),
  install: (name) => call('POST', `/api/tools/${name}/install`),
  presets: () => call('GET', '/api/handbrake/presets'),
  jobs: () => call('GET', '/api/jobs'),
  addJob: (job) => call('POST', '/api/jobs', job),
  cancel: (id) => call('POST', `/api/jobs/${id}/cancel`),
  retry: (id) => call('POST', `/api/jobs/${id}/retry`),
  remove: (id) => call('DELETE', `/api/jobs/${id}`),
  reveal: (path) => call('POST', '/api/reveal', { path }),
  pickFolder: () => call('POST', '/api/pick-folder'),
}
