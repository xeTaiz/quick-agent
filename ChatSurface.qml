import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Rectangle {
  id: root

  property var messagesModel: null
  property var permission: null
  property string draft: ""
  property string modelName: "sol"
  property string thinking: "medium"
  property string errorText: ""
  property bool busy: false
  property bool connected: false
  property bool expanded: false
  property int transcriptRevision: 0

  signal draftEdited(string text)
  signal sendRequested(string text)
  signal cancelRequested()
  signal newRequested()
  signal cycleModelRequested()
  signal cycleThinkingRequested()
  signal expandRequested()
  signal handoffRequested()
  signal closeRequested()
  signal permissionAnswered(var answer)

  readonly property color foreground: Color.popups.text
  readonly property color backgroundColor: Color.popups.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: Color.muted
  readonly property var permissionOptions: permission && Array.isArray(permission.options) ? permission.options : []
  readonly property bool hasMessages: messagesModel && messagesModel.count > 0
  readonly property int outerPadding: Style.space(expanded ? 18 : 16)

  color: backgroundColor
  radius: expanded ? 0 : Style.cornerRadius
  border.color: expanded ? "transparent" : Color.popups.border
  border.width: expanded ? 0 : Math.max(1, Style.normalBorderWidth)
  clip: true
  focus: true

  // Swallow otherwise-unhandled clicks inside the card so they never fall
  // through to the overlay's dismiss scrim. Interactive children stack above
  // this guard and continue to receive their own pointer events.
  MouseArea {
    anchors.fill: parent
    onClicked: {}
  }

  function focusComposer() {
    composer.forceActiveFocus()
    composer.cursorPosition = composer.length
  }

  function permissionHasDenyOption() {
    for (var i = 0; i < permissionOptions.length; i++) {
      var option = permissionOptions[i] || {}
      var label = String(option.label || "").toLowerCase()
      var value = option.value
      if (value === false || label.indexOf("deny") !== -1 || label.indexOf("reject") !== -1 || label.indexOf("cancel") !== -1)
        return true
    }
    return false
  }

  function isNearBottom() {
    if (!transcript || transcript.contentHeight <= transcript.height) return true
    return transcript.contentY >= transcript.contentHeight - transcript.height - Style.space(72)
  }

  function scrollToBottom() {
    if (!transcript || !root.hasMessages) return
    transcript.positionViewAtEnd()
  }

  function handleKey(event, fromComposer) {
    var control = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var backtab = event.key === Qt.Key_Backtab || (shift && event.key === Qt.Key_Tab)

    if (event.key === Qt.Key_Escape) {
      root.closeRequested()
      event.accepted = true
    } else if (!control && backtab) {
      root.cycleThinkingRequested()
      event.accepted = true
    } else if (control && shift && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      root.handoffRequested()
      event.accepted = true
    } else if (control && !shift && event.key === Qt.Key_P) {
      root.cycleModelRequested()
      event.accepted = true
    } else if (control && event.key === Qt.Key_E) {
      root.expandRequested()
      event.accepted = true
    } else if (control && event.key === Qt.Key_N) {
      root.newRequested()
      event.accepted = true
    } else if (fromComposer && !control && !shift && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      if (!root.busy && composer.text.trim().length > 0)
        root.sendRequested(composer.text)
      event.accepted = true
    }
  }

  onTranscriptRevisionChanged: {
    var follow = isNearBottom()
    Qt.callLater(function() {
      if (follow) root.scrollToBottom()
    })
  }

  Keys.priority: Keys.AfterItem
  Keys.onPressed: function(event) { root.handleKey(event, false) }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: root.outerPadding
    spacing: Style.spacing.md

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.sm

      Column {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: "Quick Agent"
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.weight: Font.DemiBold
        }

        Text {
          textFormat: Text.PlainText
          text: root.connected ? (root.busy ? "Working…" : "Ready") : "Starting agent…"
          color: root.connected ? root.muted : root.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        text: root.modelName + "  Ctrl+P"
        tooltipText: "Cycle model (Ctrl+P)"
        foreground: root.foreground
        accent: root.accent
        bordered: true
        enabled: root.connected
        focusable: true
        onClicked: root.cycleModelRequested()
      }

      Button {
        text: root.thinking + "  Shift+Tab"
        tooltipText: "Cycle thinking effort (Shift+Tab)"
        foreground: root.foreground
        accent: root.accent
        bordered: true
        enabled: root.connected
        focusable: true
        onClicked: root.cycleThinkingRequested()
      }

      Button {
        text: "New"
        tooltipText: "New temporary session (Ctrl+N)"
        foreground: root.foreground
        accent: root.accent
        enabled: root.connected
        focusable: true
        onClicked: root.newRequested()
      }

      Button {
        text: root.expanded ? "Overlay" : "Expand"
        tooltipText: (root.expanded ? "Return to overlay" : "Open a normal window") + " (Ctrl+E)"
        foreground: root.foreground
        accent: root.accent
        focusable: true
        onClicked: root.expandRequested()
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.spacing.hairline
      color: Util.alpha(root.foreground, 0.18)
    }

    ListView {
      id: transcript

      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.minimumHeight: root.hasMessages ? Style.space(120) : 0
      visible: root.hasMessages
      clip: true
      spacing: Style.spacing.sm
      model: root.messagesModel
      boundsBehavior: Flickable.StopAtBounds
      reuseItems: true
      Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

      onMovementEnded: {
        // The revision handler consults the current scroll position, so a user
        // who has deliberately scrolled upward is never pulled back down.
      }

      delegate: Item {
        id: messageRow

        required property int index
        required property string messageId
        required property string role
        required property string body

        readonly property bool fromUser: role === "user"
        readonly property bool isError: role === "error"
        width: ListView.view.width
        height: bubble.height

        Rectangle {
          id: bubble

          width: messageRow.fromUser ? Math.min(messageRow.width * 0.86, Style.space(620)) : messageRow.width
          height: messageText.implicitHeight + Style.space(20)
          anchors.right: messageRow.fromUser ? parent.right : undefined
          anchors.left: messageRow.fromUser ? undefined : parent.left
          radius: Style.cornerRadius
          color: messageRow.fromUser
            ? Util.alpha(root.accent, 0.13)
            : (messageRow.isError ? Util.alpha(root.urgent, 0.12) : "transparent")
          border.color: messageRow.fromUser
            ? Util.alpha(root.accent, 0.28)
            : (messageRow.isError ? Util.alpha(root.urgent, 0.35) : "transparent")
          border.width: (messageRow.fromUser || messageRow.isError) ? Math.max(1, Style.normalBorderWidth) : 0

          TextEdit {
            id: messageText

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            text: messageRow.body
            textFormat: TextEdit.MarkdownText
            wrapMode: TextEdit.Wrap
            color: messageRow.isError ? root.urgent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            readOnly: true
            selectByMouse: true
            selectByKeyboard: true
            persistentSelection: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) { root.handleKey(event, false) }

            TapHandler {
              acceptedButtons: Qt.LeftButton
              gesturePolicy: TapHandler.DragThreshold
              onTapped: function(eventPoint) {
                var link = messageText.linkAt(eventPoint.position.x, eventPoint.position.y)
                if (link.length > 0)
                  Qt.openUrlExternally(link)
              }
            }

            HoverHandler {
              cursorShape: messageText.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.IBeamCursor
            }
          }
        }
      }
    }

    Item {
      Layout.fillWidth: true
      Layout.fillHeight: !root.hasMessages
      Layout.minimumHeight: !root.hasMessages ? Style.space(root.expanded ? 40 : 14) : 0
      visible: !root.hasMessages

      Column {
        anchors.centerIn: parent
        width: parent.width
        spacing: Style.space(6)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "What can I help with?"
          horizontalAlignment: Text.AlignHCenter
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.weight: Font.Medium
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Files are read only after you approve the request."
          horizontalAlignment: Text.AlignHCenter
          color: root.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: permissionColumn.implicitHeight + Style.space(24)
      visible: root.permission !== null
      radius: Style.cornerRadius
      color: Util.alpha(root.accent, 0.1)
      border.color: Util.alpha(root.accent, 0.45)
      border.width: Math.max(1, Style.normalBorderWidth)

      Column {
        id: permissionColumn

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(12)
        spacing: Style.space(8)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.permission ? String(root.permission.title || "Permission required") : ""
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
          wrapMode: Text.WordWrap
        }

        TextEdit {
          width: parent.width
          textFormat: TextEdit.PlainText
          text: root.permission ? String(root.permission.message || "") : ""
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: TextEdit.WrapAnywhere
          readOnly: true
          selectByMouse: true
          persistentSelection: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.handleKey(event, false) }
        }

        Flow {
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            model: root.permissionOptions

            delegate: Button {
              required property var modelData
              text: String((modelData && modelData.label) || "Continue")
              foreground: root.foreground
              accent: root.accent
              bordered: true
              focusable: true
              onClicked: root.permissionAnswered(modelData ? modelData.value : false)
            }
          }

          Button {
            visible: !root.permissionHasDenyOption()
            text: "Deny"
            foreground: root.foreground
            accent: root.urgent
            bordered: true
            focusable: true
            onClicked: root.permissionAnswered(false)
          }
        }
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: errorLabel.implicitHeight + Style.space(16)
      visible: root.errorText.length > 0
      radius: Style.cornerRadius
      color: Util.alpha(root.urgent, 0.11)
      border.color: Util.alpha(root.urgent, 0.38)
      border.width: Math.max(1, Style.normalBorderWidth)

      TextEdit {
        id: errorLabel
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(8)
        textFormat: TextEdit.PlainText
        text: root.errorText
        color: root.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: TextEdit.WordWrap
        readOnly: true
        selectByMouse: true
        persistentSelection: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.handleKey(event, false) }
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.max(Style.space(54), Math.min(Style.space(150), composer.contentHeight + Style.space(20)))
      radius: Style.cornerRadius
      color: Util.alpha(root.foreground, 0.045)
      border.color: composer.activeFocus ? root.accent : Util.alpha(root.foreground, 0.24)
      border.width: Math.max(1, Style.normalBorderWidth)

      RowLayout {
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.spacing.sm

        Controls.TextArea {
          id: composer

          Layout.fillWidth: true
          Layout.fillHeight: true
          text: root.draft
          placeholderText: root.connected ? "Ask anything…" : "Starting agent…"
          enabled: root.connected
          color: root.foreground
          placeholderTextColor: root.muted
          selectionColor: Style.selectionFillFor(root.foreground, root.accent)
          selectedTextColor: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          background: null

          onTextChanged: if (root.draft !== text) root.draftEdited(text)
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.handleKey(event, true) }
        }

        Button {
          text: root.busy ? "Stop" : "Send"
          tooltipText: root.busy ? "Stop the current response" : "Send (Enter); newline (Shift+Enter)"
          foreground: root.busy ? root.urgent : root.foreground
          accent: root.busy ? root.urgent : root.accent
          bordered: true
          focusable: true
          enabled: root.busy || (root.connected && composer.text.trim().length > 0)
          onClicked: root.busy ? root.cancelRequested() : root.sendRequested(composer.text)
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.sm

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: "Enter send · Shift+Enter newline · Esc hide"
        color: root.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Button {
        text: "Hand off"
        tooltipText: "Continue this temporary session in the terminal (Ctrl+Shift+Enter)"
        foreground: root.foreground
        accent: root.accent
        focusable: true
        enabled: root.hasMessages && root.connected
        onClicked: root.handoffRequested()
      }
    }
  }
}
