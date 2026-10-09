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
                section(.save, tool: "on this Mac", last: true) { save }
            }
            defaultsBar
            SubmitSection(isEasy: false)
        }
        .card()
    }

    // MARK: Sections

    private func section<Content: View>(_ stage: Stage, tool: String, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 9) {
                Swatch(stage: stage)
                SlateText(stage.label)
                Text(tool).font(.timecode()).foregroundStyle(Color.soft)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(stage.label) (\(tool))")
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
