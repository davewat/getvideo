import SwiftUI

// Shared building blocks: every card, label, button and field in the app is one of these, so no
// screen spells out a colour or a radius of its own.

// MARK: - Cards and lettering

extension View {
    /// The panel every block of content sits in.
    func card() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deck, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line, lineWidth: 1))
    }

    /// Small secondary text under or beside a control.
    func hint() -> some View {
        font(.system(size: 12)).foregroundStyle(Color.soft)
    }

    /// Greys out and disables a field whose option does not apply right now.
    func off(_ off: Bool) -> some View {
        disabled(off).opacity(off ? 0.4 : 1)
    }
}

/// Condensed uppercase lettering for headings and field-group labels.
struct SlateText: View {
    let text: String
    var size: CGFloat = 14

    init(_ text: String, size: CGFloat = 14) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(.slate(size))
            .tracking(1.2)
            .accessibilityLabel(text)
    }
}

/// The stage's colour chip, shown wherever a stage is named.
struct Swatch: View {
    let stage: Stage

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(stage.color)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

/// A card's heading with an optional action on the right.
struct CardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SlateText(title).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.line).frame(height: 1).accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// The one full-width action of a form ("Get video", "Add to queue").
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    // A view of its own so it can read whether the button is enabled.
    private struct Face: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.deck)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.ink.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

/// A tertiary action: plain blue text.
struct LinkButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .font(.system(size: 12))
    }
}

/// A secondary action: the standard small bordered button.
struct SmallButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// A toggle chip: filled when on.
struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Color.deck : Color.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 3)
                .background(isOn ? Color.ink : Color.well, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Color.ink : Color.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Fields

/// A labelled control: small grey label above, the control below.
struct Field<Content: View>: View {
    let label: String
    /// Shown after the label in timecode lettering (a slider's current value).
    var value: String?
    @ViewBuilder var content: Content

    init(_ label: String, value: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.value = value
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(label).hint()
                if let value {
                    Text(value).font(.timecode()).foregroundStyle(Color.ink)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A pop-up menu over a fixed list of (value, title) pairs.
struct SelectField<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]

    init(_ label: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.label = label
        _selection = selection
        self.options = options
    }

    var body: some View {
        Field(label) {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.0) { value, title in
                    Text(title).tag(value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A one-line text box for options that are passed on as typed.
struct TextBox: View {
    let label: String
    @Binding var text: String
    var placeholder = ""

    init(_ label: String, text: Binding<String>, placeholder: String = "") {
        self.label = label
        _text = text
        self.placeholder = placeholder
    }

    var body: some View {
        Field(label) {
            // An empty title: outside a Form, macOS would show the title as the placeholder.
            TextField("", text: $text, prompt: placeholder.isEmpty ? nil : Text(placeholder))
                .accessibilityLabel(label)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }
}

/// A whole number of zero or more. The value follows every keystroke, so a number typed just
/// before pressing the form's button is never lost; anything that is not a number counts as 0.
struct NumberBox: View {
    let label: String
    @Binding var value: Int
    @State private var text = ""

    init(_ label: String, value: Binding<Int>) {
        self.label = label
        _value = value
    }

    var body: some View {
        Field(label) {
            TextField("", text: $text)
                .accessibilityLabel(label)
                .textFieldStyle(.roundedBorder)
                .font(.timecode())
                .autocorrectionDisabled()
        }
        .onAppear { text = String(value) }
        .onChange(of: text) { _, new in
            let n = max(0, Int(new.trimmingCharacters(in: .whitespaces)) ?? 0)
            if n != value { value = n }
        }
        .onChange(of: value) { _, new in
            // Changed from outside (a reset): show it, but never rewrite what is being typed.
            if max(0, Int(text.trimmingCharacters(in: .whitespaces)) ?? 0) != new { text = String(new) }
        }
    }
}

/// A switch with its label on the right, as in the web version.
struct SwitchRow: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Text(label)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture { isOn.toggle() }
                .accessibilityHidden(true) // the switch already carries the label
        }
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
    }
}

// MARK: - Layouts

/// Lays children out left to right, wrapping to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (i, frame) in rows.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                              proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            // An item wider than the row gets the whole row and wraps inside it.
            let size = sub.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
}

/// A row whose children share the width in proportion to their `rowWeight`.
struct WeightedRow: Layout {
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        let height = zip(subviews, widths(subviews, total: width))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (sub, width) in zip(subviews, widths(subviews, total: bounds.width)) {
            sub.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func widths(_ subviews: Subviews, total: CGFloat) -> [CGFloat] {
        let weights = subviews.map { $0[RowWeight.self] }
        let sum = weights.reduce(0, +)
        let room = max(0, total - spacing * CGFloat(max(0, subviews.count - 1)))
        return weights.map { sum > 0 ? room * $0 / sum : 0 }
    }
}

private struct RowWeight: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

extension View {
    /// This view's share of a `WeightedRow` (1 by default).
    func rowWeight(_ weight: CGFloat) -> some View {
        layoutValue(key: RowWeight.self, value: weight)
    }
}
