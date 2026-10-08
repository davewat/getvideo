// Form defaults and field definitions. Field keys match the Go option structs' JSON names.

export const defaults = {
  download: {
    maxHeight: 1080, audioOnly: false, audioFormat: 'mp3', mergeContainer: 'mp4', formatSort: '', customFormat: '',
    noPlaylist: true, subtitles: false, autoSubs: false, subLangs: 'en', embedSubs: false, embedMetadata: true,
    embedThumbnail: false, cookiesBrowser: '', rateLimit: '', proxy: '', sponsorBlock: [], extraArgs: '',
  },
  transcode: {
    skip: false, preset: 'Fast 1080p30', container: 'mp4', encoder: '', qualityMode: '', quality: 22,
    videoBitrate: 4000, encoderPreset: '', framerate: '', framerateMode: 'vfr', maxWidth: 0, maxHeight: 0,
    deinterlace: '', audioEncoder: '', audioBitrate: 0, allAudio: false, allSubs: false, webOptimize: true, extraArgs: '',
  },
  output: { dir: '', filename: '', keepSource: false, overwrite: false },
}

const same = (xs) => xs.map((x) => [x, x])
const audioOnly = (f) => f.download.audioOnly
const noTranscode = (f) => f.transcode.skip || f.download.audioOnly

// type: select | text | number | check | range | chips | preset | folder
// off(form) disables a field; show(form) hides it when false; advanced fields sit behind "More options".
export const sections = [
  {
    key: 'download', title: 'Download', tool: 'yt-dlp', fields: [
      { key: 'maxHeight', label: 'Max quality', type: 'select', number: true,
        options: [[0, 'Best available'], [2160, '2160p (4K)'], [1440, '1440p'], [1080, '1080p'], [720, '720p'], [480, '480p'], [360, '360p']] },
      { key: 'mergeContainer', label: 'Container', type: 'select', off: audioOnly,
        options: [['mp4', 'mp4'], ['mkv', 'mkv'], ['webm', 'webm'], ['', 'yt-dlp default']] },
      { key: 'audioOnly', label: 'Audio only', type: 'check' },
      { key: 'audioFormat', label: 'Audio format', type: 'select', show: audioOnly, options: same(['mp3', 'm4a', 'opus', 'flac', 'wav', 'best']) },
      { key: 'noPlaylist', label: 'Single video only (ignore playlist)', type: 'check' },
      { key: 'embedMetadata', label: 'Embed metadata', type: 'check' },
      { key: 'embedThumbnail', label: 'Embed thumbnail', type: 'check' },
      { key: 'subtitles', label: 'Download subtitles', type: 'check' },
      { key: 'autoSubs', label: 'Include auto-generated subtitles', type: 'check' },
      { key: 'embedSubs', label: 'Embed subtitles', type: 'check', off: (f) => !f.download.subtitles && !f.download.autoSubs },
      { key: 'subLangs', label: 'Subtitle languages', type: 'text', placeholder: 'en,es or all', show: (f) => f.download.subtitles || f.download.autoSubs },
      { key: 'sponsorBlock', label: 'Remove SponsorBlock segments', type: 'chips', wide: true,
        options: ['sponsor', 'intro', 'outro', 'selfpromo', 'interaction', 'preview', 'filler'] },
      { key: 'cookiesBrowser', label: 'Cookies from browser', type: 'select', advanced: true,
        options: [['', 'None'], ...same(['safari', 'chrome', 'firefox', 'edge', 'brave'])] },
      { key: 'rateLimit', label: 'Rate limit', type: 'text', placeholder: 'e.g. 2M', advanced: true },
      { key: 'proxy', label: 'Proxy', type: 'text', placeholder: 'http://host:port', advanced: true },
      { key: 'formatSort', label: 'Format sort (-S)', type: 'text', placeholder: 'res,codec:h264', advanced: true },
      { key: 'customFormat', label: 'Custom format (-f), overrides quality', type: 'text', advanced: true },
      { key: 'extraArgs', label: 'Extra yt-dlp arguments', type: 'text', placeholder: '--retries 10', advanced: true, wide: true },
    ],
  },
  {
    key: 'transcode', title: 'Convert', tool: 'HandBrake', fields: [
      { key: 'skip', label: 'Skip converting (keep the download as it is)', type: 'check', wide: true, off: audioOnly },
      { key: 'preset', label: 'Preset', type: 'preset', off: noTranscode },
      { key: 'container', label: 'Container', type: 'select', off: noTranscode, options: same(['mp4', 'mkv', 'webm']) },
      { key: 'encoder', label: 'Video encoder', type: 'select', off: noTranscode,
        options: [['', 'Preset default'], ['x264', 'H.264 (x264)'], ['x265', 'H.265 (x265)'], ['vt_h264', 'H.264 (VideoToolbox)'],
          ['vt_h265', 'H.265 (VideoToolbox)'], ['svt_av1', 'AV1 (SVT)'], ['vp9', 'VP9']] },
      { key: 'qualityMode', label: 'Quality', type: 'select', off: noTranscode,
        options: [['', 'Preset default'], ['rf', 'Constant quality (RF)'], ['bitrate', 'Average bitrate']] },
      { key: 'quality', label: 'RF (lower is better)', type: 'range', min: 0, max: 51, step: 0.5, off: noTranscode,
        show: (f) => f.transcode.qualityMode === 'rf' },
      { key: 'videoBitrate', label: 'Video bitrate (kbps)', type: 'number', off: noTranscode, show: (f) => f.transcode.qualityMode === 'bitrate' },
      { key: 'maxWidth', label: 'Max width (px, 0 = no limit)', type: 'number', off: noTranscode },
      { key: 'maxHeight', label: 'Max height (px, 0 = no limit)', type: 'number', off: noTranscode },
      { key: 'webOptimize', label: 'Web optimized (mp4)', type: 'check', off: noTranscode },
      { key: 'allAudio', label: 'Keep all audio tracks', type: 'check', off: noTranscode },
      { key: 'allSubs', label: 'Keep all subtitle tracks', type: 'check', off: noTranscode },
      { key: 'encoderPreset', label: 'Encoder speed', type: 'select', advanced: true, off: noTranscode,
        options: [['', 'Preset default'], ...same(['ultrafast', 'veryfast', 'fast', 'medium', 'slow', 'slower', 'veryslow'])] },
      { key: 'framerate', label: 'Framerate', type: 'select', advanced: true, off: noTranscode,
        options: [['', 'Same as source'], ...same(['23.976', '24', '25', '29.97', '30', '50', '59.94', '60'])] },
      { key: 'framerateMode', label: 'Framerate mode', type: 'select', advanced: true, off: noTranscode,
        options: [['vfr', 'Variable'], ['cfr', 'Constant'], ['pfr', 'Peak-limited']] },
      { key: 'deinterlace', label: 'Deinterlace', type: 'select', advanced: true, off: noTranscode,
        options: [['', 'Off'], ['decomb', 'Decomb'], ['yadif', 'Yadif']] },
      { key: 'audioEncoder', label: 'Audio encoder', type: 'select', advanced: true, off: noTranscode,
        options: [['', 'Preset default'], ['av_aac', 'AAC'], ['ac3', 'AC3'], ['opus', 'Opus'], ['mp3', 'MP3'], ['copy', 'Passthru (copy)']] },
      { key: 'audioBitrate', label: 'Audio bitrate (kbps, 0 = default)', type: 'number', advanced: true, off: noTranscode },
      { key: 'extraArgs', label: 'Extra HandBrakeCLI arguments', type: 'text', placeholder: '--rotate=angle=90', advanced: true, wide: true, off: noTranscode },
    ],
  },
  {
    key: 'output', title: 'Save', tool: 'on this Mac', fields: [
      { key: 'dir', label: 'Folder', type: 'folder', placeholder: 'Defaults to ~/Downloads', wide: true },
      { key: 'filename', label: 'File name (no extension; blank = video title)', type: 'text', wide: true, transient: true },
      { key: 'keepSource', label: 'Also keep the original download', type: 'check' },
      { key: 'overwrite', label: 'Overwrite an existing file', type: 'check' },
    ],
  },
]
