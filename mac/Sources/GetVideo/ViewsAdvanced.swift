import SwiftUI

/// The Advanced page: the full form, then the queue, then the tools, stacked in one column.
struct AdvancedView: View {
    @Binding var expanded: Set<UUID>
    @State private var moreDownload = false
    @State private var moreConvert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                form
                sidebar
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private var form: some View {
        AdvancedForm(moreDownload: $moreDownload, moreConvert: $moreConvert)
    }

    private var sidebar: some View {
        VStack(spacing: 20) {
            QueueCard(expanded: $expanded)
            ToolsCard()
        }
    }
}

/// The Advanced form: the link box, one section per stage, the defaults bar and the button.
struct AdvancedForm: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var form: LinkForm
    @Binding var moreDownload: Bool
    @Binding var moreConvert: Bool
    @State private var confirmReset = false
    @State private var keyRevision = 0

    // Inputs flow into as many columns as fit; switches use the same columns, packed tighter.
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 16, alignment: .top)]

    private var d: DownloadOptions { settings.draft.download }
    private var t: TranscodeOptions { settings.draft.transcode }
    private var audioOnly: Bool { d.audioOnly }
    private var noTranscode: Bool { t.skip || d.audioOnly }
    private var anySubs: Bool { d.subtitles || d.autoSubs }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LinkSection()
            VStack(alignment: .leading, spacing: 0) {
                section(.download, tool: "yt-dlp") { download }
                section(.convert, tool: "HandBrake") { convert }
                section(.write, tool: "AI provider", title: "PDF Guides") { guide }
                section(.save, tool: "on this Mac", last: true) { save }
            }
            defaultsBar
            SubmitSection(isEasy: false)
        }
        .card()
    }

    // MARK: Sections

    private func section<Content: View>(_ stage: Stage, tool: String, title: String? = nil, last: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        let name = title ?? stage.label
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 9) {
                Swatch(stage: stage)
                SlateText(name)
                Text(tool).font(.timecode()).foregroundStyle(Color.soft)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) (\(tool))")
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, 18)
        .padding(.bottom, last ? 0 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }

    private func inputs<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14, content: content)
    }

    private func switches<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4, content: content)
    }

    private func more<Content: View>(_ isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        let fields = content()
        return DisclosureGroup("More options", isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 14) { fields }
                .padding(.top, 12)
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private var download: some View {
        let o = $settings.draft.download
        inputs {
            SelectField("Max quality", selection: o.maxHeight, options: [
                (0, "Best available"), (2160, "2160p (4K)"), (1440, "1440p"), (1080, "1080p"), (720, "720p"),
                (480, "480p"), (360, "360p"),
            ])
            SelectField("Container", selection: o.mergeContainer,
                        options: [("mp4", "mp4"), ("mkv", "mkv"), ("webm", "webm"), ("", "yt-dlp default")])
                .off(audioOnly)
            if audioOnly {
                SelectField("Audio format", selection: o.audioFormat, options: same(["mp3", "m4a", "opus", "flac", "wav", "best"]))
            }
            if anySubs {
                TextBox("Subtitle languages", text: o.subLangs, placeholder: "en,es or all")
            }
        }
        Field("Remove SponsorBlock segments") {
            FlowLayout {
                ForEach(["sponsor", "intro", "outro", "selfpromo", "interaction", "preview", "filler"], id: \.self) { name in
                    Chip(title: name, isOn: d.sponsorBlock.contains(name)) {
                        if d.sponsorBlock.contains(name) {
                            settings.draft.download.sponsorBlock.removeAll { $0 == name }
                        } else {
                            settings.draft.download.sponsorBlock.append(name)
                        }
                    }
                }
            }
        }
        switches {
            SwitchRow("Audio only", isOn: o.audioOnly)
            SwitchRow("Single video only (ignore playlist)", isOn: o.noPlaylist)
            SwitchRow("Embed metadata", isOn: o.embedMetadata)
            SwitchRow("Embed thumbnail", isOn: o.embedThumbnail)
            SwitchRow("Download subtitles", isOn: o.subtitles)
            SwitchRow("Include auto-generated subtitles", isOn: o.autoSubs)
            SwitchRow("Embed subtitles", isOn: o.embedSubs).off(!anySubs)
        }
        SwitchRow("Keep the download until it is converted, so a failed conversion can resume", isOn: o.keepDownload)
            .off(noTranscode)
        more($moreDownload) {
            inputs {
                SelectField("Cookies from browser", selection: o.cookiesBrowser,
                            options: [("", "None")] + same(["safari", "chrome", "firefox", "edge", "brave"]))
                TextBox("Rate limit", text: o.rateLimit, placeholder: "e.g. 2M")
                TextBox("Proxy", text: o.proxy, placeholder: "http://host:port")
                TextBox("Format sort (-S)", text: o.formatSort, placeholder: "res,codec:h264")
                TextBox("Custom format (-f), overrides quality", text: o.customFormat)
            }
            TextBox("Extra yt-dlp arguments", text: o.extraArgs, placeholder: "--retries 10")
        }
    }

    @ViewBuilder private var convert: some View {
        let o = $settings.draft.transcode
        SwitchRow("Skip converting (keep the download as it is)", isOn: o.skip).off(audioOnly)
        inputs {
            presetPicker
            SelectField("Container", selection: o.container, options: same(["mp4", "mkv", "webm"]))
            SelectField("Shorten the video", selection: o.trimMode,
                        options: [("", "Keep the whole video"), ("duration", "To a length"), ("percent", "To a percentage")])
            if t.trimMode == "duration" {
                TextBox("Length to keep", text: o.trimLength, placeholder: "3:00:00")
            }
            if t.trimMode == "percent" {
                Field("Percentage to keep", value: "\(Int(t.trimPercent))%") {
                    Slider(value: Binding(get: { t.trimPercent }, set: { settings.draft.transcode.trimPercent = $0.rounded() }),
                           in: 1...100)
                        .controlSize(.small)
                        .accessibilityLabel("Percentage to keep")
                }
            }
            if t.trimMode != "" {
                SelectField("Keep the", selection: o.trimKeep,
                            options: [("first", "First part"), ("last", "Last part"), ("middle", "Middle")])
            }
            SelectField("Video encoder", selection: o.encoder, options: [
                ("", "Preset default"), ("x264", "H.264 (x264)"), ("x265", "H.265 (x265)"), ("vt_h264", "H.264 (VideoToolbox)"),
                ("vt_h265", "H.265 (VideoToolbox)"), ("svt_av1", "AV1 (SVT)"), ("vp9", "VP9"),
            ])
            SelectField("Quality", selection: o.qualityMode,
                        options: [("", "Preset default"), ("rf", "Constant quality (RF)"), ("bitrate", "Average bitrate")])
            if t.qualityMode == "rf" {
                Field("RF (lower is better)", value: t.quality.formatted(.number.precision(.fractionLength(0...1)))) {
                    // Snapped to halves here rather than with `step:`, which would draw 100 tick marks.
                    Slider(value: Binding(get: { t.quality }, set: { settings.draft.transcode.quality = ($0 * 2).rounded() / 2 }),
                           in: 0...51)
                        .controlSize(.small)
                        .accessibilityLabel("RF (lower is better)")
                }
            }
            if t.qualityMode == "bitrate" {
                NumberBox("Video bitrate (kbps)", value: o.videoBitrate)
            }
            NumberBox("Max width (px, 0 = no limit)", value: o.maxWidth)
            NumberBox("Max height (px, 0 = no limit)", value: o.maxHeight)
        }
        .off(noTranscode)
        if t.trimMode == "duration" {
            Text("Length: hours:minutes:seconds, such as 3:00:00. Or 90m, or 1h30m.").hint().off(noTranscode)
        }
        switches {
            SwitchRow("Web optimized (mp4)", isOn: o.webOptimize)
            SwitchRow("Keep all audio tracks", isOn: o.allAudio)
            SwitchRow("Keep all subtitle tracks", isOn: o.allSubs)
        }
        .off(noTranscode)
        more($moreConvert) {
            inputs {
                SelectField("Encoder speed", selection: o.encoderPreset, options: [("", "Preset default")]
                    + same(["ultrafast", "veryfast", "fast", "medium", "slow", "slower", "veryslow"]))
                SelectField("Framerate", selection: o.framerate, options: [("", "Same as source")]
                    + same(["23.976", "24", "25", "29.97", "30", "50", "59.94", "60"]))
                SelectField("Framerate mode", selection: o.framerateMode,
                            options: [("vfr", "Variable"), ("cfr", "Constant"), ("pfr", "Peak-limited")])
                SelectField("Deinterlace", selection: o.deinterlace, options: [("", "Off"), ("decomb", "Decomb"), ("yadif", "Yadif")])
                SelectField("Audio encoder", selection: o.audioEncoder, options: [
                    ("", "Preset default"), ("av_aac", "AAC"), ("ac3", "AC3"), ("opus", "Opus"), ("mp3", "MP3"),
                    ("copy", "Passthru (copy)"),
                ])
                NumberBox("Audio bitrate (kbps, 0 = default)", value: o.audioBitrate)
            }
            .off(noTranscode)
            TextBox("Extra HandBrakeCLI arguments", text: o.extraArgs, placeholder: "--rotate=angle=90")
                .off(noTranscode)
        }
    }

    /// HandBrake's presets by category, plus "(none)" and the current value if HandBrake does
    /// not list it (a saved preset from another version, or the list has not loaded yet).
    private var presetPicker: some View {
        let known = tools.presets.contains { $0.presets.contains(t.preset) }
        return Field("Preset") {
            Picker("Preset", selection: $settings.draft.transcode.preset) {
                Text("(none)").tag("")
                if !t.preset.isEmpty, !known {
                    Text(t.preset).tag(t.preset)
                }
                ForEach(tools.presets) { group in
                    Section(group.category) {
                        ForEach(group.presets, id: \.self) { preset in
                            Text(preset).tag(preset)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The "Make a guide" options: what to write and which AI service writes it.
    @ViewBuilder private var guide: some View {
        let o = $settings.draft.guide
        let g = settings.draft.guide
        Text("Used by GetPDF. The video's captions are sent to the AI service you choose.").hint()
        inputs {
            SelectField("Style", selection: o.style, options: [
                ("full", "Full guide"), ("summary", "Summary"), ("notes", "Study notes"), ("tutorial", "Step-by-step tutorial"),
            ])
            SelectField("AI provider", selection: o.provider, options: GuideProvider.all.map { ($0.id, $0.title) })
            GuideModelField(options: o, keyRevision: keyRevision)
            TextBox("Base URL", text: o.baseURL, placeholder: g.effectiveBaseURL)
            NumberBox("Most screenshots", value: o.maxShots)
        }
        .onChange(of: g.provider) { _, new in
            // The old address and model belong to the old service.
            settings.draft.guide.baseURL = GuideProvider.named(new).baseURL
            settings.draft.guide.model = ""
        }
        GuideKeyField(provider: g.provider, revision: $keyRevision)
        switches {
            SwitchRow("Dark PDF", isOn: o.dark)
            SwitchRow("Large text", isOn: o.largeText)
        }
    }

    @ViewBuilder private var save: some View {
        let o = $settings.draft.output
        Field("Working folder") {
            HStack(spacing: 8) {
                TextField("", text: o.dir, prompt: Text("Defaults to ~/Downloads"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Working folder")
                Button("Choose folder", action: chooseFolder)
            }
        }
        Text("Videos are saved here. Downloads and conversions also keep their temporary files here, in a hidden folder that is removed when each video finishes.")
            .hint()
        TextBox("File name (no extension; blank = video title)", text: o.filename)
        switches {
            SwitchRow("Also keep the original download", isOn: o.keepSource)
            SwitchRow("Overwrite an existing file", isOn: o.overwrite)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose folder"
        if !settings.draft.output.dir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (settings.draft.output.dir as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            settings.draft.output.dir = url.path
        }
    }

    // MARK: Defaults

    /// Saving the form as the defaults Easy mode uses.
    private var defaultsBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button("Save as default") {
                form.error = nil
                do {
                    try settings.saveDraftAsDefault()
                } catch {
                    form.error = "Defaults not saved: \(userMessage(error))"
                }
            }
            .disabled(!settings.isDirty)
            Text(settings.isDirty ? "Not saved yet. Easy mode keeps using your previous defaults."
                : settings.hasSaved ? "Saved. Easy mode uses these settings." : "These are the built-in defaults.")
                .hint()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if settings.hasSaved {
                LinkButton("Reset to built-in defaults") { confirmReset = true }
            }
        }
        .padding(.top, 18)
        .overlay(alignment: .top) { Hairline() }
        .confirmationDialog("Discard your saved defaults and go back to the built-in ones?", isPresented: $confirmReset) {
            Button("Reset to built-in defaults", role: .destructive) { settings.resetToBuiltIn() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func same(_ values: [String]) -> [(String, String)] { values.map { ($0, $0) } }
}

/// The API key box. The key goes to the Keychain when saved and is never kept in the settings.
struct GuideKeyField: View {
    let provider: String
    /// Counts key changes, so the Model box knows to ask for its list again.
    @Binding var revision: Int
    @State private var key = ""
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        Field("API key") {
            HStack(spacing: 8) {
                SecureField("", text: $key, prompt: Text(saved ? "Saved in the Keychain" : "Paste your API key"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("API key")
                    .onSubmit(save)
                Button("Save key", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if saved { Button("Remove") { store("") } }
            }
        }
        .onAppear { saved = Keychain.get(provider) != nil }
        .onChange(of: provider) { _, new in
            key = ""
            saved = Keychain.get(new) != nil
        }
        if let error { Text(error).font(.system(size: 13)).foregroundStyle(Color.barRed) }
    }

    private func save() { store(key) }

    private func store(_ value: String) {
        do {
            try Keychain.set(value, for: provider)
            error = nil
            key = ""
            saved = Keychain.get(provider) != nil
            revision += 1
        } catch {
            self.error = userMessage(error)
        }
    }
}

/// The Model box. Once there is a key (or a local service) it asks which models are available
/// and offers them in a menu; anything can still be typed.
struct GuideModelField: View {
    @Binding var options: GuideOptions
    let keyRevision: Int
    @State private var all: [ModelList.Entry] = []
    @State private var loading = false
    @State private var problem: String?

    /// The checkbox only means something when the service marked some models free.
    private var canFilter: Bool { all.contains(where: \.free) }
    private var models: [String] { all.filter { !(canFilter && options.freeOnly) || $0.free }.map(\.id) }

    private var task: String { "\(options.provider)|\(options.effectiveBaseURL)|\(keyRevision)" }

    var body: some View {
        Field("Model") {
            HStack(spacing: 8) {
                TextField("", text: $options.model, prompt: Text(options.effectiveModel))
                    .accessibilityLabel("Model")
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if loading {
                    ProgressView().controlSize(.small)
                } else if !models.isEmpty {
                    Menu("Models") {
                        ForEach(models, id: \.self) { id in Button(id) { options.model = id } }
                    }
                    .fixedSize()
                }
            }
            if canFilter { Toggle("Free models only", isOn: $options.freeOnly).toggleStyle(.checkbox) }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Color.soft) }
        }
        .task(id: task) { await load() }
    }

    private func load() async {
        all = []
        problem = nil
        let key = Keychain.get(options.provider)
        guard key != nil || options.isLocal else { return }
        // Typing in the Base URL box changes the task id on every key; wait for a pause.
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await ModelList.fetch(options, apiKey: key ?? "")
            guard !Task.isCancelled else { return }
            all = found
            // Fill an empty box only when the default is not on offer.
            if options.model.isEmpty, let first = models.first, !models.contains(options.effectiveModel) { options.model = first }
        } catch is CancellationError {
        } catch {
            problem = "Could not list models: \(userMessage(error))"
        }
    }
}
