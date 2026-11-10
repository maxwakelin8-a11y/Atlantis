import Foundation

/// Reading and drawing on `.excalidraw` boards without a web view, for agents (MCP tools).
///
/// Agents describe what to draw in a small format (boxes, ellipses, diamonds, text, arrows that
/// connect ids). This turns it into real Excalidraw elements: labels bound to their shapes,
/// arrows bound to both ends. Text is sized roughly here and marked `customData.atlantisLayout`;
/// the whiteboard page measures it in Excalidraw's own font the next time the board is open
/// (web/whiteboard/src/scene.ts). Agents only ever add: nothing already on a board is moved or
/// deleted (an arrow attached to an existing shape adds itself to that shape's `boundElements`).
public enum WhiteboardScene {
    public static let emptyBoard = """
    {
      "type": "excalidraw",
      "version": 2,
      "source": "https://excalidraw.com",
      "elements": [],
      "appState": {
        "gridSize": 20,
        "viewBackgroundColor": "#ffffff"
      },
      "files": {}
    }

    """

    public static let layoutMark = "atlantisLayout"
    public static let maxElementsPerDraw = 300

    /// Parses a board. Empty text is an empty board.
    public static func parse(_ text: String?) throws -> JSONValue {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try JSONValue.parse(Data(emptyBoard.utf8))
        }
        guard let board = try? JSONValue.parse(Data(text.utf8)), board.objectValue != nil else {
            throw WhiteboardFiles.Failure.notABoard
        }
        if let type = board["type"]?.stringValue, type != "excalidraw" { throw WhiteboardFiles.Failure.notABoard }
        return board
    }

    /// Board JSON as Excalidraw writes it (2-space indent), keys sorted.
    public static func encode(_ board: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(board)) ?? Data(emptyBoard.utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func liveElements(_ board: JSONValue) -> [JSONValue] {
        (board["elements"]?.arrayValue ?? []).filter { $0["isDeleted"]?.boolValue != true }
    }

    // MARK: Summary (atlantis_whiteboard_read)

    /// What's on a board, compactly: one entry per shape, text or arrow, with labels folded into
    /// their shape and arrows showing what they connect.
    public static func summary(_ board: JSONValue, limit: Int = 500) -> JSONValue {
        let live = liveElements(board)
        var labels: [String: String] = [:]
        for el in live where el["type"]?.stringValue == "text" {
            if let container = el["containerId"]?.stringValue, let text = el["text"]?.stringValue {
                labels[container] = text
            }
        }
        var items: [JSONValue] = []
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for el in live {
            guard let type = el["type"]?.stringValue, let id = el["id"]?.stringValue else { continue }
            let x = el["x"]?.doubleValue ?? 0, y = el["y"]?.doubleValue ?? 0
            let w = el["width"]?.doubleValue ?? 0, h = el["height"]?.doubleValue ?? 0
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x + w); maxY = max(maxY, y + h)
            if type == "text", el["containerId"]?.stringValue != nil { continue }
            guard items.count < limit else { continue }
            var item: [String: JSONValue?] = [
                "id": .string(id), "type": .string(type),
                "x": .int(Int(x.rounded())), "y": .int(Int(y.rounded())),
                "width": .int(Int(w.rounded())), "height": .int(Int(h.rounded())),
            ]
            if type == "text" { item["text"] = .str(el["text"]?.stringValue.map { Clip.text($0, 500) }) }
            if let label = labels[id] { item["label"] = .string(Clip.text(label, 500)) }
            if type == "arrow" || type == "line" {
                item["from"] = .str(el["startBinding"]?["elementId"]?.stringValue)
                item["to"] = .str(el["endBinding"]?["elementId"]?.stringValue)
            }
            if type == "frame" { item["name"] = .str(el["name"]?.stringValue) }
            if let stroke = el["strokeColor"]?.stringValue, stroke != Palette.defaultStroke { item["strokeColor"] = .string(stroke) }
            if let fill = el["backgroundColor"]?.stringValue, fill != "transparent" { item["backgroundColor"] = .string(fill) }
            if let link = el["link"]?.stringValue { item["link"] = .string(Clip.text(link, 300)) }
            items.append(.make(item))
        }
        var out: [String: JSONValue?] = [
            "elements": .array(items), "count": .int(items.count),
            "truncated": items.count < live.count(where: { $0["type"]?.stringValue != "text" || $0["containerId"]?.stringValue == nil }) ? .bool(true) : nil,
            "background": .str(board["appState"]?["viewBackgroundColor"]?.stringValue),
        ]
        if minX.isFinite {
            out["bounds"] = .make(["x": .int(Int(minX.rounded())), "y": .int(Int(minY.rounded())),
                                   "width": .int(Int((maxX - minX).rounded())), "height": .int(Int((maxY - minY).rounded()))])
        }
        return .make(out)
    }

    // MARK: Colours

    enum Palette {
        static let defaultStroke = "#1e1e1e"
        /// Excalidraw's own palette: dark shades for lines and text, light ones for fills.
        static let stroke: [String: String] = [
            "black": "#1e1e1e", "gray": "#868e96", "grey": "#868e96", "red": "#e03131", "pink": "#c2255c",
            "grape": "#9c36b5", "violet": "#6741d9", "purple": "#6741d9", "blue": "#1971c2", "cyan": "#0c8599",
            "teal": "#099268", "green": "#2f9e44", "yellow": "#f08c00", "orange": "#e8590c", "white": "#ffffff",
        ]
        static let fill: [String: String] = [
            "black": "#343a40", "gray": "#e9ecef", "grey": "#e9ecef", "red": "#ffc9c9", "pink": "#fcc2d7",
            "grape": "#eebefa", "violet": "#d0bfff", "purple": "#d0bfff", "blue": "#a5d8ff", "cyan": "#99e9f2",
            "teal": "#96f2d7", "green": "#b2f2bb", "yellow": "#ffec99", "orange": "#ffd8a8", "white": "#ffffff",
        ]

        static func color(_ raw: String?, fill: Bool, key: String) throws -> String? {
            guard let raw else { return nil }
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if value == "transparent" || value == "none" { return "transparent" }
            if let named = (fill ? Self.fill : Self.stroke)[value] { return named }
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else {
                throw ToolFailure("\"\(key)\" must be a colour name (red, blue, green, …), #rrggbb or transparent.")
            }
            return "#" + hex
        }
    }
}

/// One `atlantis_whiteboard_draw` request: which board, and what to add.
public struct WhiteboardDraw: Sendable, Equatable {
    public enum Position: String, Sendable { case auto, absolute }

    public var path: String
    /// The element specs as the agent sent them (validated on every apply).
    public var elements: [JSONValue]
    public var position: Position

    static let maxSpecJSON = 55_000

    public init(arguments args: JSONValue) throws {
        do { path = try WhiteboardFiles.validate(try args.requireString("board", maxLength: 300), addExtension: true) }
        catch let failure as WhiteboardFiles.Failure { throw ToolFailure(failure.errorDescription ?? "Bad board path.") }
        guard let list = args["elements"]?.arrayValue, !list.isEmpty else {
            throw ToolFailure("Missing required argument \"elements\" (a non-empty array of shapes, text and arrows).")
        }
        guard list.count <= WhiteboardScene.maxElementsPerDraw else {
            throw ToolFailure("Too many elements (max \(WhiteboardScene.maxElementsPerDraw) per call). Split the drawing into several calls.")
        }
        elements = list
        position = try args.optionalChoice("position", ["auto", "absolute"]).flatMap(Position.init(rawValue:)) ?? .auto
        guard JSONValue.array(list).encoded().count <= Self.maxSpecJSON else {
            throw ToolFailure("The drawing is too big for one call. Split it into several calls.")
        }
        // Check every spec now (ids that may already be on the board aside), so a bad request
        // fails before it reaches the Inbox. `check(against:)` then checks it with the board.
        _ = try WhiteboardBuilder(specs: list, board: try WhiteboardScene.parse(nil), position: position, knownRefsOnly: false).build()
    }

    /// Fails if the drawing can't go on the board as it is now (e.g. an arrow to an id that isn't there).
    public func check(against files: WhiteboardFiles) throws {
        let current = files.exists(path) ? try files.read(path) : nil
        _ = try apply(to: current)
    }

    /// From an Inbox `whiteboard.draw` line.
    public init(item: InboxItem) throws {
        guard let raw = item.field("board") else { throw ToolFailure("This proposal has no board.") }
        path = try WhiteboardFiles.validate(raw, addExtension: true)
        guard let encoded = item.field("elements"),
              let list = try? JSONValue.parse(Data(InboxText.decode(encoded).utf8)).arrayValue else {
            throw ToolFailure("This proposal has no drawing.")
        }
        elements = list
        position = item.field("position").flatMap(Position.init(rawValue:)) ?? .auto
    }

    public var inboxFields: [InboxItem.Field] {
        [.init(key: "board", value: path), .init(key: "position", value: position.rawValue),
         .init(key: "elements", value: InboxText.encode(String(decoding: JSONValue.array(elements).encoded(), as: UTF8.self)))]
    }

    public func summary(creating: Bool) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let what = elements.count == 1 ? "1 element" : "\(elements.count) elements"
        return Clip.text(creating ? "New board \"\(name)\" with \(what)" : "Draw \(what) on \"\(name)\"", 200)
    }

    /// Adds the drawing to the board's current text (nil: a new board). Returns the new text and
    /// the ids of what was added.
    public func apply(to current: String?, now: Date = Date()) throws -> (text: String, ids: [String]) {
        let board: JSONValue
        do { board = try WhiteboardScene.parse(current) } catch { throw ToolFailure("That file isn't an Excalidraw board.") }
        let built = try WhiteboardBuilder(specs: elements, board: board, position: position, now: now).build()
        return (WhiteboardScene.encode(built.board), built.ids)
    }

    /// Draws on the board in the folder (creating it if needed). Returns the ids added.
    public func apply(in files: WhiteboardFiles) throws -> [String] {
        var ids: [String] = []
        do {
            try files.update(path) { current in
                let result = try apply(to: current)
                ids = result.ids
                return result.text
            }
        } catch let failure as WhiteboardFiles.Failure {
            throw ToolFailure(failure.errorDescription ?? "That board can't be changed.")
        }
        return ids
    }
}

/// Builds Excalidraw elements from agent specs. See `WhiteboardTools` for the spec format.
struct WhiteboardBuilder {
    let specs: [JSONValue]
    var board: JSONValue
    let position: WhiteboardDraw.Position
    var now: Date = Date()
    /// false: an arrow may name an id that isn't known (checked again later against the real board).
    var knownRefsOnly = true

    private struct Spec {
        enum Kind: String { case rectangle, ellipse, diamond, text, arrow, line }
        var kind: Kind
        var id: String
        var x: Double?, y: Double?, width: Double?, height: Double?
        var text: String?
        var from: String?, to: String?
        var points: [[Double]]?
        var stroke: String?, fill: String?
        var fillStyle: String, strokeStyle: String, strokeWidth: Double
        var fontSize: Double
        var startArrowhead: JSONValue, endArrowhead: JSONValue
    }

    struct Box {
        var type: String
        var x: Double, y: Double, width: Double, height: Double
        var center: (Double, Double) { (x + width / 2, y + height / 2) }
    }

    init(specs: [JSONValue], board: JSONValue, position: WhiteboardDraw.Position, now: Date = Date(), knownRefsOnly: Bool = true) {
        self.specs = specs
        self.board = board
        self.position = position
        self.now = now
        self.knownRefsOnly = knownRefsOnly
    }

    // MARK: Build

    func build() throws -> (board: JSONValue, ids: [String]) {
        var allElements = board["elements"]?.arrayValue ?? []
        let existing = WhiteboardScene.liveElements(board)
        var takenIds = Set(allElements.compactMap { $0["id"]?.stringValue })
        var existingBoxes: [String: Box] = [:]
        for el in existing {
            guard let id = el["id"]?.stringValue, let type = el["type"]?.stringValue,
                  ["rectangle", "ellipse", "diamond", "text", "image", "frame"].contains(type) else { continue }
            existingBoxes[id] = Box(type: type, x: el["x"]?.doubleValue ?? 0, y: el["y"]?.doubleValue ?? 0,
                                    width: el["width"]?.doubleValue ?? 0, height: el["height"]?.doubleValue ?? 0)
        }

        // 1. Parse and give every spec an id.
        var parsed: [Spec] = []
        for (index, raw) in specs.enumerated() {
            parsed.append(try parse(raw, index: index, taken: &takenIds))
        }
        let batchIds = Set(parsed.map(\.id))

        // 2. Sizes and positions of shapes and text.
        var boxes: [String: Box] = [:]
        for spec in parsed where spec.kind != .arrow && spec.kind != .line {
            boxes[spec.id] = try box(for: spec)
        }

        // 3. "auto": a new drawing goes to the right of what's there, unless it connects to existing shapes.
        let connectsToExisting = parsed.contains { spec in
            [spec.from, spec.to].contains { ref in ref.map { !batchIds.contains($0) } ?? false }
        }
        var dx = 0.0, dy = 0.0
        if position == .auto, !existing.isEmpty, !connectsToExisting {
            let ownBoxes = Array(boxes.values) + parsed.compactMap(freeLineBox)
            if let minX = ownBoxes.map(\.x).min(), let minY = ownBoxes.map(\.y).min() {
                let right = existing.map { ($0["x"]?.doubleValue ?? 0) + max(0, $0["width"]?.doubleValue ?? 0) }.max() ?? 0
                let top = existing.map { $0["y"]?.doubleValue ?? 0 }.min() ?? 0
                dx = right + 120 - minX
                dy = top - minY
            }
        }
        for id in boxes.keys {
            boxes[id]!.x += dx
            boxes[id]!.y += dy
        }

        // 4. Elements.
        var added: [JSONValue] = []
        var bound: [String: [JSONValue]] = [:] // shape id → arrows/labels bound to it
        for spec in parsed {
            switch spec.kind {
            case .rectangle, .ellipse, .diamond:
                let box = boxes[spec.id]!
                var el = base(spec, type: spec.kind.rawValue, x: box.x, y: box.y, width: box.width, height: box.height)
                el["roundness"] = spec.kind == .ellipse ? .null : .make(["type": .int(spec.kind == .rectangle ? 3 : 2)])
                if let label = spec.text {
                    let textId = freshId(&takenIds)
                    bound[spec.id, default: []].append(.make(["id": .string(textId), "type": "text"]))
                    added.append(.object(textElement(id: textId, text: label, spec: spec, center: box.center, containerId: spec.id)))
                }
                added.insert(.object(el), at: added.count - (spec.text == nil ? 0 : 1))
            case .text:
                let box = boxes[spec.id]!
                var el = textElement(id: spec.id, text: spec.text ?? "", spec: spec, center: box.center, containerId: nil)
                el["x"] = .double(box.x)
                el["y"] = .double(box.y)
                el["textAlign"] = "left"
                el["verticalAlign"] = "top"
                added.append(.object(el))
            case .arrow, .line:
                let (start, end, mids) = try endpoints(spec, boxes: boxes, existing: existingBoxes, offset: (dx, dy))
                let pts = [start] + mids + [end]
                let local = pts.map { [$0.0 - start.0, $0.1 - start.1] }
                let xs = local.map { $0[0] }, ys = local.map { $0[1] }
                var el = base(spec, type: spec.kind.rawValue, x: start.0, y: start.1,
                              width: (xs.max()! - xs.min()!), height: (ys.max()! - ys.min()!))
                el["roundness"] = .make(["type": .int(2)])
                el["points"] = .array(local.map { .array([.double($0[0]), .double($0[1])]) })
                el["lastCommittedPoint"] = .null
                el["startArrowhead"] = spec.startArrowhead
                el["endArrowhead"] = spec.endArrowhead
                el["startBinding"] = spec.from.map { .make(["elementId": .string($0), "focus": .int(0), "gap": .int(4)]) } ?? .null
                el["endBinding"] = spec.to.map { .make(["elementId": .string($0), "focus": .int(0), "gap": .int(4)]) } ?? .null
                if spec.kind == .arrow { el["elbowed"] = false }
                for ref in [spec.from, spec.to].compactMap({ $0 }) {
                    bound[ref, default: []].append(.make(["id": .string(spec.id), "type": "arrow"]))
                }
                if let label = spec.text {
                    let textId = freshId(&takenIds)
                    bound[spec.id, default: []].append(.make(["id": .string(textId), "type": "text"]))
                    added.append(.object(el))
                    let mid = midpoint(pts)
                    added.append(.object(textElement(id: textId, text: label, spec: spec, center: mid, containerId: spec.id)))
                } else {
                    added.append(.object(el))
                }
            }
        }

        // 5. Bindings: new elements get their boundElements; existing shapes an arrow attaches to
        //    get the arrow added (and a new version, so Excalidraw sees the change).
        added = added.map { el in
            guard case .object(var o) = el, let id = o["id"]?.stringValue, let refs = bound[id] else { return el }
            o["boundElements"] = .array((o["boundElements"]?.arrayValue ?? []) + refs)
            return .object(o)
        }
        allElements = allElements.map { el in
            guard case .object(var o) = el, let id = o["id"]?.stringValue, let refs = bound[id], !batchIds.contains(id) else { return el }
            o["boundElements"] = .array((o["boundElements"]?.arrayValue ?? []) + refs)
            o["version"] = .int((o["version"]?.intValue ?? 1) + 1)
            o["versionNonce"] = .int(Self.random())
            o["updated"] = .int(millis)
            return .object(o)
        }

        var next = board.objectValue ?? [:]
        next["elements"] = .array(allElements + added)
        if next["type"] == nil { next["type"] = "excalidraw" }
        if next["version"] == nil { next["version"] = 2 }
        return (.object(next), parsed.map(\.id))
    }

    // MARK: Spec parsing

    private func parse(_ raw: JSONValue, index: Int, taken: inout Set<String>) throws -> Spec {
        let at = "elements[\(index)]"
        guard raw.objectValue != nil else { throw ToolFailure("\(at) must be an object.") }
        guard let kindText = raw["type"]?.stringValue?.lowercased(), let kind = Spec.Kind(rawValue: kindText == "box" ? "rectangle" : kindText) else {
            throw ToolFailure("\(at).type must be rectangle, ellipse, diamond, text, arrow or line.")
        }
        func number(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
            guard let value = raw[key], !value.isNull else { return nil }
            guard let n = value.doubleValue, n.isFinite, range.contains(n) else {
                throw ToolFailure("\(at).\(key) must be a number between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
            }
            return n
        }
        func string(_ key: String, _ max: Int) throws -> String? {
            guard let value = raw[key], !value.isNull else { return nil }
            guard let text = value.stringValue else { throw ToolFailure("\(at).\(key) must be a string.") }
            guard text.count <= max else { throw ToolFailure("\(at).\(key) is too long (max \(max) characters).") }
            return text
        }
        func ref(_ key: String) throws -> String? {
            guard let id = try string(key, 60) else { return nil }
            guard Self.validId(id) else { throw ToolFailure("\(at).\(key) must be an element id (letters, digits, - and _).") }
            return id
        }
        func arrowhead(_ key: String, default value: JSONValue) throws -> JSONValue {
            guard let raw = raw[key] else { return value }
            if raw.isNull { return .null }
            guard let name = raw.stringValue?.lowercased() else { throw ToolFailure("\(at).\(key) must be a string or null.") }
            if name == "none" { return .null }
            guard ["arrow", "triangle", "dot", "bar", "circle", "diamond"].contains(name) else {
                throw ToolFailure("\(at).\(key) must be arrow, triangle, dot, bar, circle, diamond or none.")
            }
            return .string(name)
        }

        var id: String
        if let wanted = try string("id", 60) {
            guard Self.validId(wanted) else { throw ToolFailure("\(at).id may only use letters, digits, - and _.") }
            guard !taken.contains(wanted) else { throw ToolFailure("\(at).id \"\(wanted)\" is already used on this board. Pick another id.") }
            id = wanted
            taken.insert(id)
        } else {
            id = freshId(&taken)
        }

        let limit = 1_000_000.0
        var points: [[Double]]?
        if let list = raw["points"], !list.isNull {
            guard let array = list.arrayValue, (2...100).contains(array.count) else {
                throw ToolFailure("\(at).points must be 2 to 100 [x, y] pairs.")
            }
            points = try array.map { pair in
                guard let p = pair.arrayValue, p.count == 2, let px = p[0].doubleValue, let py = p[1].doubleValue,
                      px.isFinite, py.isFinite, abs(px) <= limit, abs(py) <= limit else {
                    throw ToolFailure("\(at).points must be [x, y] number pairs.")
                }
                return [px, py]
            }
        }

        var text = try string(kind == .text ? "text" : "label", 2_000)
        if text == nil, kind != .text { text = try string("text", 2_000) }
        let spec = Spec(
            kind: kind, id: id,
            x: try number("x", -limit...limit), y: try number("y", -limit...limit),
            width: try number("width", 1...20_000), height: try number("height", 1...20_000),
            text: text.flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "\r\n", with: "\n") },
            from: try ref("from"), to: try ref("to"), points: points,
            stroke: try WhiteboardScene.Palette.color(try string("strokeColor", 20), fill: false, key: "\(at).strokeColor"),
            fill: try WhiteboardScene.Palette.color(try string("backgroundColor", 20), fill: true, key: "\(at).backgroundColor"),
            fillStyle: try choice(raw, "fillStyle", ["solid", "hachure", "cross-hatch", "zigzag"], at) ?? "solid",
            strokeStyle: try choice(raw, "strokeStyle", ["solid", "dashed", "dotted"], at) ?? "solid",
            strokeWidth: try number("strokeWidth", 0.5...16) ?? 2,
            fontSize: try number("fontSize", 8...200) ?? 20,
            startArrowhead: try arrowhead("startArrowhead", default: .null),
            endArrowhead: try arrowhead("endArrowhead", default: kind == .arrow ? "arrow" : .null))

        switch kind {
        case .text:
            guard spec.text != nil else { throw ToolFailure("\(at) is text, so it needs \"text\".") }
            fallthrough
        case .rectangle, .ellipse, .diamond:
            guard spec.x != nil, spec.y != nil else { throw ToolFailure("\(at) needs \"x\" and \"y\" (its top-left corner).") }
        case .arrow, .line:
            let ends = spec.from != nil && spec.to != nil
            guard ends || (spec.x != nil && spec.y != nil && spec.points != nil) || (spec.from != nil || spec.to != nil) && spec.points != nil else {
                throw ToolFailure("\(at) needs \"from\" and \"to\" (ids of shapes to connect), or \"x\", \"y\" and \"points\".")
            }
        }
        return spec
    }

    private func choice(_ raw: JSONValue, _ key: String, _ options: [String], _ at: String) throws -> String? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let text = value.stringValue?.lowercased(), options.contains(text) else {
            throw ToolFailure("\(at).\(key) must be one of: \(options.joined(separator: ", ")).")
        }
        return text
    }

    // MARK: Geometry

    /// Rough text size in Excalifont: Swift can't measure it, the page re-measures (layoutMark).
    static func textSize(_ text: String, fontSize: Double) -> (width: Double, height: Double) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let widest = lines.map { line in
            line.unicodeScalars.reduce(0.0) { sum, scalar in sum + (scalar.value > 0x2E80 ? 1.0 : 0.56) }
        }.max() ?? 0
        return ((widest * fontSize).rounded(.up), (Double(lines.count) * fontSize * 1.25).rounded(.up))
    }

    private func box(for spec: Spec) throws -> Box {
        let x = spec.x ?? 0, y = spec.y ?? 0
        if spec.kind == .text {
            let size = Self.textSize(spec.text ?? "", fontSize: spec.fontSize)
            return Box(type: "text", x: x, y: y, width: size.width, height: size.height)
        }
        // Big enough for the label: diamonds and ellipses need more room around text.
        let label = spec.text.map { Self.textSize($0, fontSize: spec.fontSize) } ?? (width: 0, height: 0)
        let grow = spec.kind == .rectangle ? 1.0 : 1.5
        let width = spec.width ?? max(160, (label.width * grow + 40).rounded(.up))
        let height = spec.height ?? max(80, (label.height * grow + 40).rounded(.up))
        return Box(type: spec.kind.rawValue, x: x, y: y, width: width, height: height)
    }

    /// A free arrow's extent (for "auto" placement).
    private func freeLineBox(_ spec: Spec) -> Box? {
        guard spec.kind == .arrow || spec.kind == .line, spec.from == nil, spec.to == nil,
              let x = spec.x, let y = spec.y, let points = spec.points else { return nil }
        return Box(type: "line", x: x + (points.map { $0[0] }.min() ?? 0), y: y + (points.map { $0[1] }.min() ?? 0), width: 0, height: 0)
    }

    private func endpoints(_ spec: Spec, boxes: [String: Box], existing: [String: Box], offset: (Double, Double))
        throws -> ((Double, Double), (Double, Double), [(Double, Double)]) {
        func target(_ id: String) throws -> Box {
            if let box = boxes[id] ?? existing[id] { return box }
            if !knownRefsOnly { return Box(type: "rectangle", x: 0, y: 0, width: 1, height: 1) }
            throw ToolFailure("No shape with id \"\(id)\" to connect to (on the board or earlier in this call).")
        }
        let base = (spec.x.map { $0 + offset.0 } ?? 0, spec.y.map { $0 + offset.1 } ?? 0)
        let pts = (spec.points ?? []).map { (base.0 + $0[0], base.1 + $0[1]) }
        let mids = pts.count > 2 ? Array(pts.dropFirst().dropLast()) : []
        let from = try spec.from.map(target)
        let to = try spec.to.map(target)
        let aimFromStart = mids.first ?? to?.center ?? pts.last ?? base
        let aimFromEnd = mids.last ?? from?.center ?? pts.first ?? base
        let start = from.map { Self.edge(of: $0, toward: aimFromStart, gap: 4) } ?? pts.first ?? base
        let end = to.map { Self.edge(of: $0, toward: aimFromEnd, gap: 4) } ?? pts.last ?? base
        return (start, end, mids)
    }

    /// Where a line from the shape's centre toward `point` leaves the shape, plus a small gap.
    static func edge(of box: Box, toward point: (Double, Double), gap: Double) -> (Double, Double) {
        let (cx, cy) = box.center
        let dx = point.0 - cx, dy = point.1 - cy
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.001 else { return (cx, cy) }
        let hw = max(box.width / 2, 0.5), hh = max(box.height / 2, 0.5)
        let scale: Double = switch box.type {
        case "ellipse": 1 / ((dx / hw) * (dx / hw) + (dy / hh) * (dy / hh)).squareRoot()
        case "diamond": 1 / (abs(dx) / hw + abs(dy) / hh)
        default: min(abs(dx) > 0 ? hw / abs(dx) : .infinity, abs(dy) > 0 ? hh / abs(dy) : .infinity)
        }
        let k = min(scale, 1) + gap / length
        return (cx + dx * k, cy + dy * k)
    }

    private func midpoint(_ pts: [(Double, Double)]) -> (Double, Double) {
        if pts.count % 2 == 1 { return pts[pts.count / 2] }
        let a = pts[pts.count / 2 - 1], b = pts[pts.count / 2]
        return ((a.0 + b.0) / 2, (a.1 + b.1) / 2)
    }

    // MARK: Elements

    private var millis: Int { Int(now.timeIntervalSince1970 * 1000) }

    private func base(_ spec: Spec, type: String, x: Double, y: Double, width: Double, height: Double) -> [String: JSONValue] {
        [
            "id": .string(spec.id), "type": .string(type),
            "x": .double(x), "y": .double(y), "width": .double(width), "height": .double(height), "angle": 0,
            "strokeColor": .string(spec.stroke ?? WhiteboardScene.Palette.defaultStroke),
            "backgroundColor": .string(spec.fill ?? "transparent"),
            "fillStyle": .string(spec.fillStyle), "strokeWidth": .double(spec.strokeWidth),
            "strokeStyle": .string(spec.strokeStyle), "roughness": 1, "opacity": 100,
            "groupIds": [], "frameId": .null, "index": .null, "roundness": .null,
            "seed": .int(Self.random()), "version": 1, "versionNonce": .int(Self.random()),
            "isDeleted": false, "boundElements": .array([]), "updated": .int(millis),
            "link": .null, "locked": false,
            "customData": .make([WhiteboardScene.layoutMark: .bool(true)]),
        ]
    }

    private func textElement(id: String, text: String, spec: Spec, center: (Double, Double), containerId: String?) -> [String: JSONValue] {
        let size = Self.textSize(text, fontSize: spec.fontSize)
        var el = base(spec, type: "text", x: center.0 - size.width / 2, y: center.1 - size.height / 2,
                      width: size.width, height: size.height)
        el["id"] = .string(id)
        el["backgroundColor"] = "transparent"
        el["strokeWidth"] = 2
        el["strokeStyle"] = "solid"
        el["boundElements"] = .null
        el["text"] = .string(text)
        el["originalText"] = .string(text)
        el["fontSize"] = .double(spec.fontSize)
        el["fontFamily"] = 5 // Excalifont, Excalidraw's default hand-drawn font
        el["textAlign"] = "center"
        el["verticalAlign"] = "middle"
        el["containerId"] = containerId.map(JSONValue.string) ?? .null
        el["autoResize"] = true
        el["lineHeight"] = 1.25
        return el
    }

    static func validId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 60 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    private func freshId(_ taken: inout Set<String>) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        while true {
            let id = String((0..<20).map { _ in alphabet.randomElement()! })
            if taken.insert(id).inserted { return id }
        }
    }

    static func random() -> Int { Int.random(in: 1..<Int(Int32.max)) }
}
