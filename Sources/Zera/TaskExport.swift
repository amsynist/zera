import AppKit

// MARK: - Exporting tasks
//
// One row per task per day it was worked on (or finished, or added):
//
//   Date        #  Project  Task                 Status  Minutes  Estimate
//   2026-10-07  1  Zera     Ship the Tasks menu  Open    24       45
//
// as Excel (.xlsx), CSV, a tab-separated table on the clipboard for Google Sheets, or text:
//
//   Wed, 7 Oct 2026
//     1. Ship the Tasks menu [Zera] · 24m
//     2. Fix ⌘K arrow keys [Zera] ✓ 18m

enum TaskExport {
    enum Span: Int, CaseIterable {
        case today, week, month, lastMonth, all
        var title: String {
            switch self {
            case .today: return "Today"
            case .week: return "Last 7 days"
            case .month: return "This month"
            case .lastMonth: return "Last month"
            case .all: return "Everything"
            }
        }

        /// The days it covers: [from, to).
        func range(now: Date, calendar cal: Calendar) -> (Date, Date) {
            let today = cal.startOfDay(for: now)
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? now
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? today
            switch self {
            case .today: return (today, tomorrow)
            case .week: return (cal.date(byAdding: .day, value: -6, to: today) ?? today, tomorrow)
            case .month: return (thisMonth, tomorrow)
            case .lastMonth: return (cal.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth, thisMonth)
            case .all: return (.distantPast, .distantFuture)
            }
        }
    }

    enum Format: Int, CaseIterable {
        case timesheet, xlsx, csv, text
        var title: String {
            switch self {
            case .timesheet: return "Timesheet"
            case .xlsx: return "Excel"
            case .csv: return "CSV"
            case .text: return "Text"
            }
        }
        var subtitle: String {
            switch self {
            case .timesheet: return "Copy day by day"
            case .xlsx: return ".xlsx workbook"
            case .csv: return "Any spreadsheet"
            case .text: return "Dates, numbered"
            }
        }
        var fileExtension: String? {
            switch self {
            case .xlsx: return "xlsx"
            case .csv: return "csv"
            case .timesheet: return nil
            case .text: return "txt"
            }
        }
    }

    struct Row: Equatable {
        var day: String       // 2026-10-07
        var date: Date        // that day, for headings
        var index: Int        // 1, 2, 3 within the day
        var project: String
        var repo: String = ""     // "cerebrum", "api, web" (commit-made tasks)
        var title: String
        var done: Bool        // finished that day
        var minutes: Int
        var estimate: Int
        var status: String { done ? "Done" : "Open" }
    }

    static let header = ["Date", "#", "Project", "Repo", "Task", "Status", "Minutes", "Estimate"]

    /// The rows for a span, newest day first, in the order the tasks were added.
    /// `project` nil: every project.
    static func rows(_ store: TaskStore, span: Span, project: String? = nil) -> [Row] {
        let cal = store.calendar, now = store.now()
        let startToday = cal.startOfDay(for: now)
        let (from, to) = span.range(now: now, calendar: cal)
        // Which days each task belongs to: days with time on it, the day it was finished, the day it was added.
        var byDay: [String: [(FocusTask, Date)]] = [:]
        for t in store.tasks where project == nil || store.project(of: t) == project {
            var days: [String: Date] = [:]
            let live = store.spent(t) - t.spent
            for k in t.log.keys { if let d = date(k, cal) { days[k] = d } }
            if live > 0 { days[store.dayKey(now)] = startToday }
            if let d = t.doneAt { days[store.dayKey(d)] = cal.startOfDay(for: d) }
            if days.isEmpty { days[store.dayKey(t.created)] = cal.startOfDay(for: t.created) }
            for (k, d) in days where d >= from && d < to { byDay[k, default: []].append((t, d)) }
        }
        var out: [Row] = []
        for k in byDay.keys.sorted(by: >) {
            let list = byDay[k]!.sorted { $0.0.created < $1.0.created }
            for (i, (t, d)) in list.enumerated() {
                var secs = t.log[k] ?? 0
                if k == store.dayKey(now) { secs += store.spent(t) - t.spent }
                out.append(Row(day: k, date: d, index: i + 1, project: store.project(of: t), repo: t.repos.joined(separator: ", "), title: t.title,
                               done: t.doneAt.map { store.dayKey($0) == k } ?? false,
                               minutes: Int((secs / 60).rounded()), estimate: t.estimate))
            }
        }
        return out
    }

    private static func date(_ key: String, _ cal: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    // MARK: Formats

    static func cells(_ r: Row) -> [String] {
        [r.day, String(r.index), r.project, r.repo, r.title, r.status, String(r.minutes), r.estimate > 0 ? String(r.estimate) : ""]
    }

    static func csv(_ rows: [Row]) -> String {
        func q(_ s: String) -> String {
            s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        return ([header] + rows.map(cells)).map { $0.map(q).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Tab-separated: what Google Sheets (and Numbers, Excel) split into cells when pasted.
    static func tsv(_ rows: [Row]) -> String {
        ([header] + rows.map(cells)).map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    /// Each day's date, then its tasks numbered. One project: its name on top. Several: each
    /// task carries its project in brackets.
    static func text(_ rows: [Row], project: String? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE, d MMM yyyy"
        var out: [String] = project.map { [$0, ""] } ?? []
        let tagged = project == nil && Set(rows.map(\.project)).count > 1
        var day = ""
        for r in rows {
            if r.day != day {
                if !day.isEmpty || (project != nil && out.count > 2) { out.append("") }
                day = r.day
                out.append(f.string(from: r.date))
            }
            let time = r.minutes > 0 || r.done ? (r.done ? " ✓ " : " · ") + duration(r.minutes) : ""
            let tags = [tagged ? r.project : nil, r.repo.isEmpty ? nil : r.repo].compactMap { $0 }
            out.append("  \(r.index). \(r.title)\(tags.isEmpty ? "" : " [" + tags.joined(separator: " · ") + "]")\(time)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Timesheet

    /// What a timesheet copy holds, and whether times round to quarter hours.
    struct SheetOptions: Equatable {
        var times = false, repos = false, round = true
        static var saved: SheetOptions {
            get {
                let d = UserDefaults.standard
                return SheetOptions(times: d.bool(forKey: "tasks.sheet.times"), repos: d.bool(forKey: "tasks.sheet.repos"),
                                    round: d.object(forKey: "tasks.sheet.round") as? Bool ?? true)
            }
            set {
                let d = UserDefaults.standard
                d.set(newValue.times, forKey: "tasks.sheet.times")
                d.set(newValue.repos, forKey: "tasks.sheet.repos")
                d.set(newValue.round, forKey: "tasks.sheet.round")
            }
        }
    }

    /// Minutes as a timesheet takes them: to the nearest quarter hour (at least one, for any work).
    static func minutes(_ m: Int, round: Bool) -> Int {
        guard round, m > 0 else { return m }
        return max(15, Int((Double(m) / 15).rounded()) * 15)
    }

    /// The rows by day, newest first.
    static func days(_ rows: [Row]) -> [(date: Date, rows: [Row])] {
        var order: [String] = [], by: [String: [Row]] = [:]
        for r in rows {
            if by[r.day] == nil { order.append(r.day) }
            by[r.day, default: []].append(r)
        }
        return order.sorted(by: >).map { (by[$0]![0].date, by[$0]!) }
    }

    /// One day, ready to paste: a bullet per task.
    static func dayText(_ rows: [Row], _ o: SheetOptions) -> String {
        rows.map { r in
            var line = "• " + r.title
            if o.repos, !r.repo.isEmpty { line += " (\(r.repo))" }
            if o.times { line += " — " + duration(minutes(r.minutes, round: o.round)) }
            return line
        }.joined(separator: "\n")
    }

    /// Every day: its date and total, then its tasks.
    static func sheetText(_ rows: [Row], _ o: SheetOptions) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM yyyy"
        return days(rows).map { d in
            let total = d.rows.reduce(0) { $0 + minutes($1.minutes, round: o.round) }
            return "\(f.string(from: d.date)) · \(duration(total))\n" + dayText(d.rows, o)
        }.joined(separator: "\n\n") + "\n"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "45m", "1h 05m".
    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }

    static func fileName(_ span: Span, _ format: Format, project: String? = nil, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let tag: String
        switch span {
        case .today: tag = f.string(from: now)
        case .week: tag = f.string(from: calendar.date(byAdding: .day, value: -6, to: now) ?? now) + " to " + f.string(from: now)
        case .month: f.dateFormat = "yyyy-MM"; tag = f.string(from: now)
        case .lastMonth: f.dateFormat = "yyyy-MM"; tag = f.string(from: calendar.date(byAdding: .month, value: -1, to: now) ?? now)
        case .all: tag = "all"
        }
        // "Tasks Zera 2026-10-07.xlsx": no slashes or colons from a project name in the file name.
        let p = project.map { " " + $0.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-") } ?? ""
        return "Tasks\(p) \(tag).\(format.fileExtension ?? "tsv")"
    }

    // MARK: Excel

    /// A one-sheet workbook: bold header, numbers as numbers, sensible column widths.
    static func xlsx(_ rows: [Row]) -> Data {
        func esc(_ s: String) -> String {
            var o = ""
            for ch in s.unicodeScalars {
                switch ch {
                case "&": o += "&amp;"
                case "<": o += "&lt;"
                case ">": o += "&gt;"
                case "\"": o += "&quot;"
                default:
                    // XML 1.0 forbids most control characters.
                    if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                    o.unicodeScalars.append(ch)
                }
            }
            return o
        }
        func col(_ i: Int) -> String { String(UnicodeScalar(UInt8(65 + i))) }   // A…H
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\
        <cols><col min="1" max="1" width="12" customWidth="1"/><col min="2" max="2" width="5" customWidth="1"/>\
        <col min="3" max="3" width="16" customWidth="1"/><col min="4" max="4" width="22" customWidth="1"/>\
        <col min="5" max="5" width="44" customWidth="1"/><col min="6" max="6" width="9" customWidth="1"/>\
        <col min="7" max="8" width="10" customWidth="1"/></cols><sheetData>
        """
        let all: [[String]] = [header] + rows.map(cells)
        for (r, line) in all.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, v) in line.enumerated() {
                let ref = col(c) + String(r + 1)
                let numeric = r > 0 && [1, 6, 7].contains(c)
                if numeric, v.isEmpty { continue }   // no estimate: an empty cell
                if numeric { sheet += "<c r=\"\(ref)\"><v>\(v)</v></c>" }
                else { sheet += "<c r=\"\(ref)\" t=\"inlineStr\"\(r == 0 ? " s=\"1\"" : "")><is><t xml:space=\"preserve\">\(esc(v))</t></is></c>" }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"

        let files: [(String, String)] = [
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            </Types>
            """),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """),
            ("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="Tasks" sheetId="1" r:id="rId1"/></sheets></workbook>
            """),
            ("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
            </Relationships>
            """),
            ("xl/styles.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
            </styleSheet>
            """),
            ("xl/worksheets/sheet1.xml", sheet),
        ]
        return StoredZip.make(files.map { ($0.0, Data($0.1.utf8)) })
    }

    // MARK: Writing out

    /// Saves to Downloads (a new name if one's there) or, for Sheets, copies the table.
    /// Returns the saved file, or nil after copying.
    @discardableResult
    static func export(_ store: TaskStore, span: Span, format: Format, project: String? = nil) throws -> URL? {
        let rows = rows(store, span: span, project: project)
        let data: Data
        switch format {
        case .timesheet:
            copy(sheetText(rows, SheetOptions.saved))
            return nil
        case .csv: data = Data(csv(rows).utf8)
        case .text: data = Data(text(rows, project: project).utf8)
        case .xlsx: data = xlsx(rows)
        }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = fileName(span, format, project: project, now: store.now(), calendar: store.calendar)
        var url = dir.appendingPathComponent(name)
        var n = 2
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// A zip archive with its files stored uncompressed: all an .xlsx needs, with no other tools.
enum StoredZip {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func make(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        // 1 Jan 2026, 00:00 in DOS time: the date doesn't matter, a fixed one keeps the output stable.
        let dosTime = 0, dosDate = ((2026 - 1980) << 9) | (1 << 5) | 1
        for (name, data) in files {
            let n = Data(name.utf8), crc = crc32(data), offset = UInt32(out.count)
            u32(0x0403_4B50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out)
            u16(dosTime, &out); u16(dosDate, &out)
            u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out)
            u16(n.count, &out); u16(0, &out)
            out.append(n); out.append(data)

            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(dosTime, &central); u16(dosDate, &central)
            u32(crc, &central); u32(UInt32(data.count), &central); u32(UInt32(data.count), &central)
            u16(n.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central)
            central.append(n)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out)
        u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }
}
