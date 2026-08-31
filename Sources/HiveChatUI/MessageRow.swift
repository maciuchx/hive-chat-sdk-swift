import SwiftUI
import HiveChat

/// One row in the thread: a bubble, a card, or a system line.
struct MessageRow: View {
    let message: ChatMessage
    let previews: [LinkPreview]
    let onReact: (String) -> Void
    let onOpenArticle: (ArticleCard) -> Void
    let onSubmitForm: (ChatForm, [String: String]) -> Void
    var onProductTap: ((ProductCard) -> Void)?
    var onOpenURL: ((URL) -> Bool)?

    @Environment(\.hiveChatTheme) private var theme

    var body: some View {
        switch message.content {
        case .text(let body):
            bubble { Text(body) }
        case .attachment(let attachment):
            bubble(padded: false) { AttachmentContent(attachment: attachment) }
        case .productCard(let card):
            CardContainer(alignment: .leading) {
                ProductCardView(card: card, onTap: onProductTap, onOpenURL: onOpenURL)
            }
        case .articleCard(let card):
            CardContainer(alignment: .leading) {
                ArticleCardView(card: card) { onOpenArticle(card) }
            }
        case .form(let form):
            CardContainer(alignment: .leading) {
                FormCardView(form: form) { values in onSubmitForm(form, values) }
            }
        case .formResponse(let response):
            CardContainer(alignment: .trailing) { FormResponseView(response: response) }
        case .unsupported:
            /* A sentinel this version does not know. Rendering the raw
               marker would show the customer machine noise, so we say
               nothing — the agent still sees whatever they sent. */
            EmptyView()
        }
    }

    @ViewBuilder
    private func bubble<Content: View>(
        padded: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if message.sender == .system {
            Text(message.content.previewText)
                .font(.caption)
                .foregroundColor(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                if !isOutgoing, let name = message.senderName, !name.isEmpty {
                    Text(name)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 6)
                }

                content()
                    .font(theme.font ?? .body)
                    .padding(.horizontal, padded ? 14 : 4)
                    .padding(.vertical, padded ? 10 : 4)
                    .foregroundColor(isOutgoing ? theme.onBrandColor : theme.incomingText)
                    .background(bubbleBackground)
                    .clipShape(BubbleShape(isOutgoing: isOutgoing, radius: theme.cornerRadius))
                    .frame(maxWidth: 300, alignment: isOutgoing ? .trailing : .leading)
                    .contextMenu { reactionMenu }

                if !previews.isEmpty {
                    ForEach(previews) { LinkPreviewView(preview: $0) }
                }

                if !message.reactions.isEmpty {
                    ReactionRow(reactions: message.reactions, onTap: onReact)
                }

                footer
            }
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isOutgoing {
            theme.brandFill
        } else {
            theme.incomingBubble
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 4) {
            Text(message.createdAt, style: .time)
            if isOutgoing {
                switch message.delivery {
                case .sending:
                    Image(systemName: "clock")
                case .failed:
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(.red)
                case .sent:
                    Image(systemName: message.isRead ? "checkmark.circle.fill" : "checkmark")
                        .foregroundColor(message.isRead ? theme.brandColor : theme.secondaryText)
                }
            }
        }
        .font(.caption2)
        .foregroundColor(theme.secondaryText)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityFooterLabel)
    }

    private var accessibilityFooterLabel: String {
        guard isOutgoing else { return "" }
        switch message.delivery {
        case .sending: return "Sending"
        case .failed: return "Failed to send"
        case .sent: return message.isRead ? "Read" : "Sent"
        }
    }

    @ViewBuilder
    private var reactionMenu: some View {
        ForEach(["👍", "❤️", "😂", "🙏", "😮"], id: \.self) { emoji in
            Button(emoji) { onReact(emoji) }
        }
    }

    private var isOutgoing: Bool { message.sender == .visitor }
}

/// An asymmetric bubble — the corner nearest the sender is squared off.
private struct BubbleShape: Shape {
    let isOutgoing: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = 4
        return Path(roundedRect: rect, cornerRadii: .init(
            topLeading: radius,
            bottomLeading: isOutgoing ? radius : tail,
            bottomTrailing: isOutgoing ? tail : radius,
            topTrailing: radius
        ))
    }
}

private extension Path {
    init(roundedRect rect: CGRect, cornerRadii: (topLeading: CGFloat, bottomLeading: CGFloat, bottomTrailing: CGFloat, topTrailing: CGFloat)) {
        /* Hand-rolled rather than using `UnevenRoundedRectangle`, which is
           iOS 16+; this package supports 15. */
        var path = Path()
        let (tl, bl, br, tr) = cornerRadii
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        self = path
    }
}

/// Wraps a card so it aligns like a bubble without inheriting bubble styling.
struct CardContainer<Content: View>: View {
    enum Alignment { case leading, trailing }
    let alignment: Alignment
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

struct ReactionRow: View {
    let reactions: [Reaction]
    let onTap: (String) -> Void
    @Environment(\.hiveChatTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    onTap(reaction.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(reaction.emoji)
                        if reaction.count > 1 {
                            Text("\(reaction.count)").font(.caption2)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(reaction.isMine ? theme.brandColor.opacity(0.15) : HivePalette.tertiaryFill)
                    )
                    .overlay(
                        Capsule().stroke(reaction.isMine ? theme.brandColor.opacity(0.4) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }
}
