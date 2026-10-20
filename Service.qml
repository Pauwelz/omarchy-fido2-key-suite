import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "FingerprintModel.js" as FingerprintModel

Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // Inline settings come from this plugin's own entry in shell.json --
  // `{ "id": "erijl.lock", "defaultMode": "security-key" }` -- which is where
  // the shell puts per-plugin configuration. shellConfig is reassigned on
  // reload, so this re-evaluates when the user edits the file.
  //
  // The bar layout is searched first and the plugins list second, which is the
  // order the shell's own updateEntryInline writes in: once the bar widget is
  // on the bar, that layout entry is the plugin's entry, and settings written
  // from the panel land there. Looking in only one of the two would lose them.
  readonly property var settings: {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    if (!config) return ({})
    var id = manifest && manifest.id ? String(manifest.id) : "erijl.lock"

    var layout = config.bar && config.bar.layout ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var row = layout && Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
      for (var r = 0; r < row.length; r++) {
        if (row[r] && String(row[r].id).split("#")[0] === id) return row[r]
      }
    }

    var entries = Array.isArray(config.plugins) ? config.plugins : []
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] && String(entries[i].id) === id) return entries[i]
    }
    return ({})
  }

  // "auto" starts on the key when one is enrolled and attached, "password"
  // never auto-selects it, "security-key" always does. Anything else is a typo
  // in shell.json and is treated as the default rather than as an instruction.
  readonly property string defaultMode: {
    var mode = String(settings.defaultMode || "auto")
    return ["auto", "password", "security-key"].indexOf(mode) !== -1 ? mode : "auto"
  }

  // Both off by default, so a stock install adds no background work: turning
  // either on is what starts watching for the key while the session is
  // unlocked (see fido2DetectTimer). `=== true` rather than a truthy test --
  // a typo in shell.json should read as "not asked for", not as consent.
  readonly property bool lockOnUnplug: settings.lockOnUnplug === true
  readonly property bool notifyOnKeyChange: settings.notifyOnKeyChange === true
  // Surfaces that show presence -- the bar widget, one instance per monitor --
  // register while they are mounted. Counted rather than flagged so the last
  // one leaving is what stops the watching.
  property int presenceWatchers: 0

  function watchPresence(on) {
    presenceWatchers = Math.max(0, presenceWatchers + (on ? 1 : -1))
  }

  readonly property bool watchesPresence: lockOnUnplug || notifyOnKeyChange || presenceWatchers > 0

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  property int fingerprintUnreachedStreak: 0
  property bool fingerprintAttemptReachedDevice: false
  property bool fingerprintAttemptFastError: false
  property double fingerprintAttemptPromptedAtMs: 0
  property double fingerprintLastNudgeMs: 0
  property double fingerprintLastSettleMs: 0
  property double fingerprintResumedAtMs: 0
  property int fingerprintProbeStreak: 0
  // While the lock has the displays off no new attempt starts, so the reader
  // isn't held awake all night; any wake starts it again.
  property bool fingerprintPaused: false
  // The sleep watch is stopped while paused, so a sleep seen after the
  // pre-suspend lock request is marked here instead.
  property bool fingerprintSleptWhilePaused: false
  // When the armed retry is due, so time spent blank counts toward it.
  property double fingerprintRetryDueMs: 0
  // The backoff the armed retry was set to; a wake shortens the timer to the
  // remaining wait, so the input guard reads the tier from here instead.
  property int fingerprintRetryBackoffMs: 0
  // Outputs the lock last saw, so only a display arriving counts as a wake.
  property int knownScreenCount: 0
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property string videoPosterPath: ""
  property int backgroundVersion: 0
  // The wallpaper file's mtime and size. The lock caches its wallpaper by
  // version, so a file overwritten in place must bump the version too.
  property string backgroundSignature: ""
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool displaysBlank: false
  // displaysBlank tracks what the lock asked for; Hyprland reports what each
  // panel actually did. While a video is on show the two are reconciled, so a
  // blank that failed keeps playing and a panel woken behind the lock's back
  // (a resume that kept the same outputs) resumes instead of freezing.
  property var monitorDpms: ({})
  property bool monitorDpmsKnown: false
  readonly property bool videoBackground: Util.isVideoPath(backgroundPath)
  property bool strandedLock: false
  property bool strandedLockResolved: false

  // FIDO2 is a third, explicitly-chosen flow rather than another `sufficient`
  // line inside omarchy-lock-password. Sharing the password service would
  // forward every mistyped password to the key as a PIN attempt, and a key has
  // only eight of those before it locks itself out and needs a factory reset
  // that destroys every credential on it. Separate services make it impossible
  // to spend a retry unless the user actually asked for the key.
  property string authMode: "password" // "password" | "fido2"
  property bool fido2PamConfigured: false
  property bool fido2Enrolled: false
  property bool fido2TokenPresent: false
  // The first enumeration is an observation, not a change: without this the
  // service would announce "key attached" at every login.
  property bool fido2PresenceKnown: false
  property bool fido2AbsencePending: false
  property bool fido2Authenticating: false
  property bool fido2NeedsPin: false
  property string fido2Status: ""
  property string pendingFido2Pin: ""
  // The factor is picked once per lock, then left alone. Without this the
  // auto-selection would fight the user every time a check re-ran.
  property bool authModeSettled: false

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure

  // Decisions read the lock state afresh. A property binding that missed a change
  // notification once reported locked after an unlock, and a lock request before
  // suspend then took that for done and never locked the session.
  function currentlyLocked() {
    return lockRequested || sessionLock.locked || sessionLock.secure
  }
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating || fido2Authenticating
  readonly property var batteryService: shell && shell.services ? shell.firstPartyServiceFor("omarchy.battery") : null
  readonly property bool powerSaverActive: batteryService ? batteryService.powerSaverOnBattery : false
  // A prompt clears the unavailable notice before the attempt finishes.
  readonly property bool fingerprintUnavailable: FingerprintModel.isUnavailable(fingerprintProbeStreak) || (fingerprintConfigured && (!fingerprintAttemptReachedDevice || fingerprintAttemptFastError) && FingerprintModel.isUnavailable(fingerprintUnreachedStreak))
  readonly property bool fido2Configured: fido2PamConfigured && fido2Enrolled
  readonly property bool fido2Active: authMode === "fido2"

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early may be an orphan behind Hyprland's failsafe. It
  // may also be another shell's live lock, which Hyprland would let this one
  // take over and then strand on exit, so the helper answers undetermined while
  // another locker runs. Outputs are often still absent here, so ask until the
  // answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (currentlyLocked()) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || currentlyLocked() || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshPoster() {
    if (!root.videoBackground) {
      root.videoPosterPath = ""
      return
    }
    if (posterProc.running) return
    posterProc.sourcePath = root.backgroundPath
    posterProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  function refreshFido2Status() {
    if (!fido2CheckProc.running) fido2CheckProc.running = true
  }

  // Presence is polled rather than watched: a key can be plugged in at any
  // point while the screen is locked, and the answer decides whether the UI
  // offers the key or says there is none to offer.
  function refreshFido2Token() {
    if (!fido2DetectProc.running) fido2DetectProc.running = true
  }

  // Called only for a real transition, and only once the first reading is in.
  function announcePresence(present) {
    logEvent(present ? "key-attached" : "key-removed")
    if (!present && lockOnUnplug) lockForUnplug()

    // Deliberately after the lock decision, so `locked` covers both a session
    // that was already locked and one this very removal just locked. A banner
    // raised behind the lock surface is one nobody can read -- it went up
    // 6ms before the lock and was buried by it -- and where the screen locks,
    // the lock screen is the better answer to "where did my key go" anyway.
    // If beginLock refused (no working password service) nothing is locked,
    // and the notification goes out after all.
    if (notifyOnKeyChange && !locked) notifyKeyChange(present)
  }

  function notifyKeyChange(present) {
    notifyProcess.command = ["notify-send", "-u", "low",
      present ? "Security key attached" : "Security key removed",
      present
        ? "The lock screen will offer it."
        : "The lock screen will ask for your password."]
    notifyProcess.running = true
  }

  // Pulling the key out is a request to lock, not to log out: beginLock()
  // refuses without a working password service, which is what keeps this from
  // stranding anyone behind a key they just unplugged.
  function lockForUnplug() {
    if (locked || lockRequested) return
    logEvent("lock-on-unplug")
    beginLock()
  }

  // Pick the factor once per lock: by default the key if one is enrolled and
  // plugged in, the password otherwise. Driven from the check processes rather
  // than from beginLock(), because neither answer is known yet at the moment
  // the lock is requested -- both are subprocesses that have not returned.
  function settleAuthMode() {
    if (authModeSettled || !locked) return
    if (defaultMode === "password") return
    if (!fido2Configured) return
    // "security-key" means start there and say so when nothing is plugged in,
    // rather than quietly landing on the password.
    if (!fido2TokenPresent && defaultMode !== "security-key") return
    if (authenticatingPassword || enteredPassword.length > 0) return

    setAuthMode("fido2")
  }

  function setAuthMode(mode) {
    // Any deliberate choice -- by the user or by settleAuthMode -- ends the
    // auto-selection for this lock. A key plugged in later must never yank the
    // field out from under someone already typing their password.
    authModeSettled = true

    if (authMode === mode) return
    if (mode === "fido2" && !fido2Configured) return

    // Never leave a half-finished conversation behind when switching away.
    if (authMode === "fido2") abortFido2()
    else if (passwordPam.active) passwordPam.abort()

    authMode = mode
    failureMessage = ""
    enteredPassword = ""
    pendingPassword = ""
    logEvent("auth-mode=" + mode)

    if (mode === "fido2") {
      refreshFido2Token()
      startFido2()
    }
  }

  // Only definitive enrollment results may disable authentication.
  function applyFingerprintProbe(text) {
    var status = FingerprintModel.classifyProbe(text)
    if (status === "unknown") {
      if (fingerprintConfigured) return
      fingerprintProbeStreak += 1
      if (lockRequested) {
        fingerprintRecheckTimer.interval = FingerprintModel.retryDelayMs(fingerprintProbeStreak)
        fingerprintRecheckTimer.restart()
      }
      return
    }
    fingerprintProbeStreak = 0
    fingerprintRecheckTimer.stop()
    fingerprintConfigured = status === "yes"
    if (lockRequested && fingerprintConfigured) {
      // A pending retry already owns the next attempt.
      if (!fingerprintRetryTimer.running) startFingerprint()
    } else if (!fingerprintConfigured) {
      // abort() delivers no completion signal, so close the attempt here
      // too; settle returns before arming a retry while unconfigured.
      if (fingerprintPam.active) fingerprintPam.abort()
      settleFingerprintAttempt()
      fingerprintRetryTimer.stop()
    }
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("omarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    authenticatingPassword = false
    fingerprintAuthenticating = false
    fingerprintUnreachedStreak = 0
    fingerprintAttemptFastError = false
    fingerprintAttemptPromptedAtMs = 0
    fingerprintLastNudgeMs = 0
    fingerprintLastSettleMs = 0
    fingerprintResumedAtMs = 0
    fingerprintProbeStreak = 0
    fingerprintPaused = false
    fingerprintSleptWhilePaused = false
    fingerprintRecheckTimer.stop()
    fingerprintRetryTimer.stop()
    fingerprintReachTimer.stop()
    fingerprintResumeTimer.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
    abortFido2()
    authMode = "password"
    authModeSettled = false
  }

  function abortFido2() {
    fido2Authenticating = false
    fido2NeedsPin = false
    fido2Status = ""
    pendingFido2Pin = ""
    if (fido2Pam.active) fido2Pam.abort()
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    lockRequested = true
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFido2Status()
      root.refreshFido2Token()
    })

    return true
  }

  function finishUnlock() {
    if (!root.currentlyLocked()) return

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    sessionLock.locked = false
    logEvent("unlocked")
    runWake()
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now()
    idleBlankTimer.restart()
  }

  function runWake() {
    root.displaysBlank = false
    root.monitorDpmsKnown = false
    if (!wakeProcess.running) wakeProcess.running = true
    if (lockRequested) armBlankTimer()
    resumeFingerprint()
    nudgeFingerprint()
  }

  // An attempt already running is left to finish under its own timeouts, so
  // a slow claim still completes; only the next one waits for a wake.
  function pauseFingerprint() {
    if (fingerprintPaused) return
    fingerprintPaused = true
    fingerprintRetryTimer.stop()
  }

  // The retry keeps whatever backoff was armed, counting the time spent blank,
  // so a failing reader still gets its idle window; after a sleep it recovers
  // at once, as the sleep watch does.
  function resumeFingerprint() {
    if (!fingerprintPaused) return
    fingerprintPaused = false
    if (fingerprintSleptWhilePaused) {
      fingerprintSleptWhilePaused = false
      noteFingerprintResumed()
      fingerprintRetryBackoffMs = FingerprintModel.MATCH_RETRY_MS
      fingerprintRetryTimer.interval = FingerprintModel.MATCH_RETRY_MS
    } else {
      fingerprintRetryTimer.interval = Math.max(FingerprintModel.MATCH_RETRY_MS, fingerprintRetryDueMs - Date.now())
    }
    if (lockRequested && fingerprintConfigured && !fingerprintAuthenticating) fingerprintRetryTimer.restart()
  }

  // A resume can light the panel with no input to wake the lock, so after a
  // lock request the reader comes back once a sleep is seen; the blank
  // countdown then pauses it again if nothing else happens. The idle service
  // repeats the same request without sleeping, so the sleep has to be seen.
  function noteSleepRequested() {
    if (!lockRequested || !fingerprintPaused) return
    // logind holds a suspend for its inhibitor delay, at most 15 seconds here.
    fingerprintResumeTimer.ticksLeft = 20
    fingerprintResumeTimer.lastTickMs = Date.now()
    fingerprintResumeTimer.restart()
  }

  // User activity advances retries without recreating a busy retry loop.
  function nudgeFingerprint() {
    if (!lockRequested) return
    if (!fingerprintConfigured && fingerprintRecheckTimer.running) {
      var now = Date.now()
      if (FingerprintModel.shouldNudge(now, fingerprintLastNudgeMs, now - FingerprintModel.IDLE_CLEAR_MS, fingerprintRecheckTimer.interval)) {
        fingerprintLastNudgeMs = now
        fingerprintRecheckTimer.interval = FingerprintModel.MATCH_RETRY_MS
        fingerprintRecheckTimer.restart()
      }
      return
    }
    if (!fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return
    if (!fingerprintRetryTimer.running) return
    var now = Date.now()
    if (!FingerprintModel.shouldNudge(now, fingerprintLastNudgeMs, fingerprintLastSettleMs, fingerprintRetryBackoffMs)) return
    fingerprintLastNudgeMs = now
    armFingerprintRetry(FingerprintModel.MATCH_RETRY_MS)
  }


  function armFingerprintRetry(delayMs) {
    fingerprintRetryTimer.interval = delayMs
    fingerprintRetryBackoffMs = delayMs
    fingerprintRetryDueMs = Date.now() + delayMs
    if (!fingerprintPaused) fingerprintRetryTimer.restart()
  }

  // Reset pre-sleep failures while the resume hook restarts fprintd.
  function noteFingerprintResumed() {
    var now = Date.now()
    if (FingerprintModel.inResumeGrace(now, fingerprintResumedAtMs)) return
    logEvent("fingerprint-resume: streak=" + fingerprintUnreachedStreak)
    fingerprintResumedAtMs = now
    fingerprintUnreachedStreak = 0
  }

  // A suspended PAM conversation may be orphaned by the daemon restart.
  function restartFingerprintAfterSleep() {
    noteFingerprintResumed()
    if (fingerprintAuthenticating || fingerprintPam.active) {
      if (fingerprintPam.active) fingerprintPam.abort()
      settleFingerprintAttempt()
      return
    }
    if (!fingerprintRetryTimer.running) return
    armFingerprintRetry(FingerprintModel.MATCH_RETRY_MS)
  }

  function runBlank() {
    root.displaysBlank = true
    root.monitorDpmsKnown = false
    pauseFingerprint()
    if (!blankProcess.running) blankProcess.running = true
  }

  function screenBlank(screenName) {
    var name = String(screenName || "")
    if (!monitorDpmsKnown || !(name in monitorDpms)) return displaysBlank
    return !monitorDpms[name]
  }

  function applyMonitorDpms(text) {
    var monitors
    try {
      monitors = JSON.parse(String(text || ""))
    } catch (error) {
      return
    }
    if (!Array.isArray(monitors)) return

    var dpms = {}
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      if (monitor && monitor.name && !monitor.disabled) dpms[String(monitor.name)] = !!monitor.dpmsStatus
    }
    monitorDpms = dpms
    monitorDpmsKnown = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
    passwordPam.respond(pendingPassword)
  }

  function handlePasswordFailure() {
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = I18n.t("lock.authenticationFailed").arg(I18n.formatNumber(failedAttempts))
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured || fingerprintPaused) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    fingerprintAttemptReachedDevice = false
    fingerprintAttemptFastError = false
    fingerprintAttemptPromptedAtMs = 0
    if (!fingerprintPam.start()) {
      // Pace a failed start while checking whether its PAM configuration was
      // removed; a definitive "no" stops retries and hides the indicator.
      settleFingerprintAttempt()
      refreshFingerprintStatus()
      return
    }
    // Bound claims that never prompt; a normal verify waits for a finger
    // under pam_fprintd's own timeout after reaching the reader.
    fingerprintReachTimer.restart()
  }

  // A prompt proves the claim landed, so stop waiting for reachability.
  function noteFingerprintReachedDevice() {
    if (fingerprintAttemptReachedDevice) return
    fingerprintAttemptReachedDevice = true
    fingerprintAttemptPromptedAtMs = Date.now()
    fingerprintReachTimer.stop()
  }

  // abort() gives no completion signal; settle the attempt here.
  function timeoutFingerprintReach() {
    logEvent("fingerprint-reach-timeout")
    if (fingerprintPam.active) fingerprintPam.abort()
    settleFingerprintAttempt()
  }

  // onError and onCompleted can both fire; settle each attempt once.
  function settleFingerprintAttempt(deviceError) {
    if (!fingerprintAuthenticating) return
    fingerprintAuthenticating = false
    fingerprintReachTimer.stop()
    if (!lockRequested || !fingerprintConfigured) return

    // An error can arrive before the sleep watcher notices the wall-clock gap.
    var now = Date.now()
    fingerprintAttemptFastError = !!deviceError && fingerprintAttemptReachedDevice && now - fingerprintAttemptPromptedAtMs < FingerprintModel.FAST_ERROR_MS
    var usableAttempt = fingerprintAttemptReachedDevice && !fingerprintAttemptFastError
    if (!usableAttempt && fingerprintSleepWatch.running
        && FingerprintModel.spannedSleep(now - fingerprintSleepWatch.lastTickMs, fingerprintSleepWatch.interval)) {
      noteFingerprintResumed()
    }

    // Reached attempts are the steady state (one per swipe window), so only
    // the misses and the recovery from them leave a trace.
    var previousStreak = fingerprintUnreachedStreak
    var inGrace = FingerprintModel.inResumeGrace(now, fingerprintResumedAtMs)
    fingerprintUnreachedStreak = FingerprintModel.nextStreak(previousStreak, usableAttempt, inGrace)
    if (!usableAttempt) {
      var crossed = !FingerprintModel.isUnavailable(previousStreak) && FingerprintModel.isUnavailable(fingerprintUnreachedStreak)
      logEvent((crossed ? "fingerprint-unavailable" : "fingerprint-unreached") + ": streak=" + fingerprintUnreachedStreak)
    } else if (previousStreak > 0) {
      logEvent("fingerprint-recovered: streak=" + previousStreak)
    }
    fingerprintLastSettleMs = now
    armFingerprintRetry(FingerprintModel.retryDelayMs(fingerprintUnreachedStreak))
  }

  function handleFingerprintFinished(result) {
    if (result === PamResult.Success && lockRequested) {
      // A match after a run of misses is the recovery too; the unlock resets
      // the streak without settling, so log it here or it leaves no trace.
      if (fingerprintUnreachedStreak > 0) logEvent("fingerprint-recovered: streak=" + fingerprintUnreachedStreak)
      finishUnlock()
    } else {
      settleFingerprintAttempt(result === PamResult.Error)
    }
  }

  function startFido2() {
    // Wait for the lock surface, exactly as startFingerprint does. Beginning a
    // conversation that can succeed before the screen is actually up would let
    // finishUnlock fire against a lock that never became secure.
    if (!lockRequested || !sessionLock.secure) return
    if (!fido2Active || !fido2Configured) return
    if (fido2Pam.active || fido2Authenticating) return
    if (!fido2TokenPresent) {
      fido2Status = "No security key detected"
      return
    }

    runWake()
    fido2NeedsPin = false
    pendingFido2Pin = ""
    fido2Status = "Waiting for your key…"
    fido2Authenticating = true

    if (!fido2Pam.start()) {
      fido2Authenticating = false
      fido2Status = "Could not start the key"
    }
  }

  // pam_u2f drives the conversation: it asks for the PIN with a prompt that
  // requires a response, and announces the touch with an informational message
  // that does not. Rendering whichever arrives keeps the UI honest without
  // hardcoding the module's wording or its ordering.
  function handleFido2Message() {
    if (!fido2Authenticating) return
    runWake()

    var text = String(fido2Pam.message || "")

    if (fido2Pam.responseRequired) {
      fido2NeedsPin = true
      fido2Status = text.length > 0 ? text : "Enter your security key PIN"
      // A PIN typed before the prompt arrived is still valid; send it now
      // rather than making the user type it twice.
      if (pendingFido2Pin.length > 0) submitFido2Pin(pendingFido2Pin)
      return
    }

    fido2NeedsPin = false
    if (text.length > 0) fido2Status = text
  }

  function submitFido2Pin(pin) {
    var value = String(pin || "")
    if (!fido2Active || value.length === 0) return

    pendingFido2Pin = value
    if (!fido2Pam.active || !fido2Pam.responseRequired) return

    fido2Pam.respond(value)
    pendingFido2Pin = ""
    fido2NeedsPin = false
    enteredPassword = ""
    fido2Status = "Checking…"
  }

  function handleFido2Finished(result) {
    fido2Authenticating = false
    fido2NeedsPin = false
    pendingFido2Pin = ""
    enteredPassword = ""

    if (!lockRequested) return
    if (result === PamResult.Success) {
      finishUnlock()
      return
    }

    // Deliberately no auto-retry, unlike the fingerprint flow. Every failed
    // attempt here may have cost one of the key's PIN retries, so restarting
    // is the user's call.
    failedAttempts += 1
    failureMessage = "Security key failed (" + failedAttempts + ")"
    fido2Status = ""
    runWake()
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.startFingerprint()
        root.startFido2()
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      // Right-to-left languages read this window mirrored.
      Binding { target: lockSurface.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
      Binding { target: lockSurface.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

      color: Commons.Color.background

      LockView {
        id: lockView
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        videoPosterPath: root.videoPosterPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured || root.fingerprintUnavailable
        fingerprintUnavailable: root.fingerprintUnavailable
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested
        loadBackground: root.locked
        displaysBlank: root.screenBlank(lockSurface.screen ? lockSurface.screen.name : "")
        powerSaverActive: root.powerSaverActive
        passwordText: root.enteredPassword
        fido2Configured: root.fido2Configured
        fido2Active: root.fido2Active
        fido2TokenPresent: root.fido2TokenPresent
        fido2NeedsPin: root.fido2NeedsPin
        fido2Status: root.fido2Status
        fido2Authenticating: root.fido2Authenticating
        onPasswordTextEdited: function(password) { root.enteredPassword = password }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onSubmitFido2Pin: function(pin) { root.submitFido2Pin(pin) }
        onToggleAuthMode: root.setAuthMode(root.fido2Active ? "password" : "fido2")
        onRetryFido2Requested: root.startFido2()
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    // Right-to-left languages read this window mirrored.
    Binding { target: previewWindow.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
    Binding { target: previewWindow.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.backgroundPath
      videoPosterPath: root.videoPosterPath
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured || root.fingerprintUnavailable
      fingerprintUnavailable: root.fingerprintUnavailable
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      powerSaverActive: root.powerSaverActive
      passwordText: ""
      fido2Configured: root.fido2Configured
      fido2TokenPresent: root.fido2TokenPresent
      // The preview is meant to show what the lock screen will look like, and
      // for someone with a key enrolled and attached that is key mode. It is
      // an illustration, not the state machine: nothing here settles authMode
      // or starts a PAM conversation, so previewing never touches the key.
      fido2Active: root.fido2Configured && root.fido2TokenPresent && root.defaultMode !== "password"
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onPamMessage: {
      if (!messageIsError) root.noteFingerprintReachedDevice()
    }

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.settleFingerprintAttempt(true)
    }
  }

  // The lock only starts decoding its wallpaper once locked, and a machine
  // suspending right after locking froze that decode partway: waking showed
  // the password field on a bare background, then the wallpaper popped in.
  // Keep each screen's lock wallpaper decoded in the image cache ahead of
  // time, as the lock view requests it (same URL, the screen's logical size,
  // PreserveAspectCrop), so the lock draws it on its first frame.
  readonly property string lockWallpaperPath: videoBackground ? videoPosterPath : backgroundPath
  readonly property string lockWallpaperUrl: lockWallpaperPath && !Util.isVideoPath(lockWallpaperPath)
    ? Util.fileUrl(lockWallpaperPath) + (backgroundVersion ? "?v=" + backgroundVersion : "")
    : ""

  Variants {
    model: Quickshell.screens

    Image {
      required property var modelData
      visible: false
      source: root.lockWallpaperUrl
      sourceSize.width: modelData.width
      sourceSize.height: modelData.height
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
    }
  }

  PamContext {
    id: fido2Pam
    config: "omarchy-lock-fido2"
    user: root.userName

    onResponseRequiredChanged: root.handleFido2Message()
    onPamMessage: root.handleFido2Message()

    onCompleted: function(result) {
      root.handleFido2Finished(result)
    }

    onError: function(error) {
      root.handleFido2Finished(PamResult.Error)
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: FingerprintModel.MATCH_RETRY_MS
    repeat: false
    onTriggered: root.startFingerprint()
  }

  // While the key is being offered on the lock screen -- a key plugged in
  // mid-lock should light the UI up -- and while the session is unlocked only
  // if the user asked for something that depends on presence. Polling a
  // hidraw enumeration forever behind a password prompt nobody is looking at
  // is pure waste, and so is polling for a feature nobody turned on.
  Timer {
    id: fido2DetectTimer
    interval: 2000
    repeat: true
    running: root.fido2Configured && (root.locked || root.watchesPresence)
    onTriggered: root.refreshFido2Token()
  }

  // A single missed enumeration is not an unplug. A key busy answering
  // another process -- an enrollment running in a terminal -- can fail to
  // answer, and with lockOnUnplug on that would lock the screen under a user
  // who is halfway through a PIN. A disappearance counts once it is seen
  // twice.
  Timer {
    id: fido2AbsenceConfirmTimer
    interval: 700
    repeat: false
    onTriggered: root.refreshFido2Token()
  }

  // ---- bounds on external commands ----------------------------------------
  //
  // Every command below either talks to a USB device or to a system service
  // over DBus, and both can stop answering. The readings here drive a poll, so
  // an unbounded call is not a slow refresh -- it is presence detection that
  // silently stops working for the rest of the session. Each one therefore
  // gets a deadline, and each collected stream a ceiling, so no StdioCollector
  // can grow past a known size regardless of what the child emits.
  readonly property int commandDeadlineSeconds: 5
  readonly property int commandOutputLimit: 4096

  // `bash -c '<script>' <name> <args...>` -- $0 is the name, so the deadline
  // and the ceiling arrive as $1 and $2 rather than being spliced into the
  // script text.
  function boundedCommand(script) {
    return ["bash", "-c",
            "timeout -k 2 \"$1\" bash -c \"$3\" bounded \"${@:4}\" 2>/dev/null | head -c \"$2\"",
            "omarchy-fido2-bounded",
            String(root.commandDeadlineSeconds),
            String(root.commandOutputLimit),
            script]
  }

  Process {
    id: notifyProcess
  }

  // Detect resume both during an active attempt and during backoff.
  Timer {
    id: fingerprintSleepWatch
    interval: 1000
    repeat: true
    running: root.lockRequested && root.fingerprintConfigured && (!root.fingerprintPaused || root.fingerprintAuthenticating)
    property double lastTickMs: 0
    onRunningChanged: lastTickMs = Date.now()
    onTriggered: {
      var now = Date.now()
      var slept = FingerprintModel.spannedSleep(now - lastTickMs, interval)
      lastTickMs = now
      if (slept) root.restartFingerprintAfterSleep()
    }
  }

  // Timers stand still through a suspend, so the first tick after a resume
  // sees the wall clock jump. Runs only for the seconds after a lock request
  // that a suspend can take to begin.
  Timer {
    id: fingerprintResumeTimer
    interval: 1000
    repeat: true
    property int ticksLeft: 0
    property double lastTickMs: 0
    onTriggered: {
      var now = Date.now()
      var slept = FingerprintModel.spannedSleep(now - lastTickMs, interval)
      lastTickMs = now
      if (slept && root.lockRequested && root.fingerprintPaused) {
        stop()
        root.fingerprintSleptWhilePaused = true
        root.resumeFingerprint()
        root.armBlankTimer()
      } else if (slept || !root.fingerprintPaused || --ticksLeft <= 0) {
        stop()
      }
    }
  }

  Timer {
    id: fingerprintReachTimer
    interval: FingerprintModel.REACH_TIMEOUT_MS
    repeat: false
    onTriggered: root.timeoutFingerprintReach()
  }

  Process {
    id: readlinkProc
    command: root.boundedCommand("path=$(readlink -f -- \"$1\") && printf '%s\\n%s\\n' \"$path\" \"$(stat -Lc %Y:%s -- \"$path\" 2>/dev/null)\"").concat([root.currentBackgroundLink])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var next = String(lines[0] || "").trim()
        var signature = String(lines[1] || "").trim()
        if (next !== root.backgroundPath) {
          root.videoPosterPath = ""
          root.backgroundPath = next
          root.backgroundSignature = signature
          root.backgroundVersion += 1
        } else if (signature !== root.backgroundSignature) {
          root.backgroundSignature = signature
          root.backgroundVersion += 1
        }
        root.refreshPoster()
      }
    }
  }

  Process {
    id: posterProc
    property string sourcePath: ""
    command: ["bash", Quickshell.env("OMARCHY_PATH") + "/shell/plugins/lock/poster.sh", sourcePath]
    stdout: StdioCollector { id: posterOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (sourcePath !== root.backgroundPath) {
        root.refreshPoster()
      } else {
        root.videoPosterPath = exitCode === 0 ? String(posterOutput.text || "").trim() : ""
      }
    }
  }

  // Keep fprintd errors distinguishable from an explicit empty enrollment.
  Process {
    id: fingerprintCheckProc
    // fprintd-list is a DBus round trip to a service that can be wedged.
    command: root.boundedCommand("if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1; then LC_ALL=C fprintd-list \"$USER\" 2>&1; else echo no; fi")
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: root.applyFingerprintProbe(fingerprintCheckStdout.text)
  }

  // Retries a probe that could not reach fprintd, paced like the attempt
  // retries so a daemon that stays unreachable is asked about ever less often.
  Timer {
    id: fingerprintRecheckTimer
    interval: FingerprintModel.ERROR_RETRY_BASE_MS
    repeat: false
    onTriggered: root.refreshFingerprintStatus()
  }

  // Enrollment is read straight from the mapping file rather than by shelling
  // out to a helper, so the lock screen keeps working even where none is
  // installed. The file is world-readable by design (it holds a credential id
  // and a public key), which is what lets this run as the user.
  //
  // The two halves are reported separately -- "pam" without "enrolled" is a
  // wired-up service with no credential, the reverse is a credential with no
  // service -- because "it does not offer the key" is otherwise unanswerable
  // from `omarchy-shell lock status` alone.
  Process {
    id: fido2CheckProc
    command: root.boundedCommand(
      "pam=no; enrolled=no; "
      + "[[ -f /etc/pam.d/omarchy-lock-fido2 ]] && pam=yes; "
      + "grep -q \"^$USER:\" /etc/fido2/fido2 2>/dev/null && enrolled=yes; "
      + "echo \"$pam $enrolled\"")
    stdout: StdioCollector { id: fido2CheckStdout; waitForEnd: true }
    onExited: {
      var answer = String(fido2CheckStdout.text || "").trim().split(/\s+/)
      root.fido2PamConfigured = answer[0] === "yes"
      root.fido2Enrolled = answer[1] === "yes"
      if (!root.fido2Configured && root.fido2Active) root.setAuthMode("password")
      else root.settleAuthMode()
    }
  }

  Process {
    id: fido2DetectProc
    // The hot one: this runs every two seconds while the key matters, and it
    // is the call a wedged authenticator blocks.
    command: root.boundedCommand("fido2-token -L 2>/dev/null | grep -q . && echo yes || echo no")
    stdout: StdioCollector { id: fido2DetectStdout; waitForEnd: true }
    onExited: {
      var present = String(fido2DetectStdout.text || "").trim() === "yes"

      if (!present && root.fido2TokenPresent && !root.fido2AbsencePending) {
        root.fido2AbsencePending = true
        fido2AbsenceConfirmTimer.restart()
        return
      }
      root.fido2AbsencePending = false

      if (root.fido2PresenceKnown && present !== root.fido2TokenPresent) root.announcePresence(present)
      root.fido2TokenPresent = present
      root.fido2PresenceKnown = true

      if (!present) {
        if (root.fido2Active) {
          root.abortFido2()
          root.fido2Status = "No security key detected"
        }
        return
      }

      if (!root.locked || !root.fido2Configured) return

      // Already on the key: pick the conversation up now that one is attached.
      // Otherwise let settleAuthMode decide, which covers both a key present at
      // lock time and one plugged in later.
      if (root.fido2Active) {
        if (!root.fido2Authenticating) root.startFido2()
      } else {
        root.settleAuthMode()
      }
    }
  }

  Process {
    id: strandedLockCheckProc
    // $PPID is this shell: a crash re-execs in place, so its pid is the one to skip.
    // timeout runs inside bash so $PPID stays the shell, not timeout.
    command: ["bash", "-c", "timeout -k 2 10 omarchy-hyprland-session-lock-stranded \"$PPID\""]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.currentlyLocked()
      root.recoverStrandedLock()
    }
  }

  Process {
    id: wakeProcess
    command: ["timeout", "-k", "2", "10", "bash", "-c", "omarchy-system-wake"]
  }

  Process {
    id: blankProcess
    command: ["timeout", "-k", "2", "10", "bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  // Quickshell exposes no DPMS signal, so the panel state is polled while a
  // video is the locked wallpaper. A wake or blank request drops the last
  // answer, so its optimistic state applies until the next poll confirms it.
  Process {
    id: monitorDpmsProcess
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      onStreamFinished: root.applyMonitorDpms(text)
    }
  }

  Timer {
    id: monitorDpmsTimer
    interval: 3000
    repeat: true
    triggeredOnStart: true
    running: root.locked && root.videoBackground
    onTriggered: {
      if (!monitorDpmsProcess.running) monitorDpmsProcess.running = true
    }
    onRunningChanged: {
      if (!running) root.monitorDpmsKnown = false
    }
  }

  Timer {
    id: idleBlankTimer
    interval: 5000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Only a password check in flight should hold the display up. The
      // fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` here would keep the panel lit until unlock.
      if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      // A panel coming back is a display turning on that runWake did not ask
      // for, so the blank state has to be given up here or a visible lock
      // wallpaper stays frozen until the next keypress.
      root.displaysBlank = false
      var screens = root.realScreenCount()
      if (screens > root.knownScreenCount) {
        root.resumeFingerprint()
        if (root.lockRequested) root.armBlankTimer()
      }
      root.knownScreenCount = screens
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  // Enrolling or removing a key rewires PAM, so re-ask instead of trusting an
  // answer taken at shell start.
  FileView {
    path: "/etc/fido2/fido2"
    watchChanges: true
    printErrors: false
    onLoaded: root.refreshFido2Status()
    onLoadFailed: {
      root.fido2Enrolled = false
      if (root.fido2Active) root.setAuthMode("password")
    }
    onFileChanged: reload()
  }

  // Watched for the same reason, and so that running `omarchy-fido2-suite setup`
  // takes effect on the running shell rather than at the next restart.
  FileView {
    path: "/etc/pam.d/omarchy-lock-fido2"
    watchChanges: true
    printErrors: false
    onLoaded: root.refreshFido2Status()
    onLoadFailed: {
      root.fido2PamConfigured = false
      if (root.fido2Active) root.setAuthMode("password")
    }
    onFileChanged: reload()
  }

  Component.onCompleted: {
    knownScreenCount = realScreenCount()
    refreshBackground()
    refreshFingerprintStatus()
    refreshFido2Status()
    refreshFido2Token()
    checkStrandedLock()
  }

  ShellIpc {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      // omarchy-system-sleep-lock asks for the lock before every suspend.
      if (root.currentlyLocked()) root.noteSleepRequested()
      if (!root.currentlyLocked() && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.currentlyLocked() ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.currentlyLocked(),
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        fido2: root.fido2Configured,
        fido2Pam: root.fido2PamConfigured,
        fido2Enrolled: root.fido2Enrolled,
        fido2Token: root.fido2TokenPresent,
        lockOnUnplug: root.lockOnUnplug,
        notifyOnKeyChange: root.notifyOnKeyChange,
        presenceWatchers: root.presenceWatchers,
        authMode: root.authMode,
        authModeSettled: root.authModeSettled,
        defaultMode: root.defaultMode,
        fingerprintUnavailable: root.fingerprintUnavailable,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    function preview(): string {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFido2Status()
      root.refreshFido2Token()
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }
}
