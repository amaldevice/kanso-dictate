import KansoCore

func runHUDStateMachineTests() {
    testBasicShowDismissHideLifecycle()
    testRapidIdleRecordingIdleRecordingDuringFadeOut()
    testErrorCountdownAutoDismissLifecycle()
    testErrorToRecordingCancelsAutoDismiss()
    testErrorToIdleCancelsAutoDismiss()
    testSuccessiveErrorsInvalidatePriorTimeout()
}

private func testBasicShowDismissHideLifecycle() {
    var sm = HUDPresentationStateMachine()
    assert(sm.state == .hidden, "Initial HUD state must be .hidden")

    // Idle while already hidden is a no-op
    let idleActions = sm.handle(.dictationStateChanged(.idle))
    assert(sm.state == .hidden, "Idle from hidden must stay .hidden")
    assert(idleActions.isEmpty, "Idle from hidden must emit no actions")

    // Recording from hidden fades in and enters .showing
    let showActions = sm.handle(.dictationStateChanged(.recording))
    assert(sm.state == .showing, "Recording from hidden must transition to .showing")
    assert(showActions == [.showPanel(fadeIn: true)], "Must fade in panel from hidden")

    // Transcribing and inserting while showing keep .showing without fading in from 0
    let transcribeActions = sm.handle(.dictationStateChanged(.transcribing))
    assert(sm.state == .showing, "Transcribing must stay .showing")
    assert(transcribeActions == [.showPanel(fadeIn: false)], "Must not re-fade from 0 while showing")

    let insertActions = sm.handle(.dictationStateChanged(.inserting))
    assert(sm.state == .showing, "Inserting must stay .showing")
    assert(insertActions == [.showPanel(fadeIn: false)], "Must not re-fade from 0 while showing")

    // Idle from showing begins fade-out and enters .dismissing
    let dismissActions = sm.handle(.dictationStateChanged(.idle))
    assert(sm.state == .dismissing, "Idle from showing must transition to .dismissing")
    guard case .beginFadeOut(let gen) = dismissActions.first, dismissActions.count == 1 else {
        assertionFailure("Expected single beginFadeOut action, got \(dismissActions)")
        return
    }

    // Matching fade-out completion hides panel and enters .hidden
    let hideActions = sm.handle(.fadeOutCompleted(generation: gen))
    assert(sm.state == .hidden, "fadeOutCompleted must transition to .hidden")
    assert(hideActions == [.hidePanel], "fadeOutCompleted must emit .hidePanel")

    print("✔ HUD basic show/dismiss/hide lifecycle verified")
}

private func testRapidIdleRecordingIdleRecordingDuringFadeOut() {
    var sm = HUDPresentationStateMachine()

    // idle -> recording
    _ = sm.handle(.dictationStateChanged(.recording))
    assert(sm.state == .showing, "Must be .showing after recording")

    // recording -> idle (starts fade-out with gen1)
    let dismissActions1 = sm.handle(.dictationStateChanged(.idle))
    assert(sm.state == .dismissing, "Must be .dismissing after idle")
    guard case .beginFadeOut(let gen1) = dismissActions1.first, dismissActions1.count == 1 else {
        assertionFailure("Expected beginFadeOut on first idle, got \(dismissActions1)")
        return
    }

    // idle -> recording while still .dismissing (before fade-out finishes)
    let resumeActions = sm.handle(.dictationStateChanged(.recording))
    assert(sm.state == .showing, "Recording during fade-out must restore .showing")
    assert(
        resumeActions == [.showPanel(fadeIn: false)],
        "Resuming during fade-out must restore full visibility/opacity without resetting alpha to 0"
    )

    // Stale fade-out completion from gen1 arrives late and MUST be ignored
    let staleHideActions = sm.handle(.fadeOutCompleted(generation: gen1))
    assert(sm.state == .showing, "Stale fadeOutCompleted must not leave .showing")
    assert(staleHideActions.isEmpty, "Stale fadeOutCompleted must never hide an active HUD")

    // Second idle starts a new fade-out with a new generation
    let dismissActions2 = sm.handle(.dictationStateChanged(.idle))
    assert(sm.state == .dismissing, "Second idle must enter .dismissing")
    guard case .beginFadeOut(let gen2) = dismissActions2.first, dismissActions2.count == 1 else {
        assertionFailure("Expected beginFadeOut on second idle, got \(dismissActions2)")
        return
    }
    assert(gen2 != gen1, "New fade-out generation must differ from cancelled fade-out")

    // Completion of gen2 hides the panel
    let finalHide = sm.handle(.fadeOutCompleted(generation: gen2))
    assert(sm.state == .hidden, "Current fade-out completion must enter .hidden")
    assert(finalHide == [.hidePanel], "Current fade-out completion must hide panel")

    print("✔ HUD rapid idle -> recording -> idle -> recording during fade-out verified")
}

private func testErrorCountdownAutoDismissLifecycle() {
    var sm = HUDPresentationStateMachine()

    // Error directly from hidden must restore opacity (fadeIn: true) and schedule countdown
    let errorActions = sm.handle(.dictationStateChanged(.error("Mic unavailable")))
    assert(sm.state == .errorCountdown, "Error must enter .errorCountdown")
    assert(errorActions.count == 2, "Expected showPanel + scheduleErrorDismiss, got \(errorActions)")
    assert(errorActions[0] == .showPanel(fadeIn: true), "Error from hidden must show panel")
    guard case .scheduleErrorDismiss(let gen1) = errorActions[1] else {
        assertionFailure("Expected scheduleErrorDismiss, got \(errorActions)")
        return
    }

    // Timeout fires -> begins fade-out
    let timeoutActions = sm.handle(.errorTimeoutFired(generation: gen1))
    assert(sm.state == .dismissing, "Error timeout must enter .dismissing")
    guard case .beginFadeOut(let fadeGen) = timeoutActions.first, timeoutActions.count == 1 else {
        assertionFailure("Expected beginFadeOut on error timeout, got \(timeoutActions)")
        return
    }

    // User starts recording during error's fade-out -> cancels fade-out and restores visibility
    let resumeActions = sm.handle(.dictationStateChanged(.recording))
    assert(sm.state == .showing, "Recording during error fade-out must enter .showing")
    assert(resumeActions == [.showPanel(fadeIn: false)], "Must restore panel visibility/opacity")

    let staleFade = sm.handle(.fadeOutCompleted(generation: fadeGen))
    assert(sm.state == .showing, "Stale error fade-out must not hide active recording")
    assert(staleFade.isEmpty, "Stale error fade-out must emit no actions")

    print("✔ HUD error countdown auto-dismiss lifecycle verified")
}

private func testErrorToRecordingCancelsAutoDismiss() {
    var sm = HUDPresentationStateMachine()

    _ = sm.handle(.dictationStateChanged(.recording))
    let errorActions = sm.handle(.dictationStateChanged(.error("Transcription failed")))
    assert(sm.state == .errorCountdown, "Must enter .errorCountdown from .showing")
    assert(errorActions.count == 2, "Expected showPanel + scheduleErrorDismiss, got \(errorActions)")
    assert(errorActions[0] == .showPanel(fadeIn: false), "From showing, panel is already visible")
    guard case .scheduleErrorDismiss(let errorGen) = errorActions[1] else {
        assertionFailure("Expected scheduleErrorDismiss, got \(errorActions)")
        return
    }

    // Transition straight from error -> recording before 3s timeout
    let recActions = sm.handle(.dictationStateChanged(.recording))
    assert(sm.state == .showing, "error -> recording must transition to .showing")
    assert(
        recActions == [.cancelErrorDismiss, .showPanel(fadeIn: false)],
        "error -> recording must cancel error timer and restore full visibility/opacity"
    )

    // Even if an already-dispatched timer callback races in, stale generation must be ignored
    let staleTimeout = sm.handle(.errorTimeoutFired(generation: errorGen))
    assert(sm.state == .showing, "Stale error timeout must not affect .showing")
    assert(staleTimeout.isEmpty, "Stale error timeout must emit no actions")

    print("✔ HUD error -> recording cancels auto-dismiss verified")
}

private func testErrorToIdleCancelsAutoDismiss() {
    var sm = HUDPresentationStateMachine()

    let errActions = sm.handle(.dictationStateChanged(.error("Failure")))
    guard case .scheduleErrorDismiss(let errorGen) = errActions.last else {
        assertionFailure("Expected scheduleErrorDismiss, got \(errActions)")
        return
    }

    // Leaving error state to idle cancels auto-dismiss and fades out immediately
    let idleActions = sm.handle(.dictationStateChanged(.idle))
    assert(sm.state == .dismissing, "error -> idle must transition to .dismissing")
    assert(idleActions.count == 2, "Expected cancelErrorDismiss + beginFadeOut, got \(idleActions)")
    assert(idleActions[0] == .cancelErrorDismiss, "Must cancel pending error dismiss")
    guard case .beginFadeOut(let fadeGen) = idleActions[1] else {
        assertionFailure("Expected beginFadeOut, got \(idleActions)")
        return
    }

    // Stale error timeout is ignored
    assert(sm.handle(.errorTimeoutFired(generation: errorGen)).isEmpty)
    assert(sm.state == .dismissing)

    // Fade-out completes cleanly
    assert(sm.handle(.fadeOutCompleted(generation: fadeGen)) == [.hidePanel])
    assert(sm.state == .hidden)

    print("✔ HUD error -> idle cancels auto-dismiss verified")
}

private func testSuccessiveErrorsInvalidatePriorTimeout() {
    var sm = HUDPresentationStateMachine()

    let err1 = sm.handle(.dictationStateChanged(.error("First")))
    guard case .scheduleErrorDismiss(let gen1) = err1.last else {
        assertionFailure("Expected scheduleErrorDismiss for first error")
        return
    }

    // Second error while first countdown is still running (or during fade-out)
    let err2 = sm.handle(.dictationStateChanged(.error("Second")))
    assert(sm.state == .errorCountdown)
    assert(err2.count == 3, "Expected cancel + showPanel + scheduleErrorDismiss, got \(err2)")
    assert(err2[0] == .cancelErrorDismiss)
    assert(err2[1] == .showPanel(fadeIn: false))
    guard case .scheduleErrorDismiss(let gen2) = err2[2] else {
        assertionFailure("Expected scheduleErrorDismiss for second error")
        return
    }
    assert(gen2 != gen1, "Second error must get a new generation")

    // First error's timeout must not dismiss the second error prematurely
    assert(sm.handle(.errorTimeoutFired(generation: gen1)).isEmpty)
    assert(sm.state == .errorCountdown)

    // Second error's timeout dismisses it
    let timeout2 = sm.handle(.errorTimeoutFired(generation: gen2))
    assert(sm.state == .dismissing)
    assert(timeout2.count == 1)

    // Error arriving during fade-out restores visibility and starts countdown
    let err3 = sm.handle(.dictationStateChanged(.error("Third")))
    assert(sm.state == .errorCountdown)
    assert(err3.count == 2)
    assert(err3[0] == .showPanel(fadeIn: false))

    print("✔ HUD successive errors invalidate prior timeout verified")
}
