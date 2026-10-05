// Pure model helpers for the window taskbar. Kept free of QML so the window
// selection, grouping and icon-matching rules can be reasoned about (and
// tested) on their own, the same way OhmTabsModel.js separates its state
// transitions.

// Desktop-entry ids and window appIds disagree on punctuation and casing
// ("brave-browser" vs "Brave", "org.telegram.desktop" vs "TelegramDesktop"), so
// matching happens on a squashed key rather than the raw string.
function normalizeId(value) {
  var text = String(value || "").trim()
  if (text.slice(-8) === ".desktop") text = text.slice(0, -8)
  return text
}

function shortId(value) {
  var text = normalizeId(value)
  var dot = text.lastIndexOf(".")
  return dot >= 0 ? text.slice(dot + 1) : text
}

function matchKey(value) {
  return normalizeId(value).toLowerCase().replace(/[^a-z0-9]/g, "")
}

// Hyprland's Lua dispatchers address windows by hex string. HyprlandToplevel
// reports it without the 0x prefix; the dispatcher selector requires it.
function dispatcherAddress(address) {
  var text = String(address || "")
  if (!text) return ""
  return text.indexOf("0x") === 0 ? text : "0x" + text
}

function buildEntryIndex(entries) {
  var index = {}
  var list = entries || []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry) continue
    var keys = [
      matchKey(entry.id),
      matchKey(entry.startupClass),
      matchKey(shortId(entry.id)),
      matchKey(entry.name)
    ]
    for (var k = 0; k < keys.length; k++) {
      if (keys[k] && index[keys[k]] === undefined) index[keys[k]] = entry
    }
  }
  return index
}

function entryForApp(appId, index) {
  if (!index) return null
  var candidates = [matchKey(appId), matchKey(shortId(appId))]
  for (var i = 0; i < candidates.length; i++) {
    if (candidates[i] && index[candidates[i]]) return index[candidates[i]]
  }
  return null
}

// Desktop entries keyed by their display name, for identifying a window by its
// title. Terminals run arbitrary apps in one class, and Chromium-app/PWA
// windows carry a synthetic class, so the title is the only sensible identity
// for those; the name index is what turns "cliamp" or "Discord" back into an
// app with its own icon.
function buildNameIndex(entries) {
  var index = {}
  var list = entries || []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry) continue
    var key = matchKey(entry.name)
    if (key && index[key] === undefined) index[key] = entry
  }
  return index
}

function entryForTitle(title, nameIndex) {
  if (!nameIndex) return null
  var text = String(title || "").trim()
  if (!text) return null
  var exact = nameIndex[matchKey(text)]
  if (exact) return exact
  // Many apps title their window "Document - App"; try the trailing segment.
  var dash = text.lastIndexOf(" - ")
  if (dash > 0) {
    var tail = nameIndex[matchKey(text.slice(dash + 3))]
    if (tail) return tail
  }
  return null
}

// Terminal emulator window classes. The class names the terminal, but the
// title usually names whatever is running inside it.
var TERMINAL_KEYS = {
  foot: true, footclient: true, alacritty: true, kitty: true, ghostty: true,
  wezterm: true, weztermgui: true, konsole: true, gnometerminal: true,
  gnometerminalserver: true, xterm: true, st: true, urxvt: true, rxvt: true,
  terminator: true, tilix: true, xfce4terminal: true, mateterminal: true,
  lxterminal: true, sakura: true, hyper: true, tabby: true, rio: true,
  contour: true, blackbox: true, warp: true, qterminal: true
}

// Browser window classes. A normal browser window names the browser, but a PWA
// / app window carries a synthetic class (brave-discord.com__channels_...), so
// the title is the identity there.
var BROWSER_PREFIXES = [
  "brave", "chrome", "chromium", "googlechrome", "microsoftedge",
  "vivaldi", "opera", "zen", "librewolf", "waterfox", "falkon",
  "epiphany", "firefox"
]

function isTerminalApp(appId) {
  return TERMINAL_KEYS[matchKey(appId)] === true
}

function isBrowserApp(appId) {
  var key = matchKey(appId)
  for (var i = 0; i < BROWSER_PREFIXES.length; i++) {
    if (key.indexOf(BROWSER_PREFIXES[i]) === 0) return true
  }
  return false
}

// Resolve one window to the app it actually represents:
// { key, appId, iconName }.
//
// Terminals prefer the title (so a foot window running cliamp is cliamp, not
// foot); browsers fall back to the title (so a PWA window is the app it points
// at); everything else is matched on its class first and only considers the
// title if the class resolves to nothing.
function resolveApp(appId, title, entryIndex, nameIndex) {
  var entry = null
  if (isTerminalApp(appId)) {
    entry = entryForTitle(title, nameIndex) || entryForApp(appId, entryIndex)
  } else {
    entry = entryForApp(appId, entryIndex)
    if (!entry && isBrowserApp(appId)) entry = entryForTitle(title, nameIndex)
  }

  if (entry) {
    return {
      key: matchKey(entry.id) || matchKey(appId),
      appId: normalizeId(entry.id) || String(appId || ""),
      iconName: entry.icon ? String(entry.icon) : (shortId(appId) || "application-x-executable")
    }
  }
  return {
    key: matchKey(appId) || String(appId || "") || "?",
    appId: String(appId || ""),
    iconName: shortId(appId) || String(appId || "") || "application-x-executable"
  }
}

function iconNameFor(appId, index) {
  var entry = entryForApp(appId, index)
  if (entry && entry.icon) return String(entry.icon)
  return shortId(appId) || String(appId || "") || "application-x-executable"
}

// Windows on the focused workspace, in Hyprland's own enumeration order.
// Deliberately NOT sorted by focus: the toplevel list order is effectively
// creation order, which is what gives the strip its stable, Windows-like
// positions -- focusing a window must not shuffle the icons. Workspaces come
// from the toplevel's own workspace object, so moving a window between
// workspaces reflows the list without extra bookkeeping.
function workspaceWindows(toplevels, workspaceId, entryIndex, nameIndex) {
  var list = toplevels || []
  var result = []
  for (var i = 0; i < list.length; i++) {
    var toplevel = list[i]
    if (!toplevel) continue
    var workspace = toplevel.workspace
    if (!workspace || workspace.id !== workspaceId) continue
    if (!toplevel.wayland) continue
    var appId = String((toplevel.wayland && toplevel.wayland.appId) || "")
    var title = String(toplevel.title || "")
    var resolved = resolveApp(appId, title, entryIndex, nameIndex)
    result.push({
      address: String(toplevel.address || ""),
      hyprAddress: dispatcherAddress(toplevel.address),
      appId: appId,
      // Identity the strip groups and labels by, and the icon it draws.
      key: resolved.key,
      taskAppId: resolved.appId,
      iconName: resolved.iconName,
      title: title,
      activated: toplevel.activated === true,
      wayland: toplevel.wayland
    })
  }
  return result
}

// Group windows by application and keep a persistent first-seen order.
//
// `state` is a plain object owned by the caller ({ win, grp, next }) that acts
// as the memory of the strip: every address and every app key gets a rank the
// first time it is seen and keeps it until the window/app disappears. That is
// what makes the icons stay put -- a newly focused window does not jump to the
// front, and a group does not reorder when one of its windows is focused.
//
// Returns one entry per app: { key, appId, windows, activated, focusedIndex,
// count }, groups sorted by first-seen rank, windows within a group sorted by
// first-seen rank.
function groupWindows(windows, state, pinned, explicitOrder) {
  if (!state) state = {}
  if (!state.win) state.win = {}
  if (!state.grp) state.grp = {}
  if (typeof state.next !== "number") state.next = 0

  var list = windows || []
  var i, key

  // Prune ranks for windows that have closed so a later window reusing an
  // unrelated slot starts fresh rather than inheriting a stale position.
  var alive = {}
  for (i = 0; i < list.length; i++) alive[list[i].address] = true
  for (var addr in state.win) if (!alive[addr]) delete state.win[addr]

  // Assign a rank to every window we have not seen before (append order).
  for (i = 0; i < list.length; i++) {
    if (state.win[list[i].address] === undefined) state.win[list[i].address] = state.next++
  }

  // Bucket by app key, preserving first-seen app order.
  var order = []
  var byKey = {}
  for (i = 0; i < list.length; i++) {
    var win = list[i]
    key = win.key || matchKey(win.appId) || String(win.appId || "") || "?"
    if (!byKey[key]) {
      byKey[key] = {
        key: key,
        appId: win.taskAppId || win.appId,
        iconName: win.iconName,
        windows: []
      }
      order.push(key)
    }
    byKey[key].windows.push(win)
  }

  // Prune and assign group ranks.
  var liveKeys = {}
  for (key in byKey) liveKeys[key] = true
  for (var oldKey in state.grp) if (!liveKeys[oldKey]) delete state.grp[oldKey]
  for (key in byKey) if (state.grp[key] === undefined) state.grp[key] = state.next++

  var groups = []
  for (i = 0; i < order.length; i++) {
    var group = byKey[order[i]]
    group.windows.sort(function(left, right) {
      return (state.win[left.address] || 0) - (state.win[right.address] || 0)
    })
    group.focusedIndex = -1
    group.activated = false
    for (var j = 0; j < group.windows.length; j++) {
      if (group.windows[j].activated) {
        group.activated = true
        group.focusedIndex = j
      }
    }
    group.count = group.windows.length
    groups.push(group)
  }

  groups.sort(function(left, right) {
    return (state.grp[left.key] || 0) - (state.grp[right.key] || 0)
  })

  // Assemble the final strip: pinned membership plus the user's drag order.
  //
  // `pinned` is membership -- a pinned app stays visible with no window so it
  // can act as a launch target. `order` is the explicit display order the widget
  // persists when icons are dragged. A key takes the slot of the first list that
  // names it (explicit order, then pinned, then first-seen order for the rest),
  // and an app that is neither running nor pinned is dropped from the strip.
  var pinnedList = pinned || []
  var pinnedKeys = {}
  for (var pi = 0; pi < pinnedList.length; pi++) {
    var pinKey = matchKey(pinnedList[pi])
    if (pinKey) pinnedKeys[pinKey] = true
  }

  var groupsByKey = {}
  for (var bi = 0; bi < groups.length; bi++) groupsByKey[groups[bi].key] = groups[bi]

  var ordered = []
  var placed = {}
  function place(appId) {
    var key = matchKey(appId)
    if (!key || placed[key]) return
    placed[key] = true
    var group = groupsByKey[key]
    if (group) {
      if (pinnedKeys[key]) group.pinned = true
      ordered.push(group)
    } else if (pinnedKeys[key]) {
      ordered.push({
        key: key,
        appId: String(appId),
        windows: [],
        activated: false,
        focusedIndex: -1,
        count: 0,
        pinned: true
      })
    }
  }

  var orderList = explicitOrder || []
  for (var oi = 0; oi < orderList.length; oi++) place(orderList[oi])
  for (var pj = 0; pj < pinnedList.length; pj++) place(pinnedList[pj])
  for (var rj = 0; rj < groups.length; rj++) place(groups[rj].appId)

  return ordered
}

// The window a click on a group should act on when the user has not picked a
// specific thumbnail: the focused one, else the oldest in the group.
function primaryWindow(group) {
  if (!group || !group.windows || group.windows.length === 0) return null
  if (group.focusedIndex >= 0) return group.windows[group.focusedIndex]
  return group.windows[0]
}

// Next window when a click should cycle through a group, Windows-style.
function nextWindow(group) {
  if (!group || !group.windows || group.windows.length === 0) return null
  if (group.windows.length === 1) return group.windows[0]
  var next = (group.focusedIndex >= 0) ? (group.focusedIndex + 1) % group.windows.length : 0
  return group.windows[next]
}

function countForApp(toplevels, appId) {
  var list = toplevels || []
  var key = matchKey(appId)
  var total = 0
  for (var i = 0; i < list.length; i++) {
    var toplevel = list[i]
    if (toplevel && toplevel.wayland && matchKey(toplevel.wayland.appId) === key) total++
  }
  return total
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeId: normalizeId,
    shortId: shortId,
    matchKey: matchKey,
    dispatcherAddress: dispatcherAddress,
    buildEntryIndex: buildEntryIndex,
    buildNameIndex: buildNameIndex,
    entryForApp: entryForApp,
    entryForTitle: entryForTitle,
    isTerminalApp: isTerminalApp,
    isBrowserApp: isBrowserApp,
    resolveApp: resolveApp,
    iconNameFor: iconNameFor,
    workspaceWindows: workspaceWindows,
    groupWindows: groupWindows,
    primaryWindow: primaryWindow,
    nextWindow: nextWindow,
    countForApp: countForApp
  }
}
