import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model: things parked on the shelf

struct ShelfItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, link, text }
    var id = UUID()
    let kind: Kind
    let value: String          // file path, URL string, or the text itself
    var added = Date()
    var shot = false           // came from the screenshot catcher

    var url: URL? { kind == .file ? URL(fileURLWithPath: value) : kind == .link ? URL(string: value) : nil }
    var name: String {
        switch kind {
        case .file: return URL(fileURLWithPath: value).lastPathComponent
        case .link: return URL(string: value)?.host ?? value
        case .text: return value.replacingOccurrences(of: "\n", with: " ")
        }
    }
    var isImage: Bool {
        kind == .file && (UTType(filenameExtension: URL(fileURLWithPath: value).pathExtension)?.conforms(to: .image) ?? false)
    }
}

/// The drop shelf: a liquid tab on the right edge that catches drags and screenshots.
@Observable final class Shelf {
    enum Mode: Equatable { case idle, drop, open, shot(UUID) }
    var mode = Mode.idle
    var magnet = 0.0    // 0…1, how close the pointer is
    var pullY = 0.0     // pointer height in the canvas, where the liquid bulges
    var targeted = false
    var items: [ShelfItem] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "shelf") }
    }
    @ObservationIgnored var onShot: ((ShelfItem) -> Void)?
    @ObservationIgnored private var shots: NSMetadataQuery?

    static let canvas = CGSize(width: 340, height: 340)
    static let base: CGFloat = 36       // gap under the tab, inside the window
    static let max = 40
    /// Where dragged-in images without a file (from a browser, say) get saved.
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TopNotch/Shelf")

    /// (protrusion from the edge, height, corner radius, edge flare) for each mode
    var geo: (w: CGFloat, h: CGFloat, r: CGFloat, f: CGFloat) {
        switch mode {
        case .idle: (13 + 10 * magnet, 46 + 18 * magnet, 7, 7)
        case .drop: (targeted ? 150 : 130, targeted ? 150 : 130, 24, 12)
        case .open: (304, 228, 22, 12)
        case .shot: (304, 118, 22, 12)
        }
    }

    init() {
        let saved = UserDefaults.standard.data(forKey: "shelf").flatMap { try? JSONDecoder().decode([ShelfItem].self, from: $0) } ?? []
        items = saved.filter { $0.kind != .file || FileManager.default.fileExists(atPath: $0.value) }   // drop files that are gone
        watchScreenshots()
    }

    func add(_ new: [ShelfItem]) {
        let fresh = new.filter { n in !items.contains { $0.kind == n.kind && $0.value == n.value } }
        items = Array((fresh + items).prefix(Self.max))
    }

    func remove(_ i: ShelfItem) { items.removeAll { $0.id == i.id } }

    /// Image + file on the pasteboard, so it pastes as a picture in chats and as a file in Finder.
    func copy(_ i: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch i.kind {
        case .file:
            var objects: [NSPasteboardWriting] = [URL(fileURLWithPath: i.value) as NSURL]
            if i.isImage, let img = NSImage(contentsOfFile: i.value) { objects.append(img) }
            pb.writeObjects(objects)
        case .link, .text:
            pb.setString(i.value, forType: .string)
        }
    }

    func reveal(_ i: ShelfItem) {
        if i.kind == .file { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.value)]) }
        else if let u = i.url { NSWorkspace.shared.open(u) }
    }

    /// Screenshots go to the Trash (recoverable), not gone for good.
    func trash(_ i: ShelfItem) {
        if i.kind == .file { NSWorkspace.shared.recycle([URL(fileURLWithPath: i.value)]) }
        remove(i)
    }

    func dragProvider(_ i: ShelfItem) -> NSItemProvider {
        switch i.kind {
        case .file: NSItemProvider(object: URL(fileURLWithPath: i.value) as NSURL)   // a plain file URL: what chat apps and Finder accept
        case .link: NSItemProvider(object: (URL(string: i.value) ?? URL(fileURLWithPath: "/")) as NSURL)
        case .text: NSItemProvider(object: i.value as NSString)
        }
    }

    /// Accept files, links, images and text dropped on the tab. Anything that's really a file stays a file,
    /// so it can be sent on: many apps hand over a file's contents as "text" without a file URL.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        func park(_ i: ShelfItem) { DispatchQueue.main.async { withAnimation(spring) { self.add([i]) } } }
        /// copy a file the source only lends us for the duration of the callback
        func keep(_ tmp: URL, name: String?) {
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            var dest = Self.dir.appendingPathComponent(name.map { $0.contains(".") || tmp.pathExtension.isEmpty ? $0 : "\($0).\(tmp.pathExtension)" }
                                                       ?? tmp.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = dest.deletingPathExtension().appendingPathExtension("\(Int(Date().timeIntervalSince1970)).\(dest.pathExtension)")
            }
            if (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil { park(ShelfItem(kind: .file, value: dest.path)) }
        }
        for p in providers {
            let types = p.registeredTypeIdentifiers
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                // Finder hands the file URL over as Data on some macOS versions and as a URL on others
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let u = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let u { park(ShelfItem(kind: .file, value: u.path)) }
                }
            } else if p.suggestedName != nil, let t = types.first(where: { UTType($0)?.conforms(to: .data) == true || UTType($0)?.conforms(to: .content) == true }) {
                // a named file from an editor, Photos, a browser…: keep our own copy
                _ = p.loadFileRepresentation(forTypeIdentifier: t) { tmp, _ in
                    if let tmp { keep(tmp, name: p.suggestedName) }
                }
            } else if let t = types.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                // raw image data with no name: save it under Application Support
                p.loadDataRepresentation(forTypeIdentifier: t) { data, _ in
                    guard let data else { return }
                    try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                    let f = Self.dir.appendingPathComponent("Image \(Int(Date().timeIntervalSince1970)).\(UTType(t)?.preferredFilenameExtension ?? "png")")
                    if (try? data.write(to: f)) != nil { park(ShelfItem(kind: .file, value: f.path)) }
                }
            } else if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    guard let u else { return }
                    park(u.isFileURL ? ShelfItem(kind: .file, value: u.path) : ShelfItem(kind: .link, value: u.absoluteString))
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s, !s.isEmpty else { return }
                    let paths = Self.paths(in: s)
                    if paths.isEmpty { park(ShelfItem(kind: .text, value: s)) }
                    else { paths.forEach { park(ShelfItem(kind: .file, value: $0)) } }
                }
            }
        }
        return !providers.isEmpty
    }

    /// Text that is really file paths (terminals and editors drag paths as text): the existing files, else [].
    static func paths(in s: String) -> [String] {
        let lines = s.split(whereSeparator: \.isNewline).map { l -> String in
            let t = l.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let p = t.hasPrefix("file://") ? URL(string: t)?.path ?? t : (t as NSString).expandingTildeInPath
            return p.replacingOccurrences(of: "\\ ", with: " ")
        }
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }) else { return [] }
        return lines
    }

    /// The system share menu (AirDrop, Messages, Mail, and any app that adds itself), anchored at the pointer.
    static weak var window: NSWindow?
    var sharing = false   // keep the shelf open while the menu is up
    @ObservationIgnored private var pickerDone: PickerDone?

    func share(_ i: ShelfItem) {
        guard let w = Self.window, let v = w.contentView else { return }
        let picker = NSSharingServicePicker(items: [i.url.map { $0 as Any } ?? i.value as NSString])
        pickerDone = PickerDone { [weak self] in self?.sharing = false }
        picker.delegate = pickerDone
        sharing = true
        NSApp.activate(ignoringOtherApps: true)
        let p = v.convert(w.mouseLocationOutsideOfEventStream, from: nil)
        picker.show(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: v, preferredEdge: .minX)
    }

    /// Spotlight tags every screenshot (kMDItemIsScreenCapture), wherever macOS saves them.
    private func watchScreenshots() {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] n in
            let added = n.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            for m in added {
                guard let path = m.value(forAttribute: NSMetadataItemPathKey) as? String,
                      Date().timeIntervalSince((m.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date) ?? .distantPast) < 120
                else { continue }
                let item = ShelfItem(kind: .file, value: path, shot: true)
                withAnimation(spring) { self?.add([item]) }
                self?.onShot?(item)
            }
        }
        q.start()
        shots = q
    }

    /// Images get their own pixels, everything else its Finder icon.
    static func thumb(_ i: ShelfItem) -> NSImage? {
        switch i.kind {
        case .file: i.isImage ? NSImage(contentsOfFile: i.value) : NSWorkspace.shared.icon(forFile: i.value)
        case .link, .text: nil
        }
    }
}

// MARK: - Liquid shape

/// A tab of liquid stuck to the right screen edge: concave flares where it meets the edge, rounded outer
/// corners, and a leading side that ripples at rest and bulges toward a nearby pointer.
struct EdgeBlob: Shape {
    var w: CGFloat, h: CGFloat, r: CGFloat, f: CGFloat, bulge: CGFloat
    var bulgeY: CGFloat, wobble: CGFloat, t: Double

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { .init(.init(w, h), .init(r, .init(f, bulge))) }
        set { (w, h, r, f, bulge) = (newValue.first.first, newValue.first.second, newValue.second.first,
                                     newValue.second.second.first, newValue.second.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        let edge = rect.maxX + 1, bottom = rect.maxY - Shelf.base, top = bottom - h, left = edge - 1 - w
        let r = min(r, w * 0.9, h / 2), f = min(f, max(0, w - r))   // keep the outline from folding back
        var p = Path()
        p.move(to: CGPoint(x: edge, y: top - f))
        p.addQuadCurve(to: CGPoint(x: edge - f, y: top), control: CGPoint(x: edge, y: top))
        p.addLine(to: CGPoint(x: left + r, y: top))
        p.addQuadCurve(to: CGPoint(x: left, y: top + r), control: CGPoint(x: left, y: top))
        let span = max(1, h - 2 * r)
        for y in stride(from: top + r, through: bottom - r, by: 1.5) {
            let k = sin(.pi * (y - top - r) / span)   // 0 at the corners, so they stay attached
            let ripple = wobble * sin(y * 0.16 + t * 2.4) * k
            let pull = bulge * exp(-pow(y - bulgeY, 2) / (2 * 20 * 20)) * k
            p.addLine(to: CGPoint(x: left - ripple - pull, y: y))
        }
        p.addLine(to: CGPoint(x: left, y: bottom - r))
        p.addQuadCurve(to: CGPoint(x: left + r, y: bottom), control: CGPoint(x: left, y: bottom))
        p.addLine(to: CGPoint(x: edge - f, y: bottom))
        p.addQuadCurve(to: CGPoint(x: edge, y: bottom + f), control: CGPoint(x: edge, y: bottom))
        p.closeSubpath()
        return p
    }
}

/// Faint engineering-paper dots, the island's texture.
struct ShelfDots: View {
    var body: some View {
        Canvas { ctx, size in
            for x in stride(from: 7.0, to: size.width, by: 14) {
                for y in stride(from: 7.0, to: size.height, by: 14) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)), with: .color(.white.opacity(0.08)))
                }
            }
        }
        .frame(width: Shelf.canvas.width, height: Shelf.canvas.height)
        .drawingGroup()
    }
}

// MARK: - Views

struct ShelfView: View {
    let shelf: Shelf

    var body: some View {
        let g = shelf.geo, idle = shelf.mode == .idle
        let c = Shelf.canvas, bottom = c.height - Shelf.base
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: !idle)) { tl in
                let blob = EdgeBlob(w: g.w, h: g.h, r: g.r, f: g.f, bulge: idle ? 14 * shelf.magnet : 0, bulgeY: shelf.pullY,
                                    wobble: idle ? 1.4 : 0, t: tl.date.timeIntervalSinceReferenceDate)
                ZStack {
                    Color.black
                    Group {
                        LinearGradient(colors: [.panel, .black], startPoint: .leading, endPoint: .trailing)
                        RadialGradient(colors: [Color.ice.opacity(shelf.targeted ? 0.45 : 0.28), .clear], center: UnitPoint(x: 0.4, y: 1.05),
                                       startRadius: 0, endRadius: 260)
                        ShelfDots()
                    }
                    .opacity(idle ? 0 : 1)
                }
                .clipShape(blob)
                .overlay(blob.stroke(LinearGradient(colors: [Color.ice.opacity(idle ? 0.2 + 0.5 * shelf.magnet : 0.55), .clear],
                                                    startPoint: .leading, endPoint: .trailing), lineWidth: 1))
                .shadow(color: .ice.opacity(idle ? 0.35 * shelf.magnet : 0.25), radius: 22)
                .shadow(color: .black.opacity(0.5), radius: 12, x: -3)
            }

            if idle, !shelf.items.isEmpty {   // something's parked here
                Text("\(shelf.items.count)").font(mono(9, .heavy)).foregroundStyle(.black)
                    .frame(minWidth: 15, minHeight: 15).padding(.horizontal, 2)
                    .background(Color.ice, in: Capsule())
                    .shadow(color: .ice.opacity(0.7), radius: 5)
                    .position(x: c.width - g.w - 4, y: bottom - g.h / 2)
                    .transition(.scale.combined(with: .opacity))
            }

            Group {
                switch shelf.mode {
                case .idle: EmptyView()
                case .drop: drop
                case .open: list
                case let .shot(id): if let i = shelf.items.first(where: { $0.id == id }) { ShotCard(i: i, shelf: shelf) }
                }
            }
            .frame(width: g.w - 30, height: g.h, alignment: .topLeading)
            .position(x: c.width - g.w / 2 - 6, y: bottom - g.h / 2)
            .transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.12)))
        }
        .frame(width: c.width, height: c.height)
        .foregroundStyle(Color.fg)
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: Binding(get: { shelf.targeted }, set: { t in
            withAnimation(spring) { shelf.targeted = t }
        })) { providers in
            let ok = shelf.accept(providers)
            withAnimation(spring) { shelf.mode = .open }
            return ok
        }
        .animation(spring, value: shelf.mode)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: shelf.magnet)
        .animation(spring, value: shelf.targeted)
    }

    var drop: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(Color.ice)
                .symbolEffect(.bounce, value: shelf.targeted)
                .shadow(color: .ice.opacity(0.7), radius: 10)
            Caps(text: shelf.targeted ? "let go" : "drop to shelf", color: .ice)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.ice.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .padding(.vertical, 12).padding(.leading, 6)
    }

    var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ice)
                Text("Shelf").font(sans(13, .semibold))
                Caps(text: "\(shelf.items.count) · drag out anywhere")
                Spacer()
                if !shelf.items.isEmpty {
                    Button { withAnimation(spring) { shelf.items.removeAll() } } label: { Pill(icon: "xmark", text: "clear", color: .fg3) }
                        .buttonStyle(Press())
                        .help("empty the shelf (files stay where they are)")
                }
            }
            if shelf.items.isEmpty {
                Empty(icon: "tray", title: "Drag anything here", sub: "files · images · links · screenshots")
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 8), count: 4), spacing: 8) {
                        ForEach(shelf.items) { ShelfTile(i: $0, shelf: shelf) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.leading, 14).padding(.top, 14)
    }
}

/// One parked thing: thumbnail you can drag out, with quick actions on hover.
struct ShelfTile: View {
    let i: ShelfItem, shelf: Shelf
    @State private var hover = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.05))
                if let img = Shelf.thumb(i) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: i.isImage ? .fill : .fit)
                        .padding(i.isImage ? 0 : 8)
                } else {
                    Image(systemName: i.kind == .link ? "link" : "text.alignleft")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.ice)
                }
                if hover {
                    HStack(spacing: 3) {
                        mini("doc.on.doc", "copy") { shelf.copy(i) }
                        mini("square.and.arrow.up", "share") { shelf.share(i) }
                        mini("magnifyingglass", i.kind == .file ? "show in Finder" : "open") { shelf.reveal(i) }
                        mini("xmark", "remove from shelf") { withAnimation(spring) { shelf.remove(i) } }
                    }
                    .padding(3)
                    .background(.black.opacity(0.75), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 3)
                    .transition(.opacity)
                }
            }
            .frame(width: 62, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.ice.opacity(hover ? 0.5 : 0.12), lineWidth: 0.6))
            Text(i.name).font(sans(9)).foregroundStyle(Color.fg2).lineLimit(1).frame(width: 62)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onDrag { shelf.dragProvider(i) }
        .help(i.kind == .text ? i.value : i.name)
    }

    func mini(_ icon: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(.white).frame(width: 12, height: 12)
        }
        .buttonStyle(Press())
        .help(tip)
    }
}

/// The screenshot that just landed: drag it straight into a chat, copy it, or bin it.
struct ShotCard: View {
    let i: ShelfItem, shelf: Shelf
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = NSImage(contentsOfFile: i.value) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.06)
                }
            }
            .frame(width: 100, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.ice.opacity(0.4), lineWidth: 0.6))
            .shadow(color: .ice.opacity(0.3), radius: 8)
            .onDrag { shelf.dragProvider(i) }
            .help("drag into any app")

            VStack(alignment: .leading, spacing: 5) {
                Caps(text: "screenshot", color: .ice)
                Text(copied ? "Copied" : "Drag it anywhere").font(sans(13, .bold)).foregroundStyle(copied ? Color.neon : .white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Button {
                        shelf.copy(i)
                        withAnimation(spring) { copied = true }
                    } label: { Pill(icon: "doc.on.doc", text: "copy", color: .ice) }
                    Button { shelf.share(i) } label: { Pill(icon: "square.and.arrow.up", text: "", color: .ice) }
                        .help("share: AirDrop, Messages, Mail…")
                    Button { withAnimation(spring) { shelf.trash(i); shelf.mode = .idle } } label: { Pill(icon: "trash", text: "delete", color: .hot) }
                        .help("move the screenshot to the Trash")
                }
                .buttonStyle(Press())
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .padding(.leading, 14)
    }
}

/// Tells the shelf the share menu is gone (a service was picked, or it was dismissed).
final class PickerDone: NSObject, NSSharingServicePickerDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func sharingServicePicker(_ p: NSSharingServicePicker, didChoose s: NSSharingService?) { done() }
}
