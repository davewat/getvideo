import SwiftUI

/// What GetVideo is, who it is for, and whose work it stands on.
struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    HStack(spacing: 0) {
                        ForEach(Array(Color.bars.enumerated()), id: \.offset) { $0.element }
                    }
                    .frame(width: 54, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GetVideo").font(.title).fontWeight(.semibold)
                        Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("Paste a link. Get a file.").font(.title3)
                Text("GetVideo saves an educational video to your Mac, so you can show it in class without the internet and without the adverts.")
                Text("For educational use only. Save only videos you have the right to keep and show, and follow the terms of the site they come from.")
                    .foregroundStyle(.secondary)

                GroupBox("On the shoulders of giants") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("GetVideo is a thin layer. The hard work is done by open-source projects that volunteers have built and maintained for years.")
                        credit("yt-dlp", "does every download", "https://github.com/yt-dlp/yt-dlp")
                        credit("HandBrake", "does every conversion", "https://handbrake.fr")
                        credit("FFmpeg", "joins video and audio", "https://ffmpeg.org")
                        Text("GetVideo is an independent project and is not affiliated with or endorsed by any of them, or by YouTube.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                HStack(spacing: 16) {
                    Link("Website", destination: URL(string: "https://davewat.github.io/getvideo/")!)
                    Link("Source on GitHub", destination: URL(string: "https://github.com/davewat/getvideo")!)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func credit(_ name: String, _ what: String, _ url: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Link(name, destination: URL(string: url)!)
            Text(what).foregroundStyle(.secondary)
        }
    }
}
