import Foundation
import CSQLite

// MARK: - Raw row from the join query

struct TabRow {
    let groupId: Int64?
    let groupName: String?
    let groupColor: String?
    let groupCollapsed: Bool
    let tabId: Int64
    let tabCustomTitle: String?    // tabs.custom_title
    let tabPinned: Bool
    let tabGroupId: Int64?
    let cwd: String?
    let paneId: Int64?
    let verticalTabsTitle: String? // pane_leaves.custom_vertical_tabs_title
    let isFocused: Bool            // pane_leaves.is_focused
}

// MARK: - SQLiteReader

public final class SQLiteReader: Sendable {

    // Default path for the live Warp database
    public static let defaultDBPath = "/Users/princewagan/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"

    private let dbPath: String

    public init(dbPath: String = SQLiteReader.defaultDBPath) {
        self.dbPath = dbPath
    }

    // MARK: - Public API

    /// Read all tabs and tab groups from Warp's SQLite database.
    /// Returns (tabGroups, ungroupedTabs).
    public func readTabGroups() throws -> ([WarpTabGroup], [WarpTab]) {
        // Open in read-only URI mode. Never write, never checkpoint WAL.
        let uriPath = "file:\(dbPath)?mode=ro"
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI

        let openResult = sqlite3_open_v2(uriPath, &db, openFlags, nil)
        guard openResult == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError.openFailed("Could not open \(dbPath): \(msg) (code \(openResult))")
        }
        defer { sqlite3_close(db) }

        // Fetch raw rows
        let rows = try fetchRows(db: db)

        // Build the tab groups and ungrouped tabs from raw rows
        return buildGroups(from: rows)
    }

    // MARK: - Private: Query

    /// SQL query. Uses is_leaf = 1 in pane_nodes join to avoid non-leaf (container) nodes.
    /// Each tab has exactly one leaf pane_node in the current Warp schema.
    ///
    /// Column index reference (0-based):
    ///  0  group_id
    ///  1  group_name
    ///  2  group_color
    ///  3  group_collapsed
    ///  4  tab_id
    ///  5  custom_title
    ///  6  tab_pinned
    ///  7  tab_group_id
    ///  8  cwd
    ///  9  pane_id
    /// 10  custom_vertical_tabs_title
    /// 11  is_focused  (pane_leaves.is_focused — BOOLEAN, default TRUE in current Warp schema)
    private static let query = """
        SELECT
            tg.id        AS group_id,
            tg.name      AS group_name,
            tg.color     AS group_color,
            tg.collapsed AS group_collapsed,
            t.id         AS tab_id,
            t.custom_title,
            t.pinned     AS tab_pinned,
            t.tab_group_id,
            tp.cwd,
            tp.id        AS pane_id,
            pl.custom_vertical_tabs_title,
            pl.is_focused
        FROM tabs t
        LEFT JOIN tab_groups tg ON t.tab_group_id = tg.id
        LEFT JOIN pane_nodes pn ON pn.tab_id = t.id AND pn.is_leaf = 1
        LEFT JOIN pane_leaves pl ON pl.pane_node_id = pn.id
        LEFT JOIN terminal_panes tp ON tp.id = pl.pane_node_id
        ORDER BY tg.name NULLS LAST, t.id;
    """

    private func fetchRows(db: OpaquePointer) throws -> [TabRow] {
        var stmt: OpaquePointer?
        let prepResult = sqlite3_prepare_v2(db, Self.query, -1, &stmt, nil)
        guard prepResult == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.queryFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [TabRow] = []

        while true {
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.queryFailed("Step failed: \(msg)")
            }

            // Column 0: group_id
            let groupId: Int64? = sqlite3_column_type(stmt, 0) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 0) : nil

            // Column 1: group_name
            let groupName: String? = sqlite3_column_type(stmt, 1) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 1)) : nil

            // Column 2: group_color
            let groupColor: String? = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 2)) : nil

            // Column 3: group_collapsed (BOOLEAN = INTEGER in SQLite)
            let groupCollapsed = sqlite3_column_int64(stmt, 3) != 0

            // Column 4: tab_id
            let tabId = sqlite3_column_int64(stmt, 4)

            // Column 5: custom_title
            let tabCustomTitle: String? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 5)) : nil

            // Column 6: tab_pinned
            let tabPinned = sqlite3_column_int64(stmt, 6) != 0

            // Column 7: tab_group_id
            let tabGroupId: Int64? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 7) : nil

            // Column 8: cwd
            let cwd: String? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 8)) : nil

            // Column 9: pane_id
            let paneId: Int64? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 9) : nil

            // Column 10: custom_vertical_tabs_title
            let verticalTabsTitle: String? = sqlite3_column_type(stmt, 10) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 10)) : nil

            // Column 11: is_focused (pane_leaves.is_focused — BOOLEAN stored as INTEGER)
            // NOTE: In the current Warp schema this column defaults to TRUE for all rows,
            // meaning it cannot reliably identify the single focused tab. We read it faithfully
            // and let the caller decide how to use it. We treat NULL pane (no pane_leaves row)
            // as false, which is correct for tabs with no terminal pane yet.
            let isFocused: Bool = sqlite3_column_type(stmt, 11) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 11) != 0
                : false

            rows.append(TabRow(
                groupId: groupId,
                groupName: groupName,
                groupColor: groupColor,
                groupCollapsed: groupCollapsed,
                tabId: tabId,
                tabCustomTitle: tabCustomTitle,
                tabPinned: tabPinned,
                tabGroupId: tabGroupId,
                cwd: cwd,
                paneId: paneId,
                verticalTabsTitle: verticalTabsTitle,
                isFocused: isFocused
            ))
        }

        return rows
    }

    // MARK: - Private: Build Groups

    private func buildGroups(from rows: [TabRow]) -> ([WarpTabGroup], [WarpTab]) {
        // Group rows by tab_id (in case of split panes, though currently each tab has one leaf)
        // Strategy: for each tab_id, take the row where pane_id IS NOT NULL (has a terminal pane).
        // If multiple pane rows exist for the same tab (future split panes), pick based on cwd
        // availability. In current Warp schema there is exactly 1 leaf pane per tab.
        var tabRowMap: [Int64: TabRow] = [:]
        for row in rows {
            if let existing = tabRowMap[row.tabId] {
                // If existing row has no cwd but this one does, prefer this one
                if existing.cwd == nil && row.cwd != nil {
                    tabRowMap[row.tabId] = row
                }
                // Otherwise keep existing (first-wins is deterministic since query is ORDER BY t.id)
            } else {
                tabRowMap[row.tabId] = row
            }
        }

        // Preserve insertion order (ORDER BY tg.name, t.id from query)
        var seenTabIds: [Int64] = []
        var seenTabIdSet: Set<Int64> = []
        for row in rows {
            if !seenTabIdSet.contains(row.tabId) {
                seenTabIds.append(row.tabId)
                seenTabIdSet.insert(row.tabId)
            }
        }

        // Build WarpTab objects
        var tabsByGroupId: [Int64: [WarpTab]] = [:]  // groupId -> tabs
        var ungroupedTabs: [WarpTab] = []
        var groupMeta: [Int64: (name: String, color: String?, collapsed: Bool)] = [:]

        for tabId in seenTabIds {
            guard let row = tabRowMap[tabId] else { continue }
            let tab = makeWarpTab(from: row)

            if let gid = row.groupId, let gname = row.groupName {
                if tabsByGroupId[gid] == nil {
                    tabsByGroupId[gid] = []
                    groupMeta[gid] = (name: gname, color: parseColor(row.groupColor), collapsed: row.groupCollapsed)
                }
                tabsByGroupId[gid]!.append(tab)
            } else {
                ungroupedTabs.append(tab)
            }
        }

        // Build WarpTabGroup objects, preserving sort order (alphabetical by group name from query)
        // Collect group IDs in the order their first tab appeared
        var seenGroupIds: [Int64] = []
        var seenGroupIdSet: Set<Int64> = []
        for row in rows {
            if let gid = row.groupId, !seenGroupIdSet.contains(gid) {
                seenGroupIds.append(gid)
                seenGroupIdSet.insert(gid)
            }
        }

        var tabGroups: [WarpTabGroup] = []
        for gid in seenGroupIds {
            guard let meta = groupMeta[gid], let tabs = tabsByGroupId[gid] else { continue }
            tabGroups.append(WarpTabGroup(
                id: String(gid),
                name: meta.name,
                color: meta.color,
                collapsed: meta.collapsed,
                tabs: tabs
            ))
        }

        return (tabGroups, ungroupedTabs)
    }

    // MARK: - Helpers

    private func makeWarpTab(from row: TabRow) -> WarpTab {
        let tabIdStr = String(row.tabId)
        let cwd = row.cwd ?? ""

        // Title derivation rule (per plan):
        // 1. pane_leaves.custom_vertical_tabs_title (if not NULL and non-empty) — shown in Warp's sidebar
        // 2. tabs.custom_title (if not NULL and non-empty) — user-set label
        // 3. CWD lastPathComponent
        // 4. "Tab <id_prefix>" fallback
        //
        // titleSource records which rule won. Warp writes the agent's own title
        // into custom_vertical_tabs_title (e.g. "✳ Create test admin and staff
        // accounts"), so when that column is populated it is exactly what the
        // user sees on the tab. StateManager must not overwrite it with a
        // transcript-derived guess — see the ai_title guard there.
        let title: String
        let titleSource: String
        if let vt = row.verticalTabsTitle, !vt.isEmpty {
            title = vt
            titleSource = WarpTab.warpPaneTitleSource
        } else if let ct = row.tabCustomTitle, !ct.isEmpty {
            title = ct
            titleSource = "warp-custom-title"
        } else if !cwd.isEmpty {
            title = URL(fileURLWithPath: cwd).lastPathComponent
            titleSource = "cwd-basename"
        } else {
            title = "Tab \(tabIdStr.prefix(6))"
            titleSource = "tab-id"
        }

        // custom_title in the JSON contract uses tabs.custom_title
        let customTitle: String? = (row.tabCustomTitle?.isEmpty == false) ? row.tabCustomTitle : nil

        // NOTE on is_focused: pane_leaves.is_focused defaults to TRUE for all rows in the
        // current Warp schema, so reading it directly would mark every tab as "focused".
        // We emit false until Warp changes its schema to use this column meaningfully.
        // The field is present on the wire (never omitted) so old receivers still validate.

        // Git branch: read from <cwd>/.git/HEAD via the shared cached reader.
        // Cache TTL is 30s so at most one filesystem read per cwd per 30s cycle.
        // When cwd is empty (e.g. Warp Settings tab) we skip the read and return nil.
        let gitBranch: String? = cwd.isEmpty ? nil : GitBranchReader.shared.branch(for: cwd)

        return WarpTab(
            id: tabIdStr,
            title: title,
            custom_title: customTitle,
            cwd: cwd,
            pinned: row.tabPinned,
            is_focused: false,
            git_branch: gitBranch,
            title_source: titleSource
        )
    }

    /// Parse Warp's color format. Warp stores colors as CSS-style strings or named colors.
    /// Examples seen: "---\nColor: cyan\n", nil
    /// Returns a normalized string or nil.
    private func parseColor(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Warp stores colors as YAML-ish: "---\nColor: cyan\n"
        // Extract the color name after "Color: "
        if let range = raw.range(of: "Color: ") {
            let after = String(raw[range.upperBound...])
            let colorName = after.trimmingCharacters(in: .whitespacesAndNewlines)
            return colorName.isEmpty ? nil : colorName
        }
        // Fallback: return as-is if it looks like a hex color
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Errors

public enum SQLiteError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .queryFailed(let msg): return "SQLite query failed: \(msg)"
        }
    }
}
