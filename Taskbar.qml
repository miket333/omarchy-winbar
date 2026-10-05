import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "TaskbarModel.js" as Model

// Taskbar for the Omarchy bar.
//
// One entry per application on the *focused* workspace, Windows-style: an app
// with several windows shows a single icon with a count badge, and hovering it
// shows a live thumbnail per window. Left-click focuses (and, for a group,
// cycles through the app's windows); middle-click closes; right-click opens the
// management menu. The same menu opens from a right-click on a thumbnail.
//
// Positions are stable. Windows and apps are ranked the first time they are
// seen and keep that slot until they close, so focusing a window never
// reshuffles the strip (see Model.groupWindows).
//
// Follows the host bar's orientation: a left/right bar stacks the entries
// vertically, a top/bottom bar lays them out in a row (`root.vertical`, the
// same flag the first-party widgets use).
//
// Why a bar widget rather than a separate dock: Omarchy's bar already reserves
// the screen edge and owns the popout coordinator, so extending it costs no new
// surface and no exclusive zone. Why no per-window title strips: Hyprland 0.56
// has no minimize dispatcher, so a strip could only offer close/maximize -- the
// same controls, but drawn on every window and fighting apps that ship their
// own close button. Keeping the controls in the bar avoids that entirely.
//
// Control routing. Hyprland 0.56 replaced string dispatchers with the Lua API
// (`hl.dsp.*`), and Quickshell's native `Toplevel.activate()` /
// `Toplevel.maximized` are not honoured by Hyprland. So window actions go out
// as `Hyprland.dispatch()` calls carrying a Lua dispatcher expression, while
// the window list itself comes from `Hyprland.toplevels` (which exposes the
// Hyprland address and workspace that the native Wayland handle does not).
pragma ComponentBehavior: Bound

BarWidget {
  id: root
  moduleName: "io.github.miket333.winbar"

  readonly property int iconSize: Number(setting("iconSize", 18))
  // Long-axis cap for the strip, whichever way the bar runs.
  readonly property int maxExtent: Number(setting("maxExtent", setting("maxWidth", 520)))
  readonly property bool showThumbnails: setting("showThumbnails", true) !== false
  // App ids pinned to the bar as launch targets. Stored as a comma-separated
  // string, not a JSON array: the shell IPC round-trip mangles array arguments,
  // so a plain string is the only shape that survives intact. An array is still
  // accepted in case it was hand-edited into shell.json.
  readonly property var pinnedApps: {
    var raw = setting("pinned", "")
    if (Array.isArray(raw)) return raw
    var parts = String(raw || "").split(",")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var id = parts[i].trim()
      if (id) out.push(id)
    }
    return out
  }

  // Explicit display order set by dragging icons; empty means first-seen order.
  // Stored comma-separated for the same shell-IPC reason as pins.
  readonly property var savedOrder: {
    var raw = setting("order", "")
    if (Array.isArray(raw)) return raw
    var parts = String(raw || "").split(",")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var id = parts[i].trim()
      if (id) out.push(id)
    }
    return out
  }

  // The order the strip is actually drawn in. A drag updates this live so icons
  // reflow under the cursor; null means "follow the saved order".
  property var orderDraft: null
  readonly property var iconOrder: orderDraft !== null ? orderDraft : savedOrder
  property bool dragActive: false

  readonly property int thumbnailWidth: Number(setting("thumbnailWidth", 220))
  // Cap on thumbnails shown per group so a big group cannot grow an unbounded
  // popup; the remainder is summarised as "+N more".
  readonly property int maxThumbnails: Number(setting("maxThumbnails", 6))

  // The preview popup sizes its window to the thumbnail Flow's implicit width,
  // but the Flow sits inset from the window edge by the card's padding and
  // border. Requesting only the Flow width left the row hanging one inset past
  // the right edge, so the rightmost (or only) thumbnail's highlight frame and
  // X were clipped while every earlier thumbnail sat safely inside. Adding the
  // horizontal insets to the request lets the whole row fit.
  readonly property real previewHorizontalInset: previewPopup.padding * 2
    + Border.left(previewPopup.borderSpec) + Border.right(previewPopup.borderSpec)

  readonly property var allToplevels: Hyprland.toplevels.values
  readonly property var focusedWorkspace: Hyprland.focusedWorkspace
  readonly property int focusedWorkspaceId: focusedWorkspace ? focusedWorkspace.id : -1

  // Rebuilt whenever the toplevel set or the focused workspace changes. The
  // workspace filter lives in the model so a window moving workspaces reflows
  // the strip with no extra tracking.
  readonly property var windows: Model.workspaceWindows(allToplevels, focusedWorkspaceId, entryIndex, nameIndex)

  // Persistent first-seen ranking. Mutated in place by the model; the property
  // reference never changes, so this stays out of the binding graph.
  property var rankState: ({ win: {}, grp: {}, next: 0 })

  readonly property var groups: Model.groupWindows(windows, rankState, pinnedApps, iconOrder)
  readonly property int groupCount: groups.length

  // appId -> desktop entry, for icon and launch resolution, and the same
  // entries keyed by display name so a window title ("cliamp", "Discord") can
  // be resolved back to the app with its own icon.
  readonly property var entryIndex: Model.buildEntryIndex(DesktopEntries.applications.values)
  readonly property var nameIndex: Model.buildNameIndex(DesktopEntries.applications.values)

  // Each entry is a square-ish cell: icon plus a little padding along the bar.
  readonly property int entryExtent: iconSize + Style.space(8)
  readonly property int contentExtent: Math.max(entryExtent, Math.min(maxExtent, groupCount * entryExtent))

  // The app whose preview is open. Addressed by id rather than by group object
  // so the preview survives the group list being rebuilt -- closing a window
  // from the menu re-resolves this to whatever of the group is left, and the
  // matching thumbnail simply disappears when its window closes.
  property string hoverAppId: ""

  // The group under the cursor (drives the preview). Derived from hoverAppId so
  // it always reflects the current group list.
  readonly property var hoverGroup: {
    if (!root.hoverAppId) return null
    var key = Model.matchKey(root.hoverAppId)
    var list = root.groups
    for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
    return null
  }

  // Which specific window the menu was opened for, that window's whole group,
  // and -- for a menu opened from a thumbnail -- the item the menu centres on.
  property var activeWindow: null
  property var activeGroup: null
  property var menuAnchor: null
  // Where the menu should centre, in widget-local coordinates. Set from a
  // thumbnail's projected screen position (see thumbnailAnchorPoint).
  property real menuAnchorX: 0
  property real menuAnchorY: 0

  // Icon drag-to-reorder state. The strip is deliberately NOT reordered while a
  // drag is in flight: mutating the model mid-drag recreates the delegates and
  // tears down the very DragHandler driving the gesture, which is what made the
  // icon drop the moment it crossed its neighbour. The target slot is tracked
  // and drawn as an insertion bar instead, and the move is committed on release.
  property int dragFromIndex: -1
  property int dragToIndex: -1
  // Icon name captured at drag start, so the magnified ghost shows the app's
  // resolved icon even after the model reflows.
  property string dragIconName: ""
  // The boundary the icon lands on, which is the target slot shifted one to the
  // right when moving right (the splice removes before it inserts).
  readonly property int dragEdge: root.dragToIndex < 0 ? 0
    : root.dragToIndex + (root.dragToIndex > root.dragFromIndex ? 1 : 0)
  property string dragAppId: ""
  property point dragGhostPoint: Qt.point(0, 0)

  // Live values for the settings popup. Edits land here first so the widget
  // reacts instantly, then persist to this widget's shell.json entry over the
  // shell IPC (the write updates `settings` in place, so nothing is torn down).
  property var settingsDraft: ({})


  readonly property var hoverWindows: {
    var group = root.hoverGroup
    if (!group || !group.windows) return []
    return group.windows.length > root.maxThumbnails
      ? group.windows.slice(0, root.maxThumbnails) : group.windows
  }
  readonly property int hoverMore: {
    var group = root.hoverGroup
    if (!group || !group.windows) return 0
    return Math.max(0, group.windows.length - root.maxThumbnails)
  }


  // Menu rows for the app under the cursor. Window actions only appear when a
  // window is there; a pinned-but-not-running app still gets Pin/Unpin and New
  // window so the entry stays useful as a launcher.
  readonly property var menuItems: {
    var group = root.activeGroup
    var hasWindow = root.activeWindow !== null && root.activeWindow !== undefined
    var count = (group && group.windows) ? group.windows.length : 0
    var items = []
    if (hasWindow) {
      items.push({ label: "Focus", action: "focus" })
      items.push({ label: "Maximize / restore", action: "maximize" })
    }
    items.push({ label: "New window", action: "new" })
    items.push({ label: (group && group.pinned) ? "Unpin from taskbar" : "Pin to taskbar", action: "pin" })
    if (hasWindow) {
      items.push({ label: "Close", action: "close" })
      items.push({ label: "Close other windows", action: "closeOthers" })
      items.push({ label: "Close all windows", action: "closeAll" })
    } else if (count > 1) {
      // Right-clicked the icon of a multi-window app: no single instance is the
      // subject, so only app-wide actions are offered -- no Focus, Maximize or
      // Close, which would each silently act on one arbitrary window.
      items.push({ label: "Close all windows", action: "closeAll" })
    }
    items.push({ label: "Settings\u2026", action: "settings" })
    return items
  }

  visible: groupCount > 0
  implicitWidth: !visible ? 0 : (root.vertical ? barSize : contentExtent + Style.space(4))
  implicitHeight: !visible ? 0 : (root.vertical ? contentExtent + Style.space(4) : barSize)

  function iconSource(appId) {
    return Quickshell.iconPath(Model.iconNameFor(appId, entryIndex), true)
  }

  // Icon for a group (or a window), preferring the icon name resolved when the
  // window was grouped -- that is what lets a foot window running cliamp show
  // the cliamp icon rather than foot's.
  function groupIconSource(group) {
    if (group && group.iconName) return Quickshell.iconPath(group.iconName, true)
    return iconSource(group ? group.appId : "")
  }

  function windowIconSource(win) {
    if (win && win.iconName) return Quickshell.iconPath(win.iconName, true)
    return iconSource(win ? win.appId : "")
  }

  function hyprAddressFor(window) {
    return Model.dispatcherAddress(window.address)
  }

  // Window actions. Each builds one Lua dispatcher expression and hands it to
  // Quickshell's Hyprland IPC. `address:0x...` is the selector form Hyprland's
  // hl.get_window accepts.
  //
  // focusWindow keeps the pointer where it is. Focusing a window makes Hyprland
  // warp the cursor to that window's centre, because cursor:no_warps is off by
  // default (it keeps the mouse and keyboard focus agreeing under follow_mouse).
  // A thumbnail click would otherwise fling the cursor across the screen away
  // from the thumbnail just clicked. So the focus and a cursor restore travel in
  // one Lua expression: hl.get_cursor_pos() reads the click point before the
  // warp, and the trailing hl.dsp.cursor.move puts the pointer back. Doing both
  // in a single dispatch means they can never race, and no global cursor setting
  // has to change (keyboard-driven focus elsewhere keeps warping as before).
  function focusWindow(window) {
    if (!window || !window.address) return
    var target = 'hl.get_window("address:' + hyprAddressFor(window) + '")'
    Hyprland.dispatch(
      '(function() local p = hl.get_cursor_pos(); '
      + 'hl.dispatch(hl.dsp.focus({ window = ' + target + ' })); '
      + 'if p then return hl.dsp.cursor.move({ x = p.x, y = p.y }) end; '
      + 'return hl.dsp.no_op() end)()')
  }

  function toggleMaximize(window) {
    if (!window || !window.address) return
    Hyprland.dispatch('hl.dsp.window.fullscreen({ window = hl.get_window("address:' + hyprAddressFor(window) + '"), mode = "maximized" })')
  }

  // Clicking a thumbnail brings that window forward and fills the screen. It is
  // deliberately not a blind toggle: Hyprland stores each window's maximized
  // state separately, so toggling maximized the new window while leaving the old
  // one maximized too (two windows at once, and the gesture read as a reset).
  // Instead:
  //   - clicking the window already filling the screen returns it to its tiled
  //     spot, and
  //   - clicking any other window makes it the fullscreen one and drops the
  //     previously maximized window back into the layout.
  // The whole decision runs in one Lua expression (a blind toggle cannot express
  // "is this the current one?"), with the pointer put back afterwards, so the
  // cursor never leaves the thumbnail.
  function activateThumbnail(window) {
    if (!window || !window.address) return
    var target = 'hl.get_window("address:' + hyprAddressFor(window) + '")'
    Hyprland.dispatch(
      '(function() local w = ' + target + '; if not w then return hl.dsp.no_op() end; '
      + 'local p = hl.get_cursor_pos(); local cur = hl.get_active_window(); '
      + 'local restore = cur ~= nil and cur.address == w.address and w.fullscreen == 1; '
      + 'local prev = nil; '
      + 'if cur ~= nil and cur.address ~= w.address and cur.fullscreen == 1 then prev = cur end; '
      + 'hl.dispatch(hl.dsp.focus({ window = w })); '
      + 'if restore then '
      + 'hl.dispatch(hl.dsp.window.fullscreen_state({ window = w, internal = 0, client = 0 })); '
      + 'else '
      + 'if prev then hl.dispatch(hl.dsp.window.fullscreen_state({ window = prev, internal = 0, client = 0 })) end; '
      + 'hl.dispatch(hl.dsp.window.fullscreen_state({ window = w, internal = 1, client = 0 })); '
      + 'end; '
      + 'if p then return hl.dsp.cursor.move({ x = p.x, y = p.y }) end; '
      + 'return hl.dsp.no_op() end)()')
  }

  function closeWindow(window) {
    if (!window || !window.address) return
    Hyprland.dispatch('hl.dsp.window.close({ window = hl.get_window("address:' + hyprAddressFor(window) + '") })')
  }

  // Left-click on a group: single window focuses, a multi-window group cycles
  // through its windows so repeated clicks reach each one.
  function activateGroup(group) {
    var target = Model.nextWindow(group)
    if (target) focusWindow(target)
  }

  // Bulk closes act on the app the menu was opened from, which is what a
  // grouped taskbar implies; falling back to the whole workspace keeps the
  // menu useful if it ever opens without a group.
  function closeOthers(window, group) {
    var list = (group && group.windows) ? group.windows : windows
    for (var i = 0; i < list.length; i++) {
      if (list[i].address !== window.address) closeWindow(list[i])
    }
  }

  function closeAll(group) {
    var list = (group && group.windows) ? group.windows : windows
    for (var i = 0; i < list.length; i++) closeWindow(list[i])
  }

  // Launch an app by appId. Used for "New window" and to quick-launch a pinned
  // app that has no window. Falls back to running the appId itself (works for
  // binaries named like their window class).
  function launchApp(appId) {
    if (!appId) return
    var entry = Model.entryForApp(appId, entryIndex)
    if (entry && entry.id) {
      Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", Model.normalizeId(entry.id) + ".desktop"])
      return
    }
    var name = Model.shortId(appId)
    if (name) Quickshell.execDetached(["uwsm-app", "--", name])
  }

  function newWindow(window) {
    if (window) launchApp(window.appId)
  }

  // Pin or unpin the app behind an entry. Persisted straight to shell.json so
  // the shelf is shared by every monitor's bar and survives restarts.
  function togglePin(group) {
    if (!group) return
    var key = Model.matchKey(group.appId)
    var list = root.pinnedApps.slice()
    var found = -1
    for (var i = 0; i < list.length; i++) {
      if (Model.matchKey(list[i]) === key) { found = i; break }
    }
    if (found >= 0) list.splice(found, 1)
    else list.push(group.appId)
    root.persistSetting("pinned", list.join(","))
  }

  // Begin an icon drag: remember where it started. Nothing reorders yet, so the
  // delegate -> handler -> grab chain stays intact for the whole gesture.
  function beginDrag(appId, index) {
    root.dragActive = true
    root.dragAppId = appId || ""
    root.dragIconName = ""
    var list = root.groups
    for (var i = 0; i < list.length; i++) {
      if (Model.matchKey(list[i].appId) === Model.matchKey(appId)) { root.dragIconName = list[i].iconName || ""; break }
    }
    root.dragFromIndex = index
    root.dragToIndex = index
    root.orderDraft = null
    root.closePreview()
    root.suppressBarDrag()
  }

  // Pointer position along the bar's axis -> the slot the icon would land in.
  function updateDragTarget(along) {
    if (!root.dragActive) return
    var count = Math.max(1, root.groupCount)
    var slot = Math.floor(along / Math.max(1, root.entryExtent))
    root.dragToIndex = Math.max(0, Math.min(count - 1, slot))
  }

  // Commit the drag: move the app from its start slot to the target slot, draw
  // the new order, and persist it. The list only ever holds pinned or running
  // apps (all the strip contains), so it cannot grow stale.
  function commitDrag() {
    if (!root.dragActive) return
    var from = root.dragFromIndex
    var to = root.dragToIndex
    root.dragActive = false
    root.dragFromIndex = -1
    root.dragToIndex = -1
    root.dragAppId = ""
    root.dragIconName = ""

    var list = []
    var grps = root.groups
    for (var i = 0; i < grps.length; i++) list.push(grps[i].appId)
    if (from < 0 || from >= list.length) return
    if (to < 0) to = from
    if (from !== to) {
      var moved = list.splice(from, 1)[0]
      list.splice(to, 0, moved)
    }
    root.orderDraft = list
    root.persistSetting("order", list.join(","))
  }

  // The bar lets any left-drag over a widget move the whole module to another
  // slot, and a plugin has no public switch to opt out. So while an icon drag is
  // in flight we reach up the item tree for the host Bar and clear that gesture:
  // only the icon moves. Defensive (the host API is not public) and scoped to
  // our own drag, so module reordering elsewhere is untouched.
  function suppressBarDrag() {
    var item = root
    for (var depth = 0; item && depth < 24; depth++) {
      if (typeof item.clearBarDrag === "function") {
        if (item.barDragSource) item.clearBarDrag()
        return
      }
      item = item.parent
    }
  }

  function showPreview(group) {
    previewCloseTimer.stop()
    if (root.dragActive) return
    // Hovering an entry dismisses any menu opened from another one: the menu
    // belongs to the entry it was opened from, so moving onto a neighbour folds
    // it away and the newly hovered entry previews in its place.
    if (menuPopup.open) {
      // A menu opened from an entry owns that entry: re-entering it -- or a
      // stray enter event as the pointer travels up toward the menu -- must
      // leave the menu standing, or the cursor could never reach it. Hovering
      // any *other* entry still folds the menu away and previews the neighbour.
      var owner = root.activeGroup
      if (group && owner && group.key === owner.key) {
        previewCloseTimer.stop()
        return
      }
      root.closeMenu()
    }
    // A pinned app with no window has nothing to preview. Clearing the preview
    // here (rather than doing nothing) closes whatever the previous entry left
    // open, so hovering a dormant launcher always returns the strip to rest.
    if (root.showThumbnails && group && group.windows && group.windows.length > 0) {
      root.hoverAppId = group.appId
    } else {
      root.hoverAppId = ""
    }
    // closeMenu() (via its open-changed handler) may have armed the grace timer
    // around the group we just left; cancel it so the entry we are now hovering
    // is not dismissed a moment later.
    previewCloseTimer.stop()
  }

  function closePreview() {
    previewCloseTimer.stop()
    root.hoverAppId = ""
  }

  // anchor: the item the menu centres on. Opened from a thumbnail it is that
  // thumbnail (so the menu lands over it rather than over the bar icon); opened
  // from an icon it is the icon. keepPreview holds the thumbnail strip open
  // underneath the menu so the previews do not vanish the moment it opens.
  function openMenu(window, group, anchor, keepPreview) {
    root.activeWindow = window
    root.activeGroup = group || null
    root.menuAnchor = anchor || root
    if (!keepPreview) root.closePreview()
    menuPopup.open = true
  }

  // Open the menu from a thumbnail, centred on it.
  //
  // The menu cannot anchor to the thumbnail directly: the thumbnail lives in
  // the preview's own window, and anchoring across windows breaks on the host's
  // PopupCard (its `contentItem` alias shadows the window's). So the thumbnail's
  // centre is projected to widget coordinates -- reproducing the preview's own
  // anchoring, including the screen-edge clamp -- and the marker item inside the
  // bar window is anchored there instead.
  function openThumbnailMenu(window, group, thumb) {
    var point = root.thumbnailAnchorPoint(thumb)
    root.menuAnchorX = point.x
    root.menuAnchorY = point.y
    root.openMenu(window, group, menuAnchorMarker, true)
  }

  function thumbnailAnchorPoint(thumb) {
    var win = root.QsWindow ? root.QsWindow.window : null
    var winW = win && win.width > 0 ? win.width : 1920
    var winH = win && win.height > 0 ? win.height : 1080
    var margin = Style.gapsOut
    var origin = root.mapToItem(null, 0, 0)
    var popW = previewPopup.implicitWidth
    var popH = previewPopup.implicitHeight
    // Padding plus the popup's border, the inset the flow's content sits at.
    var inset = previewPopup.padding + Math.max(1, Style.space(2))

    if (root.vertical) {
      var desiredY = origin.y + root.height / 2 - popH / 2
      var popY = Math.max(margin, Math.min(desiredY, winH - popH - margin))
      return { x: 0, y: Math.round(popY + inset + thumb.y + thumb.height / 2 - origin.y) }
    }

    var desiredX = origin.x + root.width / 2 - popW / 2
    var popX = Math.max(margin, Math.min(desiredX, winW - popW - margin))
    return { x: Math.round(popX + inset + thumb.x + thumb.width / 2 - origin.x), y: 0 }
  }

  function closeMenu() {
    menuPopup.open = false
    root.activeWindow = null
    root.activeGroup = null
    root.menuAnchor = null
    // The preview was held open while the menu was up; once the menu is gone let
    // it close on its normal hover rules again.
    if (root.hoverGroup !== null && !previewPopup.containsMouse) previewCloseTimer.restart()
  }

  // Writes one setting into this widget's shell.json entry via the shell IPC
  // (a third-party widget cannot touch the config file directly). The value is
  // JSON-encoded so numbers and booleans round-trip unchanged.
  function persistSetting(key, value) {
    if (!root.bar) return
    root.bar.run("omarchy-shell shell setBarWidget "
      + Util.shellQuote(root.moduleName) + " "
      + Util.shellQuote(key) + " "
      + Util.shellQuote(JSON.stringify(value)) + " '{}'")
  }

  // Current value for the settings popup: the not-yet-persisted draft wins,
  // otherwise the live setting (or its default).
  function draftGet(key, fallback) {
    var value = root.settingsDraft ? root.settingsDraft[key] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function adjustSetting(key, delta, minimum, maximum, fallback) {
    var current = Number(root.draftGet(key, fallback))
    if (isNaN(current)) current = Number(fallback)
    var next = Math.max(minimum, Math.min(maximum, current + delta))
    var draft = {}
    for (var existing in root.settingsDraft) draft[existing] = root.settingsDraft[existing]
    draft[key] = next
    root.settingsDraft = draft
    root.persistSetting(key, next)
  }

  function toggleSetting(key, fallback) {
    var next = !root.draftGet(key, fallback)
    var draft = {}
    for (var existing in root.settingsDraft) draft[existing] = root.settingsDraft[existing]
    draft[key] = next
    root.settingsDraft = draft
    root.persistSetting(key, next)
  }

  function openSettings() {
    root.settingsDraft = ({})
    settingsPopup.open = true
  }

  function closeSettings() {
    settingsPopup.open = false
  }

  // Entry cell: one icon per app. Hovering opens the thumbnail preview; the
  // preview stays open while the cursor is on it (see the timer below).
  component GroupEntry: Item {
    id: entry
    required property var groupData
    required property int slot

    // Lifted and faded while dragged, so the moving icon reads clearly.
    opacity: entryDrag.active ? 0.45 : 1
    z: entryDrag.active ? 1 : 0

    readonly property bool focused: entry.groupData.activated
    readonly property int count: entry.groupData.count
    // Pinned apps stay on the bar even with no window, dimmed until they run.
    readonly property bool pinned: entry.groupData.pinned === true

    width: root.vertical ? root.barSize : root.entryExtent
    height: root.vertical ? root.entryExtent : root.barSize

    Rectangle {
      anchors.fill: parent
      anchors.margins: Style.space(2)
      radius: Style.cornerRadius
      color: root.bar ? root.bar.urgent : Color.urgent
      opacity: entry.focused ? 0.22 : (entryMouse.containsMouse ? 0.12 : 0)
      Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }

    Image {
      anchors.centerIn: parent
      width: root.iconSize
      height: root.iconSize
      // A pinned app with no window is a launch target, so it reads quieter
      // than one that is actually running -- but it comes to full strength while
      // hovered, so a dormant launcher reads as interactive under the pointer.
      opacity: entry.count === 0 && !entryMouse.containsMouse ? 0.5 : 1
      Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      source: root.groupIconSource(entry.groupData)
      sourceSize.width: root.iconSize * 2
      sourceSize.height: root.iconSize * 2
      fillMode: Image.PreserveAspectFit
      smooth: true
    }

    // Window-count badge. "1" confirms an app is running, "2" (etc.) that it
    // holds several windows; a pinned app with none shows no badge.
    Text {
      visible: entry.count >= 1
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(1)
      text: entry.count
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      id: entryMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor

      onEntered: {
        root.showPreview(entry.groupData)
        if (root.bar) {
          var label = entry.count > 1
            ? entry.groupData.appId + " (" + entry.count + " windows)"
            : (entry.groupData.windows.length ? entry.groupData.windows[0].title : entry.groupData.appId)
          root.bar.showTooltip(entry, label)
        }
      }
      onExited: {
        // The strip-level HoverHandler owns closing the preview, so leaving a
        // single entry (moving to a neighbour, the badge, or a gap) does not
        // dismiss it.
        if (root.bar) root.bar.hideTooltip(entry)
      }
      onClicked: function(mouse) {
        // Left-click launches a pinned app that is not running; on a running app
        // it stays a no-op, because the hover preview is how a window is chosen
        // and a stray click should not change focus under the thumbnails.
        if (mouse.button === Qt.LeftButton) {
          if (entry.count === 0) root.launchApp(entry.groupData.appId)
        } else if (mouse.button === Qt.MiddleButton) {
          var toClose = Model.primaryWindow(entry.groupData)
          if (toClose) root.closeWindow(toClose)
        } else if (mouse.button === Qt.RightButton) {
          // Right-clicking the icon targets the app, not one of its windows. A
          // lone window is still a valid subject and keeps the per-window rows;
          // a multi-window app has no single subject, so the menu drops to
          // app-wide actions only (see menuItems).
          var wins = entry.groupData.windows ? entry.groupData.windows.length : 0
          var subject = wins > 1 ? null : Model.primaryWindow(entry.groupData)
          root.openMenu(subject, entry.groupData, entry, false)
        }
      }
    }

    // Drag to reorder. `target: null` leaves the item under the layout's control:
    // the handler only reports the pointer; the strip is not reordered until the
    // drop, so this handler keeps its grab for the whole gesture. A plain click
    // never activates it (Qt's drag threshold gates it), so launching and the
    // menu still work. The grab is explicitly taken over from the bar module's
    // MouseArea, so the container does not start moving as well.
    DragHandler {
      id: entryDrag
      target: null
      grabPermissions: PointerHandler.CanTakeOverFromItems
        | PointerHandler.CanTakeOverFromHandlersOfDifferentType
        | PointerHandler.ApprovesTakeOverByItems

      onActiveChanged: {
        if (active) {
          root.beginDrag(entry.groupData.appId, entry.slot)
          if (root.bar) root.bar.hideTooltip(entry)
        } else {
          root.commitDrag()
        }
      }

      onCentroidChanged: {
        if (!active) return
        // The zoomed icon follows the pointer, and the slot under it becomes the
        // drop target drawn as the insertion bar.
        var scene = entryDrag.centroid.scenePosition
        root.dragGhostPoint = stripClip.mapFromItem(null, scene.x, scene.y)
        var point = stripGrid.mapFromItem(entry, entryDrag.centroid.position.x, entryDrag.centroid.position.y)
        root.updateDragTarget(root.vertical ? point.y : point.x)
      }
    }
  }

  // Safety net for the bar's module-drag gesture: if it starts anyway while an
  // icon is being dragged, keep clearing it so the container never moves.
  Timer {
    running: root.dragActive
    interval: 60
    repeat: true
    onTriggered: root.suppressBarDrag()
  }

  // Grace period so the cursor can travel from the icon into the preview
  // without the preview vanishing in the gap. Cancelled while the cursor is
  // over the card.
  Timer {
    id: previewCloseTimer
    interval: 300
    repeat: false
    // Held open while the menu is up, so a right-clicked thumbnail keeps its
    // preview underneath the menu instead of vanishing.
    onTriggered: { if (!previewPopup.containsMouse && !menuPopup.open) root.hoverAppId = "" }
  }


  Connections {
    target: previewPopup
    function onContainsMouseChanged() {
      if (previewPopup.containsMouse) previewCloseTimer.stop()
      else if (root.hoverGroup !== null && !menuPopup.open) previewCloseTimer.restart()
    }
  }

  // The menu can also be dismissed by an outside click (the host's focus grab
  // closes it without going through closeMenu), so clear the state -- including
  // the thumbnail it was anchored to -- whenever it closes for any reason.
  Connections {
    target: menuPopup
    function onOpenChanged() {
      if (menuPopup.open) return
      root.activeWindow = null
      root.activeGroup = null
      root.menuAnchor = null
      if (root.hoverGroup !== null && !previewPopup.containsMouse && !root.dragActive) previewCloseTimer.restart()
    }
  }

  // Keeps the preview alive anywhere over the widget: nudging between entries,
  // onto the count badge, or into the gaps must not dismiss it. Only leaving
  // the whole strip (with the cursor not on the preview card either) closes it.
  HoverHandler {
    id: stripHover
    onHoveredChanged: {
      if (hovered) previewCloseTimer.stop()
      else if (root.hoverGroup !== null && !previewPopup.containsMouse && !menuPopup.open && !root.dragActive) previewCloseTimer.restart()
    }
  }

  // Numeric setting row: label, then − / value / +. Every press persists
  // immediately; the write updates `settings` in place without rebuilding the
  // widget, so the popup stays open and the change shows at once.
  component SettingStepper: Item {
    id: stepper
    required property string label
    required property string settingKey
    required property int value
    required property int stepSize
    required property int minimum
    required property int maximum
    required property int fallbackValue

    width: parent.width
    height: Style.space(28)

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: stepper.label
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(20)
      spacing: Style.space(2)

      Rectangle {
        width: Style.space(20)
        height: Style.space(20)
        radius: Style.cornerRadius
        color: root.bar ? root.bar.urgent : Color.urgent
        opacity: minusMouse.containsMouse ? 0.22 : 0.1

        Text {
          anchors.centerIn: parent
          text: "\u2212"
          color: root.bar ? root.bar.barForeground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: minusMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.adjustSetting(stepper.settingKey, -stepper.stepSize, stepper.minimum, stepper.maximum, stepper.fallbackValue)
        }
      }

      Text {
        width: Style.space(28)
        height: Style.space(20)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: stepper.value
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
      }

      Rectangle {
        width: Style.space(20)
        height: Style.space(20)
        radius: Style.cornerRadius
        color: root.bar ? root.bar.urgent : Color.urgent
        opacity: plusMouse.containsMouse ? 0.22 : 0.1

        Text {
          anchors.centerIn: parent
          text: "+"
          color: root.bar ? root.bar.barForeground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: plusMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.adjustSetting(stepper.settingKey, stepper.stepSize, stepper.minimum, stepper.maximum, stepper.fallbackValue)
        }
      }
    }
  }

  // Boolean setting row: label plus a small switch.
  component SettingToggle: Item {
    id: toggle
    required property string label
    required property string settingKey
    required property bool value
    required property bool fallbackValue

    width: parent.width
    height: Style.space(28)

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: toggle.label
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    Rectangle {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(36)
      height: Style.space(18)
      radius: height / 2
      color: root.bar ? root.bar.urgent : Color.urgent
      opacity: toggle.value ? 0.85 : 0.25

      Rectangle {
        width: Style.space(12)
        height: Style.space(12)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        x: toggle.value ? parent.width - width - Style.space(3) : Style.space(3)
        color: root.bar ? root.bar.barForeground : Color.foreground
        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleSetting(toggle.settingKey, toggle.fallbackValue)
      }
    }
  }

  // Settings popup, reachable from the icon/thumbnail menu. Values live in
  // `settingsDraft` while it is open and are written straight through to
  // shell.json, so they survive restarts and apply on every monitor's bar.
  PopupCard {
    id: settingsPopup
    anchorItem: root
    owner: root
    bar: root.bar
    contentWidth: settingsPopup.fittedContentWidth(Style.space(230))
    contentHeight: settingsPopup.fittedContentHeight(settingsColumn.implicitHeight)

    Column {
      id: settingsColumn
      anchors.fill: parent
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: "Taskbar settings"
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      SettingStepper {
        label: "Thumbnail size"
        settingKey: "thumbnailWidth"
        value: root.draftGet("thumbnailWidth", root.thumbnailWidth)
        stepSize: 20
        minimum: 140
        maximum: 420
        fallbackValue: 220
      }

      SettingStepper {
        label: "Thumbnails per app"
        settingKey: "maxThumbnails"
        value: root.draftGet("maxThumbnails", root.maxThumbnails)
        stepSize: 1
        minimum: 1
        maximum: 8
        fallbackValue: 6
      }

      SettingStepper {
        label: "Bar icon size"
        settingKey: "iconSize"
        value: root.draftGet("iconSize", root.iconSize)
        stepSize: 2
        minimum: 12
        maximum: 28
        fallbackValue: 18
      }

      SettingToggle {
        label: "Show thumbnails"
        settingKey: "showThumbnails"
        value: root.draftGet("showThumbnails", root.showThumbnails)
        fallbackValue: true
      }
    }
  }

  // A 1px stand-in the menu anchors to when it is opened from a thumbnail. The
  // menu cannot anchor to the thumbnail itself -- the thumbnail lives in the
  // preview's own window and the host's anchor code cannot map across windows --
  // so the thumbnail's offset within the preview is projected onto this marker
  // inside the bar window instead.
  Item {
    id: menuAnchorMarker
    width: 1
    height: 1
    x: Math.round(root.menuAnchorX)
    y: Math.round(root.menuAnchorY)
  }

  // Clip container so an over-long strip never bleeds into neighbouring
  // widgets; GridLayout switches between a row and a column on `vertical`.
  Item {
    id: stripClip
    anchors.fill: parent
    clip: true

    GridLayout {
      id: stripGrid
      anchors.centerIn: parent
      columns: root.vertical ? 1 : Math.max(1, root.groupCount)
      rowSpacing: 0
      columnSpacing: 0

      Repeater {
        model: root.groups
        delegate: GroupEntry {
          required property var modelData
          required property int index
          groupData: modelData
          slot: index
        }
      }
    }

    // Insertion bar: the boundary the dragged icon lands on when released.
    Rectangle {
      id: dropIndicator
      visible: root.dragActive && root.dragToIndex >= 0 && root.groupCount > 1 && root.dragEdge !== root.dragFromIndex
      z: 11
      radius: width / 2
      color: root.bar ? root.bar.barForeground : Color.foreground
      opacity: 0.85
      width: root.vertical ? stripGrid.width : Math.max(2, Math.round(root.entryExtent * 0.12))
      height: root.vertical ? Math.max(2, Math.round(root.entryExtent * 0.12)) : stripGrid.height
      x: root.vertical
        ? Math.round(stripGrid.x)
        : Math.round(stripGrid.x + root.dragEdge * root.entryExtent)
      y: root.vertical
        ? Math.round(stripGrid.y + root.dragEdge * root.entryExtent)
        : Math.round(stripGrid.y)
      Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
    }

    // Slightly magnified copy of the icon under the pointer while dragging.
    Image {
      id: dragGhost
      visible: root.dragActive
      z: 12
      source: root.dragAppId ? (root.dragIconName ? Quickshell.iconPath(root.dragIconName, true) : root.iconSource(root.dragAppId)) : ""
      width: Math.round(root.iconSize * 1.5)
      height: width
      sourceSize.width: root.iconSize * 3
      sourceSize.height: root.iconSize * 3
      fillMode: Image.PreserveAspectFit
      smooth: true
      opacity: 0.95
      x: Math.round(root.dragGhostPoint.x - width / 2)
      y: Math.round(root.dragGhostPoint.y - height / 2)
    }
  }

  // Live thumbnail preview: a ScreencopyView per window in the hovered group,
  // captured directly through hyprland-toplevel-export. Clicking a thumbnail
  // focuses that window; right-clicking it opens the same menu as the icon.
  PopupCard {
    id: previewPopup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.showThumbnails && root.hoverGroup !== null && !root.dragActive && !settingsPopup.open
    triggerMode: "hover"
    // Anchored to the hovered icon (not centred on the bar) so the previews sit
    // directly above the entry whichever way the bar runs.
    contentWidth: previewPopup.fittedContentWidth(previewFlow.implicitWidth + root.previewHorizontalInset)
    contentHeight: previewPopup.fittedContentHeight(previewFlow.implicitHeight)

    // Windows-style orientation: alongside a horizontal bar the previews run in
    // a row, alongside a vertical bar they stack. Flow does both from one layout.
    Flow {
      id: previewFlow
      flow: root.vertical ? Flow.TopToBottom : Flow.LeftToRight
      spacing: Style.space(8)

      // A fixed number of slots (maxThumbnails) rather than one delegate per
      // window. The delegate count is therefore constant, so closing a window
      // does not tear the strip down and rebuild it -- only the slots whose
      // window actually changed recapture, and the rest keep their frames.
      Repeater {
        model: root.maxThumbnails
        // Delegate is an Item, not a Column: the click overlay uses
        // anchors.fill, which a Column forbids on its children (and which
        // silently collapses the whole layout). The Column lives inside.
        delegate: Item {
          id: thumb
          required property int index
          // The window for this slot, or null when the group has fewer windows.
          readonly property var winData: index < root.hoverWindows.length ? root.hoverWindows[index] : null
          readonly property int titleIconExtent: Math.round(Style.font.bodySmall * 1.2)
          visible: thumb.winData !== null
          width: root.thumbnailWidth
          height: thumbBody.implicitHeight

          Column {
            id: thumbBody
            width: parent.width
            spacing: Style.space(3)

            // Title above the image with the app icon as a prefix, the way
            // Windows draws a taskbar preview.
            RowLayout {
              width: parent.width
              spacing: Style.space(4)

              Image {
                Layout.preferredWidth: thumb.titleIconExtent
                Layout.preferredHeight: thumb.titleIconExtent
                source: thumb.winData ? root.windowIconSource(thumb.winData) : ""
                sourceSize.width: Math.round(Style.font.bodySmall * 2.4)
                sourceSize.height: Math.round(Style.font.bodySmall * 2.4)
                fillMode: Image.PreserveAspectFit
                smooth: true
              }

              Text {
                Layout.fillWidth: true
                text: thumb.winData ? thumb.winData.title : ""
                color: root.bar ? root.bar.barForeground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            ScreencopyView {
              id: shot
              width: thumbBody.width
              height: Math.round(root.thumbnailWidth * 0.62)
              captureSource: thumb.winData ? thumb.winData.wayland : null
              live: false
              // A fresh delegate gets its source assigned at creation, which
              // does not emit a change, so capture on completion and on the
              // post-open tick too; the change handler covers switching groups
              // while the popup stays open.
              onCaptureSourceChanged: if (captureSource) captureFrame()
              // The preview's surface often has no recording context the instant
              // it opens, so a single still capture fired too early just fails
              // ("no recording context is ready"). Retry while visible until a
              // frame actually lands, then stop.
              Timer {
                running: previewPopup.open && thumb.winData !== null && !shot.hasContent
                interval: 200
                repeat: true
                onTriggered: if (shot.captureSource) shot.captureFrame()
              }
            }
          }

          // Windows-style hover highlight: a stroke around the whole preview
          // (title and image) once the pointer is on it.
          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: root.bar ? root.bar.urgent : Color.urgent
            opacity: thumbMouse.containsMouse ? 0.9 : 0
            Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
          }

          // Close affordance: a small X in the preview's upper-right, shown on
          // hover. It is a plain visual; the click is resolved by the overlay
          // below, so hit-testing never depends on stacking two MouseAreas.
          Rectangle {
            id: closeButton
            width: Style.space(18)
            height: Style.space(18)
            radius: width / 2
            color: root.bar ? root.bar.urgent : Color.urgent
            opacity: thumbMouse.containsMouse ? (thumbMouse.overClose ? 1.0 : 0.85) : 0
            z: 10
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(4)
            Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

            Text {
              anchors.centerIn: parent
              text: "\u2715"
              color: root.bar ? root.bar.barForeground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // Single click overlay. Left focuses the window, right opens the
          // management menu centred on this thumbnail (leaving the previews up),
          // and a click on the X closes that window.
          MouseArea {
            id: thumbMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            property bool overClose: false

            function withinClose(x, y) {
              return x >= closeButton.x && x <= closeButton.x + closeButton.width
                && y >= closeButton.y && y <= closeButton.y + closeButton.height
            }

            onPositionChanged: overClose = withinClose(mouse.x, mouse.y)
            onExited: overClose = false
            onClicked: function(mouse) {
              if (!thumb.winData) return
              if (withinClose(mouse.x, mouse.y)) {
                root.closeWindow(thumb.winData)
                return
              }
              var group = root.hoverGroup
              if (mouse.button === Qt.RightButton) {
                root.openThumbnailMenu(thumb.winData, group, thumb)
              } else {
                root.activateThumbnail(thumb.winData)
                root.closePreview()
              }
            }
          }
        }
      }

      Text {
        visible: root.hoverMore > 0
        text: "+" + root.hoverMore + " more"
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        opacity: 0.7
      }
    }
  }

  // Right-click management menu. Opened from an icon or a thumbnail; the bulk
  // actions apply to the whole app group.
  PopupCard {
    id: menuPopup
    anchorItem: root.menuAnchor !== null ? root.menuAnchor : root
    owner: root
    bar: root.bar
    contentWidth: menuPopup.fittedContentWidth(Style.space(210))
    contentHeight: menuPopup.fittedContentHeight(menuColumn.implicitHeight)

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: {
          var group = root.activeGroup
          if (root.activeWindow) {
            var base = root.activeWindow.title
            if (group && group.count > 1)
              base = group.appId + " (" + group.count + ") \u2014 " + base
            return base
          }
          if (!group) return ""
          var label = group.appId
          if (group.count > 1) label += " (" + group.count + ")"
          if (group.pinned) label += " (pinned)"
          return label
        }
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Repeater {
        model: root.menuItems

        delegate: Item {
          id: menuRow
          required property var modelData
          width: menuColumn.width
          height: Style.space(24)

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: root.bar ? root.bar.urgent : Color.urgent
            opacity: rowMouse.containsMouse ? 0.16 : 0
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: menuRow.modelData.label
            color: root.bar ? root.bar.barForeground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var target = root.activeWindow
              var group = root.activeGroup
              var action = menuRow.modelData.action
              root.closeMenu()
              if (action === "settings") { root.openSettings(); return }
              if (action === "pin") { root.togglePin(group); return }
              if (action === "new") { root.launchApp(group ? group.appId : (target ? target.appId : "")); return }
              // App-wide close works with no window subject, so it is handled
              // before the per-window guard below.
              if (action === "closeAll") { root.closeAll(group); return }
              if (!target) return
              if (action === "focus") root.focusWindow(target)
              else if (action === "maximize") root.toggleMaximize(target)
              else if (action === "close") root.closeWindow(target)
              else if (action === "closeOthers") root.closeOthers(target, group)
            }
          }
        }
      }
    }
  }
}
