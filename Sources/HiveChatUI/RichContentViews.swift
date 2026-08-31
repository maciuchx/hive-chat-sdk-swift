import SwiftUI
import HiveChat

// MARK: - Product card

struct ProductCardView: View {
    let card: ProductCard
    var onTap: ((ProductCard) -> Void)?
    var onOpenURL: ((URL) -> Bool)?
    @Environment(\.hiveChatTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            /* The host app gets first refusal: if it handles products itself
               the customer never leaves the app, which is the whole point of
               a native chat. */
            if let onTap {
                onTap(card)
            } else if let url = card.buyURL, onOpenURL?(url) != true {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let imageURL = card.imageURL {
                    AsyncImage(url: imageURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Rectangle().fill(HivePalette.tertiaryFill)
                    }
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .background(HivePalette.secondaryBackground)
                    .clipped()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)

                    if let price = card.price, price > 0 {
                        Text(price, format: .currency(code: Locale.current.currency?.identifier ?? "GBP"))
                            .font(.headline)
                            .foregroundColor(.primary)
                    }

                    if let message = card.message, !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(theme.secondaryText)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(12)
            }
        }
        .buttonStyle(.plain)
        .background(HivePalette.background)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(HivePalette.separator.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityHint(onTap == nil ? "Opens the product page" : "Opens the product")
    }
}

// MARK: - Article card

struct ArticleCardView: View {
    let card: ArticleCard
    let onOpen: () -> Void
    @Environment(\.hiveChatTheme) private var theme

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundColor(theme.brandColor)
                    .frame(width: 34, height: 34)
                    .background(theme.brandColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 3) {
                    Text("HELP ARTICLE")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(theme.brandColor)
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    if let excerpt = card.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(.footnote)
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .background(HivePalette.background)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(HivePalette.separator.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
    }
}

// MARK: - Attachments

struct AttachmentContent: View {
    let attachment: Attachment
    @Environment(\.hiveChatTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch attachment.kind {
        case .image:
            imageView
        default:
            filePill
        }
    }

    @ViewBuilder
    private var imageView: some View {
        if let url = attachment.url {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(HivePalette.tertiaryFill)
                    .overlay(ProgressView())
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            /* Still uploading: the SDK has no local URL to show, so hold the
               space rather than collapsing the row and jolting the thread. */
            RoundedRectangle(cornerRadius: 12)
                .fill(HivePalette.tertiaryFill)
                .frame(width: 220, height: 220)
                .overlay(ProgressView())
        }
    }

    private var filePill: some View {
        Button {
            if let url = attachment.url { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(attachment.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if attachment.isUploading { ProgressView().scaleEffect(0.7) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(attachment.url == nil)
    }

    private var icon: String {
        switch attachment.kind {
        case .video: return "play.rectangle"
        case .audio: return "waveform"
        default: return "doc"
        }
    }
}

// MARK: - Link previews

struct LinkPreviewView: View {
    let preview: LinkPreview
    @Environment(\.hiveChatTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: preview.url) { openURL(url) }
        } label: {
            HStack(spacing: 10) {
                if let image = preview.imageURL, let url = URL(string: image) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                        HivePalette.tertiaryFill
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let site = preview.siteName {
                        Text(site).font(.caption2).foregroundColor(theme.secondaryText)
                    }
                    Text(preview.title ?? preview.url)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 300)
        .background(HivePalette.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Forms

struct FormCardView: View {
    let form: ChatForm
    let onSubmit: ([String: String]) -> Void

    @State private var values: [String: String] = [:]
    @State private var hasSubmitted = false
    @Environment(\.hiveChatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(form.name).font(.subheadline.weight(.bold))
            if let description = form.description, !description.isEmpty {
                Text(description).font(.footnote).foregroundColor(theme.secondaryText)
            }

            if hasSubmitted {
                Label("Thanks — that's been sent.", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundColor(.green)
            } else {
                ForEach(form.fields) { field in
                    FormFieldView(field: field, value: binding(for: field))
                }

                Button {
                    guard isValid else { return }
                    hasSubmitted = true
                    onSubmit(values)
                } label: {
                    Text("Submit")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(theme.brandFill)
                        .foregroundColor(theme.onBrandColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!isValid)
                .opacity(isValid ? 1 : 0.5)
            }
        }
        .padding(14)
        .background(HivePalette.background)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(HivePalette.separator.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
    }

    private var isValid: Bool {
        form.fields.allSatisfy { field in
            guard field.required else { return true }
            /* A required checkbox means "must be ticked" — the dashboard uses
               them for consent — so an unticked one is not merely empty. */
            if field.type == .checkbox { return values[field.key] == "Yes" }
            return !(values[field.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func binding(for field: ChatForm.Field) -> Binding<String> {
        Binding(
            get: { values[field.key] ?? defaultValue(for: field) },
            set: { values[field.key] = $0 }
        )
    }

    private func defaultValue(for field: ChatForm.Field) -> String {
        switch field.type {
        case .checkbox: return "No"
        case .select: return field.options.first ?? ""
        default: return ""
        }
    }
}

private struct FormFieldView: View {
    let field: ChatForm.Field
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if field.type != .checkbox {
                HStack(spacing: 2) {
                    Text(field.label).font(.caption.weight(.semibold))
                    if field.required { Text("*").foregroundColor(.red).font(.caption) }
                }
            }

            switch field.type {
            case .textarea:
                TextEditor(text: $value)
                    .frame(height: 72)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(HivePalette.separator, lineWidth: 1))
            case .select:
                Picker(field.label, selection: $value) {
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            case .checkbox:
                Toggle(isOn: Binding(
                    get: { value == "Yes" },
                    set: { value = $0 ? "Yes" : "No" }
                )) {
                    Text(field.label).font(.caption)
                }
            default:
                TextField(field.placeholder ?? "", text: $value)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS) || os(visionOS)
                    .keyboardType(field.type == .email ? .emailAddress : field.type == .number ? .numberPad : .default)
                    .textInputAutocapitalization(field.type == .email ? .never : .sentences)
                    #endif
                    .autocorrectionDisabled(field.type == .email)
            }
        }
    }
}

struct FormResponseView: View {
    let response: FormResponse
    @Environment(\.hiveChatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(response.formName).font(.caption.weight(.bold)).foregroundColor(theme.secondaryText)
            ForEach(response.entries) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.label).font(.caption2).foregroundColor(theme.secondaryText)
                    Text(entry.value.isEmpty ? "—" : entry.value).font(.footnote)
                }
            }
        }
        .padding(12)
        .background(HivePalette.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
    }
}
