import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons

Item {
  id: root

  // Standard Omarchy plugin injections. The third-party shell facade only
  // exposes lifecycle operations for this plugin.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool expanded: false
  property bool bridgeConnected: false
  property bool busy: false
  property bool handoffExitExpected: false
  property string draft: ""
  property string modelName: "sol"
  property string thinking: "medium"
  property string errorText: ""
  property string bridgeStderr: ""
  property var pendingPermission: null
  property int transcriptRevision: 0

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "xetaiz.quick-agent"
  readonly property string bridgePath: localFilePath(Qt.resolvedUrl("bridge.ts"))

  ListModel { id: messages }

  function localFilePath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0)
      return decodeURIComponent(value.substring(7))
    return value
  }

  function parsePayload(payloadJson) {
    if (!payloadJson) return ({})
    try { return JSON.parse(String(payloadJson)) || ({}) }
    catch (e) { return ({}) }
  }

  // Lifecycle entry points called by `omarchy-shell shell summon/hide/toggle`.
  // Hiding never destroys the bridge or temporary session because this plugin
  // is keepLoaded; it only denies an outstanding permission and hides windows.
  function open(payloadJson) {
    var payload = parsePayload(payloadJson)
    // A crashed bridge is retried only on an explicit summon. Automatic
    // reconnect loops could replace a temporary session before the user has
    // read the surfaced failure.
    if (!bridge.running) bridge.running = true
    opened = true
    expanded = payload.expanded === true || payload.expanded === "true"
    Qt.callLater(function() { root.focusVisibleComposer() })
    return "ok"
  }

  function close() {
    denyPendingPermission()
    opened = false
    expanded = false
  }

  function ping() { return "ok" }

  function requestClose() {
    denyPendingPermission()
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function focusVisibleComposer() {
    if (!opened) return
    if (expanded) expandedSurface.focusComposer()
    else overlaySurface.focusComposer()
  }

  function toggleExpanded() {
    expanded = !expanded
    Qt.callLater(function() { root.focusVisibleComposer() })
  }

  function writeCommand(command) {
    if (!bridge.running) {
      errorText = "The agent bridge is not running yet."
      return false
    }
    try {
      bridge.write(JSON.stringify(command) + "\n")
      return true
    } catch (e) {
      errorText = "Could not send to the agent bridge: " + String(e)
      return false
    }
  }

  function writeReadyCommand(command) {
    if (!bridgeConnected) {
      errorText = "The agent is still starting. Your draft was kept."
      return false
    }
    return writeCommand(command)
  }

  function sendDraft(text) {
    var value = String(text || "")
    if (!value.trim() || busy) return
    if (writeReadyCommand({ type: "send", text: value })) {
      draft = ""
      errorText = ""
    }
  }

  function cancelResponse() {
    denyPendingPermission()
    writeReadyCommand({ type: "cancel" })
  }

  function newSession() {
    denyPendingPermission()
    if (writeReadyCommand({ type: "new" })) {
      draft = ""
      errorText = ""
    }
  }

  function cycleModel() {
    writeReadyCommand({ type: "cycle_model" })
  }

  function cycleThinking() {
    writeReadyCommand({ type: "cycle_thinking" })
  }

  function handoff() {
    denyPendingPermission()
    writeReadyCommand({ type: "handoff" })
  }

  function respondToPermission(answer) {
    if (!pendingPermission) return
    var permissionId = pendingPermission.id
    pendingPermission = null
    writeCommand({ type: "permission", id: permissionId, answer: answer })
    Qt.callLater(function() { root.focusVisibleComposer() })
  }

  function denyPendingPermission() {
    if (!pendingPermission) return
    var permissionId = pendingPermission.id
    pendingPermission = null
    writeCommand({ type: "permission", id: permissionId, answer: false })
  }

  function messageIndex(messageId) {
    for (var i = 0; i < messages.count; i++) {
      if (messages.get(i).messageId === messageId) return i
    }
    return -1
  }

  function upsertMessage(event) {
    var messageId = String(event.id === undefined || event.id === null ? "" : event.id)
    if (!messageId) return
    var role = String(event.role || "assistant")
    var body = String(event.text === undefined || event.text === null ? "" : event.text)
    var index = messageIndex(messageId)
    if (index < 0) {
      messages.append({ messageId: messageId, role: role, body: body })
    } else {
      messages.setProperty(index, "role", role)
      messages.setProperty(index, "body", body)
    }
    transcriptRevision += 1
  }

  function clearConversation() {
    messages.clear()
    transcriptRevision += 1
  }

  function acceptPermission(event) {
    var id = event.id
    if (id === undefined || id === null) return

    // The user deliberately hid the surface. Never leave the agent blocked on
    // an invisible approval prompt and never reopen it behind their intent.
    // A later user message can retry the operation visibly.
    if (!opened) {
      writeCommand({ type: "permission", id: id, answer: false })
      return
    }

    // If the bridge ever replaces one unanswered prompt with another, the old
    // request is explicitly denied rather than disappearing as an approval.
    if (pendingPermission && String(pendingPermission.id) !== String(id))
      denyPendingPermission()

    var options = Array.isArray(event.options) ? event.options : []
    pendingPermission = {
      id: id,
      title: String(event.title || "Permission required"),
      message: String(event.message || ""),
      options: options
    }
    Qt.callLater(function() { root.focusVisibleComposer() })
  }

  function handleBridgeEvent(event) {
    if (!event || typeof event.type !== "string") return

    if (event.type === "state") {
      if (event.model !== undefined) modelName = String(event.model)
      if (event.thinking !== undefined) thinking = String(event.thinking)
      if (event.ready !== undefined) bridgeConnected = event.ready === true
      if (event.busy !== undefined) busy = event.busy === true
    } else if (event.type === "message") {
      upsertMessage(event)
    } else if (event.type === "permission") {
      acceptPermission(event)
    } else if (event.type === "error") {
      errorText = String(event.message || "Unknown agent error")
    } else if (event.type === "reset") {
      denyPendingPermission()
      clearConversation()
      errorText = ""
    } else if (event.type === "handoff") {
      if (event.ok === true) {
        pendingPermission = null
        clearConversation()
        draft = ""
        errorText = ""
        handoffExitExpected = true
        handoffExitWindow.restart()
        requestClose()
      } else {
        errorText = String(event.message || "Could not hand the session to the terminal")
      }
    }
  }

  function handleBridgeLine(line) {
    var value = String(line || "").trim()
    if (!value) return
    try {
      handleBridgeEvent(JSON.parse(value))
    } catch (e) {
      errorText = "The agent bridge returned invalid JSON."
      console.warn("quick-agent: invalid bridge output", value)
    }
  }

  Process {
    id: bridge

    command: ["bun", root.bridgePath]
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) { root.handleBridgeLine(line) }
    }

    stderr: SplitParser {
      onRead: function(line) {
        var value = String(line || "").trim()
        if (!value) return
        root.bridgeStderr = value
        console.warn("quick-agent bridge:", value)
      }
    }

    onStarted: {
      root.bridgeConnected = false
      root.bridgeStderr = ""
      if (root.errorText.indexOf("The agent bridge stopped") === 0
          || root.errorText.indexOf("The agent bridge is not running") === 0)
        root.errorText = ""
    }

    onExited: function(exitCode, exitStatus) {
      root.bridgeConnected = false
      root.busy = false
      root.denyPendingPermission()
      root.handoffExitWindow.stop()
      if (root.handoffExitExpected) {
        root.handoffExitExpected = false
        root.errorText = ""
      } else if (!root.errorText) {
        var detail = root.bridgeStderr ? ": " + root.bridgeStderr : ""
        root.errorText = "The agent bridge stopped (exit " + exitCode + ")" + detail
      }
    }
  }

  Timer {
    id: handoffExitWindow
    interval: 5000
    repeat: false
    onTriggered: root.handoffExitExpected = false
  }


  Component.onCompleted: bridge.running = true
  Component.onDestruction: {
    denyPendingPermission()
    if (bridge.running) bridge.running = false
  }

  PanelWindow {
    id: overlay

    visible: root.opened && !root.expanded
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "quick-agent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.requestClose()
    }

    ChatSurface {
      id: overlaySurface

      width: Math.min(Style.space(780), overlay.width - Style.gapsOut * 2)
      height: Math.min(overlay.height - Style.gapsOut * 2,
                       messages.count > 0 || root.pendingPermission ? Style.space(720) : Style.space(380))
      anchors.centerIn: parent

      messagesModel: messages
      permission: root.pendingPermission
      draft: root.draft
      modelName: root.modelName
      thinking: root.thinking
      errorText: root.errorText
      busy: root.busy
      connected: root.bridgeConnected
      expanded: false
      transcriptRevision: root.transcriptRevision

      onDraftEdited: function(text) { root.draft = text }
      onSendRequested: function(text) { root.sendDraft(text) }
      onCancelRequested: root.cancelResponse()
      onNewRequested: root.newSession()
      onCycleModelRequested: root.cycleModel()
      onCycleThinkingRequested: root.cycleThinking()
      onExpandRequested: root.toggleExpanded()
      onHandoffRequested: root.handoff()
      onCloseRequested: root.requestClose()
      onPermissionAnswered: function(answer) { root.respondToPermission(answer) }
    }
  }

  FloatingWindow {
    id: window

    visible: root.opened && root.expanded
    title: "Quick Agent"
    color: Color.popups.background
    implicitWidth: Style.space(920)
    implicitHeight: Style.space(780)
    minimumSize: Qt.size(Style.space(600), Style.space(480))

    onVisibleChanged: {
      // This condition is true for a window-manager close, but false when the
      // plugin itself collapses to the overlay or the host calls close().
      if (!visible && root.opened && root.expanded) root.requestClose()
      else if (visible) Qt.callLater(function() { expandedSurface.focusComposer() })
    }

    ChatSurface {
      id: expandedSurface

      anchors.fill: parent
      messagesModel: messages
      permission: root.pendingPermission
      draft: root.draft
      modelName: root.modelName
      thinking: root.thinking
      errorText: root.errorText
      busy: root.busy
      connected: root.bridgeConnected
      expanded: true
      transcriptRevision: root.transcriptRevision

      onDraftEdited: function(text) { root.draft = text }
      onSendRequested: function(text) { root.sendDraft(text) }
      onCancelRequested: root.cancelResponse()
      onNewRequested: root.newSession()
      onCycleModelRequested: root.cycleModel()
      onCycleThinkingRequested: root.cycleThinking()
      onExpandRequested: root.toggleExpanded()
      onHandoffRequested: root.handoff()
      onCloseRequested: root.requestClose()
      onPermissionAnswered: function(answer) { root.respondToPermission(answer) }
    }
  }
}
