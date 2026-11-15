import Foundation

/// Turns Mastodon statuses into items for the store.
public enum MastodonMapper {
    /// The ID Influx gives a signed-in Mastodon account: `@user@instance`.
    public static func accountID(for account: Mastodon.Account, on instance: URL) -> String {
        "@" + fullAcct(account.acct, instanceHost: instance.host() ?? "")
    }

    public static func homeSource(accountID: String, colorIndex: Int) -> Source {
        Source(id: "mastodon:\(accountID):home", kind: .mastodonHome, accountID: accountID, title: "Home", colorIndex: colorIndex)
    }

    public static func listSource(_ list: Mastodon.List, accountID: String, colorIndex: Int) -> Source {
        Source(id: "mastodon:\(accountID):list:\(list.id)", kind: .mastodonList, accountID: accountID, title: list.title, colorIndex: colorIndex)
    }

    /// Maps a page of statuses fetched from `source` on the instance at
    /// `instanceHost`. Statuses the reader's own server-side filters hide are
    /// left out.
    public static func items(from statuses: [Mastodon.Status], source sourceID: String, instanceHost: String, fetchedAt: Date) -> [Item] {
        statuses.compactMap { item(from: $0, source: sourceID, instanceHost: instanceHost, fetchedAt: fetchedAt) }
    }

    static func item(from entry: Mastodon.Status, source sourceID: String, instanceHost: String, fetchedAt: Date) -> Item? {
        // A boost is a status of its own wrapping the boosted one: the row
        // shows the boosted post, sits at the boost's date, and names the
        // booster.
        let post = entry.reblog ?? entry
        if isHidden(entry) || isHidden(post) {
            return nil
        }

        var (body, links) = MastodonHTML.textAndLinks(post.content)
        if !post.spoilerText.isEmpty {
            let prefix = body.isEmpty ? post.spoilerText : "\(post.spoilerText)\n\n"
            links = links.map { Item.Link(start: $0.start + prefix.utf16.count, length: $0.length, url: $0.url) }
            body = body.isEmpty ? prefix : prefix + body
        }

        return Item(
            sourceID: sourceID,
            remoteID: entry.id,
            kind: .post,
            mergeKey: mergeKey(uri: post.uri),
            authorName: displayName(post.account),
            authorHandle: "@" + fullAcct(post.account.acct, instanceHost: instanceHost),
            authorAvatar: avatar(post.account),
            body: body,
            url: post.url ?? post.uri,
            publishedAt: post.createdAt,
            fetchedAt: fetchedAt,
            sortDate: entry.createdAt,
            boostedBy: entry.reblog == nil ? nil : displayName(entry.account),
            boostedByID: entry.reblog == nil ? nil : accountKey(entry.account, instanceHost: instanceHost),
            boostedByAvatar: entry.reblog == nil ? nil : avatar(entry.account),
            replyToHandle: replyToHandle(post, instanceHost: instanceHost),
            linkCard: linkCard(post),
            media: unsizedMedia(post).compactMap(\.sized),
            actionRef: post.id,
            quote: quote(post, instanceHost: instanceHost),
            viewer: viewer(post),
            links: links
        )
    }

    /// What the signed-in reader has done to `post`.
    static func viewer(_ post: Mastodon.Status) -> Item.Viewer {
        Item.Viewer(liked: post.favourited ?? false, boosted: post.reblogged ?? false, bookmarked: post.bookmarked ?? false)
    }

    /// Where Bridgy Fed serves a Bluesky post to the fediverse:
    /// `https://bsky.brid.gy/convert/ap/at://did:plc:…/app.bsky.feed.post/…`.
    static let bridgedBlueskyPrefix = "https://bsky.brid.gy/convert/ap/"

    /// What makes two statuses the same post: the ActivityPub URI, which
    /// every instance agrees on. A Bluesky post bridged in by Bridgy Fed
    /// takes the `at://` URI it wraps, so it merges with the same post
    /// fetched from Bluesky.
    static func mergeKey(uri: String) -> String {
        guard uri.hasPrefix(bridgedBlueskyPrefix) else { return uri }
        let wrapped = String(uri.dropFirst(bridgedBlueskyPrefix.count))
        let decoded = wrapped.removingPercentEncoding ?? wrapped
        return decoded.hasPrefix("at://") ? decoded : uri
    }

    /// An account as every instance names it: its profile URL, or else its
    /// full handle.
    static func accountKey(_ account: Mastodon.Account, instanceHost: String) -> String {
        account.url ?? "@" + fullAcct(account.acct, instanceHost: instanceHost)
    }

    /// `user` for a local account becomes `user@instance`, so a handle means
    /// the same thing whichever instance it was read from.
    static func fullAcct(_ acct: String, instanceHost: String) -> String {
        acct.contains("@") || instanceHost.isEmpty ? acct : "\(acct)@\(instanceHost)"
    }

    /// The account's profile picture, as a still: an animated avatar would
    /// only show its first frame anyway. Instances serve a stock picture
    /// to accounts that have none, which is kept: it is what the web shows.
    static func avatar(_ account: Mastodon.Account) -> String? {
        (account.avatarStatic ?? account.avatar)?.nilIfEmpty
    }

    /// Whether one of the reader's server-side filters hides `status`.
    static func isHidden(_ status: Mastodon.Status) -> Bool {
        status.filtered?.contains { $0.filter.filterAction == "hide" } ?? false
    }

    /// The post `post` quotes, once its author has let it be quoted. A
    /// quoted post the reader's filters hide, or whose author the reader
    /// muted, is left out, as it would be on its own; the post quoting it
    /// still shows. Any other quote without its post (pending, rejected,
    /// revoked, deleted, unauthorized, blocked, or one Influx can't read)
    /// is an unavailable quote. Mastodon sends no address for it.
    static func quote(_ post: Mastodon.Status, instanceHost: String) -> Item.Quote? {
        guard let shown = post.quote else { return nil }
        guard let quoted = shown.quotedStatus, shown.state.map({ $0 == "accepted" }) ?? true else {
            return shown.state == "muted_account" ? nil : .unavailable(url: nil)
        }
        guard !isHidden(quoted) else { return nil }
        let body = MastodonHTML.text(quoted.content)
        return Item.Quote(
            mergeKey: mergeKey(uri: quoted.uri), url: quoted.url ?? quoted.uri,
            authorName: displayName(quoted.account),
            authorHandle: "@" + fullAcct(quoted.account.acct, instanceHost: instanceHost),
            body: quoted.spoilerText.isEmpty ? body : quoted.spoilerText,
            image: quoteImage(quoted)?.sized
        )
    }

    /// The picture a quote card shows: the quoted post's first attachment
    /// (as a still: a video's preview), else its link card's image. It may
    /// still need sizing (`completing`).
    static func quoteImage(_ quoted: Mastodon.Status) -> UnsizedMedia? {
        if let first = unsizedMedia(quoted).first {
            let still = first.kind == .image ? first.url : first.previewURL
            if let still {
                return UnsizedMedia(kind: .image, url: still, width: first.width, height: first.height, altText: first.altText)
            }
        }
        if let card = quoted.card, let image = card.image {
            let size = pixels(card.width, card.height)
            return UnsizedMedia(kind: .image, url: image, width: size?.width, height: size?.height, altText: card.imageDescription)
        }
        return nil
    }

    private static func displayName(_ account: Mastodon.Account) -> String {
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? account.username : name
    }

    /// The handle a reply answers. Mastodon names the account only by ID,
    /// so the handle comes from the status's mentions, or from its author
    /// when someone replies to themselves (a thread). A reply to an account
    /// it doesn't mention has no chip.
    private static func replyToHandle(_ post: Mastodon.Status, instanceHost: String) -> String? {
        guard post.inReplyToId != nil, let accountID = post.inReplyToAccountId else { return nil }
        if accountID == post.account.id {
            return "@" + fullAcct(post.account.acct, instanceHost: instanceHost)
        }
        return post.mentions.first { $0.id == accountID }.map { "@" + fullAcct($0.acct, instanceHost: instanceHost) }
    }

    /// Mastodon shows a link card only on statuses without media, and so
    /// does Influx. A card image the instance sent no size for is dropped.
    private static func linkCard(_ post: Mastodon.Status) -> Item.LinkCard? {
        guard post.mediaAttachments.isEmpty, let card = post.card, !card.title.isEmpty else { return nil }
        let provider = card.providerName?.trimmingCharacters(in: .whitespaces) ?? ""
        let site = provider.isEmpty ? (URL(string: card.url)?.host() ?? card.url) : provider
        let image = card.image.flatMap { url in
            pixels(card.width, card.height).flatMap { Item.Media(kind: .image, url: url, width: $0.width, height: $0.height, altText: card.imageDescription) }
        }
        return Item.LinkCard(url: card.url, site: site, title: card.title, summary: card.description, image: image)
    }

    /// The link to make a card for when the instance hasn't made one yet
    /// (it builds cards in the background, so a new status often has none):
    /// the status's first web link, on a status with no media.
    static func cardLink(_ post: Mastodon.Status) -> String? {
        guard post.mediaAttachments.isEmpty, post.card == nil else { return nil }
        return MastodonHTML.links(post.content).first
    }

    /// Sides beyond this aren't real image sizes.
    static let largestSide = 100_000.0

    /// A width and height from JSON as whole pixels, or nil for anything
    /// that isn't a sane pixel count (missing, zero, negative, NaN, huge).
    static func pixels(_ width: Double?, _ height: Double?) -> (width: Int, height: Int)? {
        guard let width, let height, (1...largestSide).contains(width), (1...largestSide).contains(height) else { return nil }
        return (Int(width.rounded()), Int(height.rounded()))
    }

    /// The visual attachments, with the size the instance reports (the
    /// original's, else the small preview's, scaled up to its aspect).
    static func unsizedMedia(_ post: Mastodon.Status) -> [UnsizedMedia] {
        post.mediaAttachments.compactMap { attachment in
            let kind: Item.Media.Kind
            switch attachment.type {
            case .image: kind = .image
            case .gifv: kind = .gif
            case .video: kind = .video
            case .audio, .unknown: return nil
            }
            guard let url = attachment.url ?? attachment.previewUrl else { return nil }
            let size = [attachment.meta?.original, attachment.meta?.small].lazy.compactMap { pixels($0?.width, $0?.height) }.first
            return UnsizedMedia(
                kind: kind, url: url,
                previewURL: kind == .image ? nil : attachment.previewUrl,
                width: size?.width, height: size?.height, altText: attachment.description
            )
        }
    }

    /// Fills in what the mapper couldn't: sizes for attachments the
    /// instance sent none for, and a card for a link it hasn't carded yet.
    static func completing(_ item: Item, from status: Mastodon.Status, with resolver: MediaResolver) async -> Item {
        var item = item
        let post = status.reblog ?? status
        let media = unsizedMedia(post)
        if media.contains(where: { $0.sized == nil }) {
            item.media = await resolver.sized(media)
        }
        if item.linkCard == nil, let link = cardLink(post) {
            item.linkCard = await resolver.card(for: link)
        }
        if item.quote != nil, item.quote?.image == nil, let quoted = post.quote?.quotedStatus {
            if let still = quoteImage(quoted) {
                item.quote?.image = await resolver.sized([still]).first
            }
        }
        return item
    }
}
