import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property string backgroundPath: ""
  property string videoPosterPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool fingerprintUnavailable: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  // A locked session blanks the displays after a few seconds. Nothing is
  // visible from then until the user wakes it, so a video must not keep
  // decoding through what is usually the longest part of a lock.
  property bool displaysBlank: false
  property bool powerSaverActive: false
  property string passwordText: ""
  property bool syncingPasswordText: false

  // Info strip (LockExtras.qml), fed by the one LockInfo in Service.qml.
  property var info: null
  property bool primaryScreen: true

  property bool fido2Configured: false
  property bool fido2Active: false
  property bool fido2TokenPresent: false
  property bool fido2NeedsPin: false
  property bool fido2Authenticating: false
  property string fido2Status: ""

  // One field, two modes. In FIDO2 mode it carries a PIN and nothing else, and
  // it stays inert until pam_u2f has actually asked for one — so a PIN can
  // never be typed into the void, and never crosses into the password flow
  // where it would be spent against the key's eight-attempt retry budget.
  readonly property bool acceptsInput: fido2Active ? fido2NeedsPin : true

  // The field elides at about 25 characters, so these stay short enough to be
  // read whole: "Waiting for your security key…" arrived as "Waiting for your
  // securit…" on a real lock screen.
  readonly property string placeholderText: {
    if (!fido2Active) return Commons.I18n.t("lock.enterPassword")
    if (!fido2TokenPresent) return "No security key detected"
    if (fido2Status.length > 0) return fido2Status
    return "Waiting for your key…"
  }
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.19)
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it. The key
  // icon sits in the same gutter, so the two reservations add up.
  readonly property real fingerprintReserve: (fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0)
    + (fido2Configured ? Math.round(fido2Icon.implicitWidth + 12) : 0)
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && acceptsInput && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Commons.Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Commons.Color.lock.borderActive, root.outlineThickness, "border-alpha")

  readonly property bool video: Util.isVideoPath(root.backgroundPath)
  readonly property bool feedActive: root.video && root.loadBackground && !root.displaysBlank && !root.powerSaverActive

  signal submitPassword(string password)
  signal submitFido2Pin(string pin)
  signal passwordTextEdited(string password)
  signal toggleAuthMode()
  signal retryFido2Requested()
  signal clearFailureRequested()
  signal wakeRequested()

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  // Waking a DPMS-blanked display can stall the compositor for seconds while
  // the monitor modesets, so the wake key's release arrives late and client-side
  // key repeat floods the field with that character. A held key has no business
  // typing a password; only holding Backspace/Delete to clear stays useful.
  function dropsAutoRepeat(key) {
    return key !== Qt.Key_Backspace && key !== Qt.Key_Delete
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  // The field is disabled until pam_u2f asks for the PIN, so it has to take
  // focus at the moment the prompt lands or the first digits go nowhere.
  onAcceptsInputChanged: {
    if (acceptsInput && inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background

    BackgroundMedia {
      id: wallpaper
      objectName: "lockWallpaper"
      anchors.fill: parent
      path: root.loadBackground ? (root.video ? root.videoPosterPath : root.backgroundPath) : ""
      version: root.backgroundVersion
      // Decode only once sized, at the lock's own size: an unsized first
      // request decoded the file at its native resolution, then again once
      // sized. That size is what the lock service keeps decoded ahead of the
      // lock, so the first frame has the wallpaper.
      cached: true
      constrainDecode: true
      decodeSize: Qt.size(width, height)
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper
      autoPaddingEnabled: false
      blurEnabled: root.loadBackground && wallpaper.ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }

    // The cached poster stays behind the feed when policy pauses playback,
    // the module is unavailable, or a new connection has not received a frame.
    Loader {
      id: feedLoader
      objectName: "lockFeedLoader"
      anchors.fill: parent
      active: root.feedActive
      source: "LockFeedSurface.qml"
      visible: status === Loader.Ready
    }

    // The feed item cannot be sampled by MultiEffect on every renderer.
    // Keep video wallpapers visible and darken them slightly for legibility.
    Rectangle {
      anchors.fill: feedLoader
      visible: root.video
      color: "#22000000"
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    LockExtras {
      anchors.fill: parent
      info: root.info
      primary: root.primaryScreen
    }

    BorderSurface {
      id: inputField
      // Shown on the main screen only. Elsewhere it stays as an invisible
      // field, because typing goes to whichever screen has focus.
      opacity: root.primaryScreen ? 1 : 0
      width: root.fieldWidth
      height: root.fieldHeight
      anchors.centerIn: parent
      color: Commons.Color.lock.background
      borderSpec: root.inputBorderSpec
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        // Reserve the fingerprint icon's width on both sides so the centered
        // dots stay symmetric and never slide under the icon as they grow.
        anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        // Inert in key mode, but still enabled and focused: a disabled item
        // drops focus, and then the keyboard shortcuts below would have nobody
        // to fire on. readOnly is what actually keeps a PIN out of the void.
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword || !root.acceptsInput
        echoMode: TextInput.Password
        passwordCharacter: "\u25CF"
        passwordMaskDelay: 0
        color: Commons.Color.lock.text
        selectionColor: Commons.Color.lock.selection
        selectedTextColor: Commons.Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Commons.Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText) root.passwordTextEdited(text)
          if (text.length > 0) {
            root.wakeRequested()
          }
          if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
        }

        onAccepted: {
          var submitted = root.passwordText
          root.passwordTextEdited("")
          if (submitted.length === 0) return
          if (root.fido2Active) root.submitFido2Pin(submitted)
          else root.submitPassword(submitted)
        }

        Keys.onPressed: function(event) {
          root.wakeRequested()
          if (event.isAutoRepeat && root.dropsAutoRepeat(event.key)) {
            event.accepted = true
            return
          }
          // Tab moves between factors. The pill under the field says the same
          // thing, but a lock screen is the worst place to need a mouse.
          if (root.fido2Configured && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
            root.toggleAuthMode()
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
            root.passwordTextEdited("")
            event.accepted = true
            return
          }

          if (root.acceptsInput) return

          // The field is inert, so the key is waiting for a touch or for a PIN
          // prompt that has not arrived. Enter asks for another attempt --
          // nothing retries by itself here, because every attempt can cost one
          // of the key's eight PIN retries.
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.retryFido2Requested()
            event.accepted = true
          }

          // Everything else is swallowed by readOnly. Switching to the password
          // on any printable key was tried here and taken back out: waiting for
          // a touch is exactly when a stray keystroke is most likely, and
          // having one silently change the factor under you is worse than
          // reaching for Tab.
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? Commons.I18n.t("lock.checking") : (root.failureMessage.length > 0 ? root.failureMessage : root.placeholderText)
        visible: passwordInput.text.length === 0
        color: root.authenticatingPassword ? Commons.Color.lock.text : (root.failureMessage.length > 0 ? Commons.Color.lock.textError : Commons.Color.lock.placeholder)
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.italic: !root.authenticatingPassword && root.failureMessage.length > 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      // Fingerprint hint pinned inside the field's right edge when a sensor is
      // enrolled, so the user knows they can touch to unlock instead of typing.
      // Matches hyprlock, which draws its fingerprint icon in the same spot.
      // A reader the shell cannot reach crosses out rather than disappears, so
      // it stops inviting touches that can never unlock.
      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: root.fingerprintUnavailable ? "󰺱" : "󰈷"
        color: root.fingerprintUnavailable ? Commons.Color.lock.textError : Commons.Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }

      // Security-key affordance, in the same gutter as the fingerprint hint and
      // using the glyph the Omarchy menu already uses for Setup > Security >
      // Fido2. Lit while the key is the active factor, dimmed when it is merely
      // available, and half-dimmed when the mode is on but no key is plugged in.
      Text {
        textFormat: Text.PlainText
        id: fido2Icon
        objectName: "fido2Indicator"
        anchors.right: fingerprintIcon.visible ? fingerprintIcon.left : parent.right
        anchors.rightMargin: fingerprintIcon.visible ? 12 : inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fido2Configured
        // U+EB11, the key glyph Omarchy's own menu uses for Setup > Security >
        // Fido2. Written as an escape rather than as the literal character: a
        // Private Use Area codepoint survives no round trip through anything
        // that sanitises text, and it went missing exactly that way once.
        text: "\ueb11"
        color: root.fido2Active
          ? (root.fido2TokenPresent ? Color.lock.text : Color.lock.textError)
          : Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter

        MouseArea {
          anchors.fill: parent
          anchors.margins: -8
          cursorShape: Qt.PointingHandCursor
          enabled: root.inputEnabled && root.fido2Configured && root.primaryScreen
          onClicked: {
            root.wakeRequested()
            // Already on the key: the click means "try again", which is the
            // only retry path — the FIDO2 flow never retries by itself,
            // because each attempt can cost one of the key's PIN retries.
            if (root.fido2Active) root.retryFido2Requested()
            else root.toggleAuthMode()
          }
        }
      }
    }

    // Both directions, always on screen whenever a key is enrolled. The way
    // back to the password matters most -- a key that is lost, dead or refusing
    // its PIN must never be the only way into the session -- but the way *to*
    // the key needs to be just as findable, because the glyph inside the field
    // is too quiet to be the only affordance.
    //
    // Drawn on the field's own background rather than as bare text: this sits
    // over a blurred wallpaper of unknown brightness, and placeholder-grey text
    // straight on the image is unreadable against a light one.
    Rectangle {
      id: authModeSwitch

      anchors.top: inputField.bottom
      anchors.topMargin: 20
      anchors.horizontalCenter: inputField.horizontalCenter
      visible: root.fido2Configured && root.inputEnabled && root.primaryScreen

      implicitWidth: authModeLabel.implicitWidth + 32
      implicitHeight: authModeLabel.implicitHeight + 16
      radius: Style.cornerRadius
      color: Color.lock.background
      opacity: authModeSwitchArea.containsMouse ? 1.0 : 0.85

      Behavior on opacity {
        NumberAnimation { duration: 120 }
      }

      Text {
        textFormat: Text.PlainText
        id: authModeLabel
        anchors.centerIn: parent
        text: root.fido2Active ? "Use password instead" : "Use security key instead"
        color: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 0.72)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }

      MouseArea {
        id: authModeSwitchArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.wakeRequested()
          root.toggleAuthMode()
          root.forcePasswordFocus()
        }
      }
    }

    // The crossed-out icon has no meaning to a user who has never seen it — it
    // is not intuitive that it signals a broken reader — so the words carry the
    // explanation and the icon only reinforces it.
    Text {
      objectName: "fingerprintUnavailableNotice"
      textFormat: Text.PlainText
      // Below the key/password switch when that is showing, so they never overlap.
      anchors.top: authModeSwitch.visible ? authModeSwitch.bottom : inputField.bottom
      anchors.topMargin: authModeSwitch.visible ? 12 : 18
      anchors.horizontalCenter: inputField.horizontalCenter
      visible: root.fingerprintConfigured && root.fingerprintUnavailable && root.primaryScreen
      text: Commons.I18n.t("lock.fingerprintUnavailable")
      color: Commons.Color.lock.textError
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.italic: true
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
