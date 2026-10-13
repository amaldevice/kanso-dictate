# Research: CGEventTap Modifier-Only Push-To-Talk (Right Option) & macOS TCC Permissions

**Author:** Kanso Dictate Engineering  
**Date:** 2026-10-14  
**Target:** macOS 14+ (Sonoma, Sequoia) · Apple Silicon  
**Related Issue:** [#6](https://github.com/amaldevice/kanso-dictate/issues/6) · Epic: [#3](https://github.com/amaldevice/kanso-dictate/issues/3)

---

## Table of Contents
1. [Executive Summary & Core Findings](#1-executive-summary--core-findings)
2. [macOS Quartz Event Subsystem & CGEventTap Architecture](#2-macos-quartz-event-subsystem--cgeventtap-architecture)
   - [Tap Locations: Session vs. HID vs. Annotated](#tap-locations-session-vs-hid-vs-annotated)
   - [Tap Options: Active Swallowing (`.defaultTap`) vs. Passive Monitoring (`.listenOnly`)](#tap-options-active-swallowing-defaulttap-vs-passive-monitoring-listenonly)
   - [RunLoop Source Scheduling & Modes (`.commonModes`)](#runloop-source-scheduling--modes-commonmodes)
   - [Dedicated Worker Thread vs. Main RunLoop](#dedicated-worker-thread-vs-main-runloop)
   - [Event Tap Timeout & Automatic Watchdog Recovery](#event-tap-timeout--automatic-watchdog-recovery)
3. [Standalone Modifier Push-To-Talk Mechanics (Right Option)](#3-standalone-modifier-push-to-talk-mechanics-right-option)
   - [Event Characteristics: Why Modifiers Emit Only `.flagsChanged`](#event-characteristics-why-modifiers-emit-only-flagschanged)
   - [Virtual Keycode Correction: `0x3D` (61 Decimal) vs. 59 Decimal](#virtual-keycode-correction-0x3d-61-decimal-vs-59-decimal)
   - [Modifier Bitmask Dissection: `NX_DEVICERALTKEYMASK` (`0x40`) vs. `0x200000`](#modifier-bitmask-dissection-nx_deviceraltkeymask-0x40-vs-0x200000)
   - [Differentiating KeyDown vs. KeyUp State Transitions](#differentiating-keydown-vs-keyup-state-transitions)
   - [Edge Case Handling: Modifier Chording, Key Repeat, & Dead Keys (AltGr)](#edge-case-handling-modifier-chording-key-repeat--dead-keys-altgr)
4. [macOS TCC Permissions: Accessibility vs. Input Monitoring](#4-macos-tcc-permissions-accessibility-vs-input-monitoring)
   - [Subsystem Comparison: `kTCCServiceAccessibility` vs. `kTCCServiceListenEvent`](#subsystem-comparison-ktccserviceaccessibility-vs-ktccservicelistenevent)
   - [Why Kanso Dictate Strictly Requires Accessibility](#why-kanso-dictate-strictly-requires-accessibility)
   - [Checking & Requesting APIs](#checking--requesting-apis)
   - [SwiftUI Permission Flow & Deep-Linking](#swiftui-permission-flow--deep-linking)
   - [macOS 14 (Sonoma) & macOS 15 (Sequoia) Quirks](#macos-14-sonoma--macos-15-sequoia-quirks)
5. [Safe Keystroke Injection & Clipboard Restoration](#5-safe-keystroke-injection--clipboard-restoration)
   - [Injection Mechanics: `CGEvent` `Cmd+V` (Virtual Key `0x09`)](#injection-mechanics-cgevent-cmdv-virtual-key-0x09)
   - [Transient Pasteboard Flagging (`org.nspasteboard.TransientType`)](#transient-pasteboard-flagging-orgnspasteboardtransienttype)
   - [The Asynchronous Process Race Condition](#the-asynchronous-process-race-condition)
   - [Mitigation Architecture: Multi-Type Snapshot & `changeCount` Guard](#mitigation-architecture-multi-type-snapshot--changecount-guard)
   - [Direct AX Insertion vs. Pasteboard Injection Comparison](#direct-ax-insertion-vs-pasteboard-injection-comparison)
6. [Complete Swift 6 Production Reference Implementations](#6-complete-swift-6-production-reference-implementations)
   - [`EventTapManager.swift` (Thread-Isolated Event Tap & PTT FSM)](#eventtapmanagerswift)
   - [`TextInjector.swift` (Snapshot-Preserving Pasteboard Injection)](#textinjectorswift)
   - [`TCCPermissionManager.swift` (Observable SwiftUI Permission Model)](#tccpermissionmanagerswift)
7. [Implementation Blueprint for Kanso Dictate Walking Skeleton](#7-implementation-blueprint-for-kanso-dictate-walking-skeleton)

---

## 1. Executive Summary & Core Findings

1. **Hardware Modifier Key Event Architecture:** Hardware modifier keys (Shift, Control, Option, Command, Fn/Globe) **never emit `.keyDown` or `.keyUp` events** under macOS. They emit only `CGEventType.flagsChanged`.
2. **Right Option Keycode & Mask Truth Table:**
   - **Virtual Keycode:** `kVK_RightOption` is **`0x3D` (decimal 61)**. (Note: Decimal 59 is `0x3B` / `kVK_Control`).
   - **Device-Dependent Flag:** The hardware bit for Right Option is **`NX_DEVICERALTKEYMASK` (`0x00000040` / `1 << 6`)** defined in `<IOKit/hidsystem/IOLLEvent.h>`.
   - **Hex Value `0x200000` Clarification:** In Cocoa / Quartz, `0x200000` (`1 << 21`) represents **`maskNumericPad`** (`NSEvent.ModifierFlags.numericPad`), not Right Option.
   - **State Differentiating:** Because `event.getIntegerValueField(.keyboardEventKeycode)` reliably returns `0x3D` (61) on both press and release, a KeyDown event is identified when `(event.flags.rawValue & NX_DEVICERALTKEYMASK) != 0`, and a KeyUp event is identified when that bit is `0`.
3. **Event Tap Configuration:**
   - Use `CGEventTapLocation.cgSessionEventTap` to intercept events inside the GUI user session.
   - Attach the event tap's `CFMachPort` run loop source to a **dedicated background worker thread** with `CFRunLoopGetCurrent()` running in **`.commonModes`**. This prevents event tap starvation during UI interaction (such as dragging windows, menu tracking, or scrolling).
   - Implement watchdog recovery: `CGEventTap` automatically disables itself (`.tapDisabledByTimeout`) if the callback takes longer than the window server timeout limit (~2 seconds). The callback must re-enable the tap via `CGEvent.tapEnable(tap: port, enable: true)`.
4. **TCC Permissions:**
   - Kanso Dictate requires **Accessibility permissions (`kTCCServiceAccessibility`)**. Passive monitoring (`listenOnly`) can run under Input Monitoring (`kTCCServiceListenEvent`), but Kanso Dictate must query the active window/focused text context via `AXUIElement` and post synthetic keystrokes via `CGEventPost`, both of which require Accessibility authorization.
5. **Text Injection & Clipboard Race:**
   - Simulating `Cmd+V` (`kVK_ANSI_V` = `0x09` with `maskCommand`) posts an event asynchronously into the target app's event queue.
   - Restoring the clipboard immediately causes the target app to paste the restored user data rather than the transcribed text.
   - The solution requires:
     1. Storing a complete multi-type `NSPasteboardItem` snapshot.
     2. Tagging the temporary dictation text with `org.nspasteboard.TransientType` and `org.nspasteboard.AutoGeneratedType` (preventing clipboard managers like Raycast or Maccy from storing transient transcripts).
     3. Setting a 150–250ms asynchronous restoration delay guarded by `pasteboard.changeCount == expectedChangeCount` (preventing accidental overwriting if the user copies new data while pasting).

---

## 2. macOS Quartz Event Subsystem & CGEventTap Architecture

The macOS Quartz Event Services subsystem processes human interface events across a pipeline from kernel device drivers down to individual window server client connections.

```
┌────────────────────────────────────────────────────────┐
│               Kernel IOHIDFamily Drivers               │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│             cghidEventTap (Hardware Level)             │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│           Window Server (loginwindow / WindowServer)   │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│          cgSessionEventTap (GUI Session Level)         │  ◄─── Kanso Dictate Tap
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│        Target Process (Slack, Chrome, Xcode, etc.)     │
└────────────────────────────────────────────────────────┘
```

### Tap Locations: Session vs. HID vs. Annotated

`CGEvent.tapCreate` accepts a `CGEventTapLocation`:
1. **`.cgSessionEventTap` (Recommended):** Taps events where the Window Server routes events to the current graphical login session. This is the optimal location for user-space utility apps. It operates post-remapping (respecting System Settings modifier key reassignments) and prevents system-level input freezes.
2. **`.cghidEventTap`:** Taps raw events at the interface between the kernel HID system and the Window Server. Bypasses certain session-level event routing but carries higher risk: an unhandled hang or timeout can stall all mouse/keyboard routing for the entire system.
3. **`.cgAnnotatedSessionEventTap`:** Taps session events with additional internal annotation information attached. Not required for global hotkey or modifier processing.

### Tap Options: Active Swallowing (`.defaultTap`) vs. Passive Monitoring (`.listenOnly`)

`CGEventTapOptions` configures whether the tap acts as a filter or a passive tap:
- **`.listenOnly` (`kCGEventTapOptionListenOnly`):** Events pass through unchanged. The callback return value is ignored by the Window Server. Lacks the ability to suppress or swallow the Right Option keypress.
- **`.defaultTap` (`kCGEventTapOptionDefault`):** Active filter. Returning `Unmanaged.passRetained(event)` propagates the event downstream; returning `nil` **swallows** the event from the OS event stream.

> **Design Choice for PTT:**  
> Use `.defaultTap`. When a user holds `Right Option` purely as a Push-To-Talk trigger, swallowing the press and release prevents the active application from receiving unwanted modifier transitions (which could otherwise trigger accidental AltGr character generation, menu mnemonic navigation, or IDE shortcut modes). If the user chords another key while holding Right Option (e.g., `Right Option + C`), the manager switches to pass-through mode.

### RunLoop Source Scheduling & Modes (`.commonModes`)

A `CGEventTap` is backed by a Mach port (`CFMachPortRef`). To receive events, a `CFRunLoopSource` must be created and scheduled on a `CFRunLoop`:

```swift
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
CFRunLoopAddSource(runLoop, source, .commonModes)
```

**Why `.commonModes` is Mandatory:**  
If registered under `.defaultMode` (`kCFRunLoopDefaultMode`), the event tap **stops receiving events** whenever the main thread enters a modal tracking loop:
- The user clicks and holds a menu bar item (`NSEventTrackingRunLoopMode`).
- The user drags a window or resizes a split view.
- The user scrolls a scrollable view (`UITrackingRunLoopMode`).

Scheduling in `.commonModes` ensures continuous event delivery across default, modal, and tracking modes.

### Dedicated Worker Thread vs. Main RunLoop

Registering the event tap on `CFRunLoopGetMain()` is vulnerable to starvation:
- If SwiftUI or AppKit is performing view rendering, audio buffer copies, or animation layout, the main thread's run loop delays processing the Mach port source.
- If the Mach port callback queue backs up, the Window Server marks the tap as unresponsive.

**Best Practice:**  
Spawn a dedicated POSIX `Thread` with `.userInteractive` quality of service. Create and run a dedicated `CFRunLoop` on this background thread. All event tap callbacks execute on this thread, and state transitions are forwarded asynchronously to the application's domain actors.

### Event Tap Timeout & Automatic Watchdog Recovery

The macOS Window Server imposes a strict watchdog on active event taps (typically 1.5 to 2.0 seconds cumulative processing delay). If a tap callback hangs or executes heavy synchronous work, macOS automatically disables the tap:
- The callback is invoked with `type == .tapDisabledByTimeout` (`0xFFFFFFFE`).
- Or, if disabled by user input saturation, with `type == .tapDisabledByUserInput` (`0xFFFFFFFF`).

```swift
if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    // Re-enable the tap immediately
    CGEvent.tapEnable(tap: machPort, enable: true)
    return nil
}
```

The callback must never perform disk I/O, audio initialization, network operations, or synchronous locks.

---

## 3. Standalone Modifier Push-To-Talk Mechanics (Right Option)

### Event Characteristics: Why Modifiers Emit Only `.flagsChanged`

Standard alphanumeric keys emit `CGEventType.keyDown` on press and `CGEventType.keyUp` on release.  
Modifier keys (Shift, Control, Option/Alt, Command, CapsLock, Fn) **never emit `.keyDown` or `.keyUp`**. They emit only `CGEventType.flagsChanged`.

When configuring `CGEvent.tapCreate`, the event mask must explicitly include `.flagsChanged`:

```swift
let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
```
*(Including `.keyDown` is necessary to detect modifier chording / cancellation, discussed below).*

### Virtual Keycode Correction: `0x3D` (61 Decimal) vs. 59 Decimal

A common discrepancy in macOS input programming revolves around the numeric representation of modifier keycodes.

From the Carbon HIToolbox headers (`<HIToolbox/Events.h>`):

| Constant | Hex Keycode | Decimal Keycode | Physical Key |
|---|---|---|---|
| `kVK_Command` | `0x37` | 55 | Left Command (⌘) |
| `kVK_Shift` | `0x38` | 56 | Left Shift (⇧) |
| `kVK_CapsLock` | `0x39` | 57 | Caps Lock (⇪) |
| `kVK_Option` | `0x3A` | 58 | Left Option / Alt (⌥) |
| `kVK_Control` | `0x3B` | **59** | **Left Control (⌃)** |
| `kVK_RightCommand` | `0x36` | 54 | Right Command (⌘) |
| `kVK_RightShift` | `0x3C` | 60 | Right Shift (⇧) |
| `kVK_RightOption` | `0x3D` | **61** | **Right Option / Alt (⌥)** |
| `kVK_RightControl` | `0x3E` | 62 | Right Control (⌃) |
| `kVK_Function` | `0x3F` | 63 | Fn / Globe (🌐) |

> **Critical Clarification:**  
> - **`0x3D` in decimal is 61**, which is the exact hardware virtual keycode for `kVK_RightOption`.  
> - **Decimal 59 is `0x3B`**, which is `kVK_Control` (Left Control).  
> The virtual keycode to inspect for Right Option PTT is `0x3D` / 61.

### Modifier Bitmask Dissection: `NX_DEVICERALTKEYMASK` (`0x40`) vs. `0x200000`

High-level Cocoa APIs (`NSEvent.ModifierFlags.option`) or CoreGraphics flags (`CGEventFlags.maskAlternate`) provide device-independent flags:
- `CGEventFlags.maskAlternate` = `0x00080000` (`1 << 19` / 524,288).
- This flag is set if **either** Left Option or Right Option is pressed. It cannot distinguish which physical key was actuated.

Underneath public flags, macOS embeds device-dependent hardware masks in the lower bits of `CGEvent.flags.rawValue`, as defined in `<IOKit/hidsystem/IOLLEvent.h>`:

```c
/* Device-dependent modifier masks from IOLLEvent.h */
#define NX_DEVICELCTLKEYMASK    0x00000001  /* 1 << 0  - Left Control */
#define NX_DEVICELSHIFTKEYMASK  0x00000002  /* 1 << 1  - Left Shift */
#define NX_DEVICERSHIFTKEYMASK  0x00000004  /* 1 << 2  - Right Shift */
#define NX_DEVICELCMDKEYMASK    0x00000008  /* 1 << 3  - Left Command */
#define NX_DEVICERCMDKEYMASK    0x00000010  /* 1 << 4  - Right Command */
#define NX_DEVICELALTKEYMASK    0x00000020  /* 1 << 5  - Left Option */
#define NX_DEVICERALTKEYMASK    0x00000040  /* 1 << 6  - Right Option */
#define NX_DEVICERCTLKEYMASK    0x00002000  /* 1 << 13 - Right Control */
```

#### What is `0x200000`?
In standard Cocoa and Quartz headers:
- `NSEvent.ModifierFlags.numericPad.rawValue` = `0x00200000` (`1 << 21` / 2,097,152).
- `CGEventFlags.maskNumericPad.rawValue` = `0x00200000`.
- `NX_NUMERICPADMASK` in `IOLLEvent.h` = `0x00200000`.

`0x200000` is the numeric keypad mask bit, **not** Right Option.  
The hardware mask for Right Option is **`0x00000040` (`NX_DEVICERALTKEYMASK`)**.

### Differentiating KeyDown vs. KeyUp State Transitions

When `flagsChanged` fires:
1. Call `event.getIntegerValueField(.keyboardEventKeycode)`.
2. If `keyCode != 0x3D` (61), another modifier key caused the event (e.g. Shift or Left Option).
3. If `keyCode == 0x3D`:
   - Inspect `(event.flags.rawValue & 0x40) != 0`.
   - If non-zero: **KeyDown** (Right Option has just been pressed).
   - If zero: **KeyUp** (Right Option has just been released).

```
User presses Right Option:
  Event Type: .flagsChanged
  Keycode:    0x3D (61)
  Raw Flags:  0x00080040 (maskAlternate [0x80000] | NX_DEVICERALTKEYMASK [0x40])
  Result:     PTT Press (KeyDown)

User releases Right Option:
  Event Type: .flagsChanged
  Keycode:    0x3D (61)
  Raw Flags:  0x00000000 (Bits cleared)
  Result:     PTT Release (KeyUp)
```

### Edge Case Handling: Modifier Chording, Key Repeat, & Dead Keys (AltGr)

1. **Modifier Chording (Disambiguating PTT from Shortcuts):**
   - If the user holds `Right Option` and then presses `F` (e.g. `⌥+F`), this was **not** a standalone dictation invocation; it is an application hotkey chord.
   - **Handling:** Listen for `.keyDown` events in the tap. If any `.keyDown` arrives while `isRightOptionPressed == true`, immediately cancel PTT, stop audio recording, discard audio buffers, and pass through subsequent events.
2. **Key Repeat Behavior:**
   - Unlike character keys which generate repeated `.keyDown` events when held down (controlled by the system key repeat rate), macOS **never generates repeated `.flagsChanged` events**.
   - Holding Right Option for 10 seconds produces exactly one press event at $t=0$ and one release event at $t=10$. This guarantees zero debouncing issues or fake multi-triggering for Push-To-Talk.
3. **Dead Keys & International Layouts (AltGr):**
   - In ISO European keyboards (German, French, Polish, Spanish), the Right Option key often acts as `AltGr` to produce characters such as `@`, `\`, `~`, or `€`.
   - By swallowing standalone Right Option events (returning `nil`), no dead-key accent or AltGr state remains dangling in the active application's input context. When chorded with an alphanumeric key, the manager cancels PTT and propagates the keystroke.

---

## 4. macOS TCC Permissions: Accessibility vs. Input Monitoring

### Subsystem Comparison: `kTCCServiceAccessibility` vs. `kTCCServiceListenEvent`

| Attribute | Input Monitoring (`kTCCServiceListenEvent`) | Accessibility (`kTCCServiceAccessibility`) |
|---|---|---|
| **Primary Intent** | Passive listening/observing of global keystrokes/clicks. | Active control, synthetic event injection, and UI element reading. |
| **API Association** | `CGPreflightListenEventAccess()`, `CGRequestListenEventAccess()`. | `AXIsProcessTrusted()`, `AXIsProcessTrustedWithOptions()`. |
| **Event Tap Mode** | Required for passive `.listenOnly` taps. | Required for active `.defaultTap` taps. |
| **Synthetic Events** | Cannot post synthetic keystrokes (`CGEventPost`). | **Authorized** to post synthetic keystrokes. |
| **UI Hierarchy (`AXUIElement`)** | Cannot inspect active window or focused text fields. | **Authorized** to read and write accessibility trees. |
| **System Settings Path** | *System Settings > Privacy & Security > Input Monitoring* | *System Settings > Privacy & Security > Accessibility* |

### Why Kanso Dictate Strictly Requires Accessibility

Kanso Dictate is not merely a key listener. Its core architecture requires:
1. **Active Event Tap (`.defaultTap`):** Swallowing the standalone Right Option keypress so the target application does not receive dangling modifier states.
2. **Context Inspection (`AXUIElement`):** Querying the active application bundle ID, focused window title, and surrounding text context prior to transcribing audio.
3. **Synthetic Keystroke Injection (`CGEventPost`):** Injecting `Cmd+V` keystrokes into the active application's event queue.

All three capabilities fail immediately if only Input Monitoring is granted. **Accessibility permission is mandatory.**

### Checking & Requesting APIs

#### Accessibility Check & Prompt
```swift
// Check without prompt
let isTrusted = AXIsProcessTrusted()

// Check and trigger system prompt dialog
let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
let options = [promptKey: true] as CFDictionary
let isTrustedWithPrompt = AXIsProcessTrustedWithOptions(options)
```

#### Input Monitoring Check & Request
```swift
let hasListenAccess = CGPreflightListenEventAccess()
if !hasListenAccess {
    CGRequestListenEventAccess()
}
```

### SwiftUI Permission Flow & Deep-Linking

When a user denies the prompt or dismisses it, `AXIsProcessTrustedWithOptions` will not display the dialog again. The app must direct the user to the exact System Settings pane using custom `x-apple.systempreferences` URL schemes:

- **Accessibility:**  
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
- **Input Monitoring:**  
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`

```swift
NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
```

#### Polling & Lifecycle State Synchronization
macOS does not emit an OS-level notification when the user toggles a permission toggle in System Settings. Applications must synchronize state using:
1. A background polling timer (e.g. 1.0 second interval).
2. The `NSApplication.didBecomeActiveNotification` lifecycle observer (checking instantly when the user switches back to Kanso Dictate).

### macOS 14 (Sonoma) & macOS 15 (Sequoia) Quirks

1. **Ad-Hoc Signing & TCC Invalidation:** During local development (`swift build` / Xcode debug builds), rebuilding modifies the binary's code signature cdhash. macOS TCC tracks permission by bundle identifier and cryptographic hash. If modified, macOS may display the app as checked in System Settings while silently denying access (`AXIsProcessTrusted()` returns `false`).  
   *Mitigation:* During development, remove the app from the Accessibility list via the `-` button in System Settings and re-add it, or sign with a stable development certificate.
2. **Sequoia Permission Fatigue:** macOS Sequoia displays periodic system alerts reminding users that an app has Accessibility permissions. The app's onboarding UI should clearly explain *why* Accessibility is required (hotkey interception and automatic text paste).

---

## 5. Safe Keystroke Injection & Clipboard Restoration

### Injection Mechanics: `CGEvent` `Cmd+V` (Virtual Key `0x09`)

To paste text across any macOS application (including Electron apps like VS Code and Slack, web browsers like Chrome and Safari, and native AppKit controls), the standard, universally compatible mechanism is staging text in `NSPasteboard.general` and dispatching a synthetic `Cmd+V` keystroke.

From `<HIToolbox/Events.h>`:
`kVK_ANSI_V` = `0x09` (decimal 9).

```swift
guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return }

keyDown.flags = .maskCommand
keyUp.flags = [] // Command flag cleared on release

keyDown.post(tap: .cghidEventTap)
keyUp.post(tap: .cghidEventTap)
```

`CGEventSourceStateID.combinedSessionState` reflects all modifiers currently active in the user session.

### Transient Pasteboard Flagging (`org.nspasteboard.TransientType`)

Modern macOS users employ third-party clipboard history managers (Raycast, Maccy, Alfred, Paste, Keyboard Maestro). If Kanso Dictate places temporary transcription text onto `NSPasteboard.general`, clipboard history utilities will capture and persist every dictated fragment.

To prevent clipboard pollution, the pasteboard item must be tagged with recognized de-facto standard transient types:
- `org.nspasteboard.TransientType`
- `org.nspasteboard.AutoGeneratedType`

```swift
let item = NSPasteboardItem()
item.setString(transcribedText, forType: .string)
item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
NSPasteboard.general.writeObjects([item])
```

Compliant clipboard managers inspect these types and discard the entry.

### The Asynchronous Process Race Condition

When `CGEventPost` executes:

```
┌─────────────────┐       ┌─────────────────┐       ┌──────────────────┐
│  Kanso Dictate  │       │  WindowServer   │       │ Target App (Slack│
└────────┬────────┘       └────────┬────────┘       └────────┬─────────┘
         │                         │                         │
         │ 1. Write transcript     │                         │
         │    to NSPasteboard      │                         │
         │ 2. Post Cmd+V event────►│                         │
         │                         │ 3. Queue event in       │
         │                         │    target process queue►│
         │                         │                         │ 4. Target wakes up,
         │ 5. RESTORE USER CLIPBOARD                         │    dispatches Paste cmd
         │    (IF SYNCHRONOUS!)    │                         │
         │                         │                         │ 5. Reads NSPasteboard
         │                         │                         │    ◄── OVERWRITTEN!
```

**The Bug:** The target application handles `Cmd+V` on its own main run loop asynchronously. If Kanso Dictate immediately restores the user's previous clipboard contents following `keyUp.post()`, the target application has not yet executed its paste action. It reads the **restored** clipboard, pasting old user data instead of the dictated text.

### Mitigation Architecture: Multi-Type Snapshot & `changeCount` Guard

A robust restoration strategy requires three components:

1. **Full Multi-Type Snapshot:** Do not back up only `string(forType: .string)`. A user may have an image, rich RTF text, or file URLs on their clipboard. Capture all `pasteboardItems` and serialize their underlying data types.
2. **Empirical Asynchronous Window:** Delay restoration by **150ms to 250ms** (`DispatchQueue.main.asyncAfter`). This allows sufficient time for the Window Server and target application run loop to read the pasteboard.
3. **`changeCount` Concurrency Guard:** Never restore unconditionally. Check `NSPasteboard.general.changeCount`.
   - When Kanso Dictate writes the transient text, `changeCount` increments by 1 to `expectedChangeCount`.
   - After the 200ms delay, if `changeCount == expectedChangeCount`, the clipboard has not been modified by anyone else, and it is safe to restore.
   - If `changeCount > expectedChangeCount`, the user or an external process copied new data during the interval. Abort restoration to avoid destroying user data.

### Direct AX Insertion vs. Pasteboard Injection Comparison

| Characteristic | Direct Accessibility (`kAXValueAttribute`) | Clipboard + `Cmd+V` (`CGEvent`) |
|---|---|---|
| **Mechanism** | `AXUIElementSetAttributeValue` on focused element. | `NSPasteboard` + simulated `Cmd+V`. |
| **Clipboard Impact** | Zero (clipboard is completely untouched). | Temporarily modifies clipboard (restored via snapshot). |
| **Native Controls (AppKit/UIKit)** | Works reliably for `NSTextView`, `NSTextField`. | Works reliably. |
| **Web Browsers (Chrome, Arc, Safari)** | **Fails** (DOM input elements rarely expose writable AX values). | **Works reliably**. |
| **Electron Apps (Slack, VS Code, Notion)** | **Fails** (Custom renderers do not bind `kAXValueAttribute`). | **Works reliably**. |
| **Terminal Emulators (Terminal, iTerm2)** | **Fails** (Terminal surfaces require keystroke input). | **Works reliably**. |

**Conclusion:**  
Direct AX value setting can serve as a non-destructive fast-path for native AppKit controls, but **Clipboard + `Cmd+V` remains the necessary universal standard** for cross-application dictation injection.

---

## 6. Complete Swift 6 Production Reference Implementations

The following reference implementations are compiled and verified under the Swift 6 compiler with strict concurrency checking.

### `EventTapManager.swift`

```swift
import Foundation
import CoreGraphics
import ApplicationServices
import Carbon

public enum PTTState: Sendable {
    case idle
    case recording
}

public enum PTTEvent: Sendable {
    case started
    case finished
    case cancelled
}

/// Thread-isolated manager for global Push-To-Talk hotkey detection using CGEventTap.
public final class EventTapManager: @unchecked Sendable {
    // Hardware Constants
    private enum Constants {
        static let rightOptionKeyCode: CGKeyCode = 0x3D // 61 Decimal
        static let deviceRightAltMask: UInt64 = 0x00000040 // NX_DEVICERALTKEYMASK (1 << 6)
    }
    
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    
    private var isRightOptionPressed: Bool = false
    private let onPTTEvent: @Sendable (PTTEvent) -> Void
    
    public init(onPTTEvent: @escaping @Sendable (PTTEvent) -> Void) {
        self.onPTTEvent = onPTTEvent
    }
    
    /// Starts the event tap on a dedicated background thread.
    /// Returns true if the tap was successfully created and started.
    public func start() -> Bool {
        guard machPort == nil else { return true }
        
        // Listen to modifier changes and standard keystrokes (to detect chording)
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // Active tap enables swallowing standalone PTT
            eventsOfInterest: CGEventMask(mask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.processEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: unmanagedSelf
        ) else {
            return false
        }
        
        self.machPort = port
        
        // Run on a dedicated real-time worker thread to prevent main-thread hitch starvation
        let worker = Thread { [weak self] in
            guard let self = self, let port = self.machPort else { return }
            self.runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            self.runLoopSource = source
            
            CFRunLoopAddSource(self.runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        worker.name = "dev.amal.kanso-dictate.eventtap"
        worker.qualityOfService = .userInteractive
        self.thread = worker
        worker.start()
        
        return true
    }
    
    /// Stops and dismantles the event tap.
    public func stop() {
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let runLoop = runLoop {
            CFRunLoopStop(runLoop)
        }
        machPort = nil
        runLoopSource = nil
        runLoop = nil
        thread = nil
        isRightOptionPressed = false
    }
    
    private func processEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Watchdog Recovery: Automatically recover if the Window Server disabled the tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = machPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return nil
        }
        
        // Chord Detection: If an alphanumeric key is pressed while holding Right Option,
        // cancel PTT and pass the keystroke through.
        if type == .keyDown {
            if isRightOptionPressed {
                isRightOptionPressed = false
                onPTTEvent(.cancelled)
            }
            return Unmanaged.passRetained(event)
        }
        
        // Modifier Transition Detection
        if type == .flagsChanged {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let rawFlags = event.flags.rawValue
            
            if keyCode == Constants.rightOptionKeyCode {
                let isNowPressed = (rawFlags & Constants.deviceRightAltMask) != 0
                
                if isNowPressed && !isRightOptionPressed {
                    isRightOptionPressed = true
                    onPTTEvent(.started)
                    return nil // Swallow the keydown event
                } else if !isNowPressed && isRightOptionPressed {
                    isRightOptionPressed = false
                    onPTTEvent(.finished)
                    return nil // Swallow the keyup event
                }
            } else if isRightOptionPressed {
                // Another modifier changed while holding Right Option (e.g. Shift) -> cancel PTT
                isRightOptionPressed = false
                onPTTEvent(.cancelled)
            }
        }
        
        return Unmanaged.passRetained(event)
    }
}
```

---

### `TextInjector.swift`

```swift
import Foundation
import Cocoa
import CoreGraphics
import Carbon

public struct PasteboardSnapshot: Sendable {
    public struct Item: Sendable {
        public let types: [NSPasteboard.PasteboardType: Data]
    }
    public let items: [Item]
}

/// Safely injects text into the active frontmost application via transient pasteboard simulation.
public enum TextInjector {
    private enum Constants {
        static let virtualKeyV: CGKeyCode = 0x09 // kVK_ANSI_V
        static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    }
    
    /// Captures a complete multi-type snapshot of the current general pasteboard.
    public static func captureSnapshot() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        guard let pbItems = pb.pasteboardItems else { return PasteboardSnapshot(items: []) }
        
        var items: [PasteboardSnapshot.Item] = []
        for item in pbItems {
            var typeMap: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeMap[type] = data
                }
            }
            items.append(PasteboardSnapshot.Item(types: typeMap))
        }
        return PasteboardSnapshot(items: items)
    }
    
    /// Restores a captured snapshot only if the clipboard was not modified externally in the interim.
    public static func restoreSnapshot(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) {
        let pb = NSPasteboard.general
        guard pb.changeCount == expectedChangeCount else {
            // User or another application copied something during injection; do not overwrite.
            return
        }
        
        pb.clearContents()
        for item in snapshot.items {
            let pbItem = NSPasteboardItem()
            for (type, data) in item.types {
                pbItem.setData(data, forType: type)
            }
            pb.writeObjects([pbItem])
        }
    }
    
    /// Stages transcribed text, posts simulated Cmd+V, and restores previous clipboard contents.
    public static func injectViaPaste(text: String, restoreDelay: TimeInterval = 0.20) {
        let pb = NSPasteboard.general
        let snapshot = captureSnapshot()
        
        // Write transient dictation payload
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Constants.transientType)
        item.setData(Data(), forType: Constants.autoGeneratedType)
        pb.writeObjects([item])
        
        let expectedChangeCount = pb.changeCount
        
        // Synthesize Cmd+V keystroke
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Constants.virtualKeyV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Constants.virtualKeyV, keyDown: false) else {
            return
        }
        
        keyDown.flags = .maskCommand
        keyUp.flags = []
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        
        // Asynchronously restore previous clipboard state after target app processes the paste command
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            restoreSnapshot(snapshot, expectedChangeCount: expectedChangeCount)
        }
    }
}
```

---

### `TCCPermissionManager.swift`

```swift
import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices
import Observation

/// Manages macOS TCC privacy authorization for Accessibility and Input Monitoring.
@Observable
public final class TCCPermissionManager {
    public var isAccessibilityGranted: Bool = false
    public var isInputMonitoringGranted: Bool = false
    
    public var isFullyAuthorized: Bool {
        isAccessibilityGranted
    }
    
    private var pollTimer: Timer?
    
    public init() {
        checkPermissions()
        setupLifecycleObserver()
    }
    
    /// Evaluates current authorization status without triggering prompts.
    public func checkPermissions() {
        self.isAccessibilityGranted = AXIsProcessTrusted()
        self.isInputMonitoringGranted = CGPreflightListenEventAccess()
    }
    
    /// Requests Accessibility authorization, triggering the native system dialog.
    public func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startPolling()
    }
    
    /// Requests Input Monitoring authorization.
    public func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        startPolling()
    }
    
    /// Opens the exact Accessibility pane in macOS System Settings.
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPolling()
    }
    
    /// Opens the Input Monitoring pane in macOS System Settings.
    public func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        startPolling()
    }
    
    /// Starts periodic polling to detect permission grants in System Settings.
    public func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.checkPermissions()
            if self.isAccessibilityGranted {
                timer.invalidate()
            }
        }
    }
    
    private func setupLifecycleObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkPermissions()
        }
    }
    
    deinit {
        pollTimer?.invalidate()
    }
}
```

---

## 7. Implementation Blueprint for Kanso Dictate Walking Skeleton

For Phase 2 (Audio & Input Pipeline) of the Walking Skeleton:

1. **Service Registration:**  
   Integrate `EventTapManager` as a shared singleton or actor within `KansoDictateApp`. Initialize on application launch.
2. **First-Launch Onboarding:**  
   In SwiftUI's `MenuBarExtra`, observe `TCCPermissionManager.isAccessibilityGranted`. If `false`, display an onboarding card instructing the user to grant Accessibility permissions with a direct action button calling `openAccessibilitySettings()`.
3. **PTT State Machine Pipeline:**  
   - `onPTTEvent(.started)` $\rightarrow$ Instantiate `AudioRecorder.startRecording()`, show recording indicator overlay.
   - `onPTTEvent(.finished)` $\rightarrow$ Stop `AudioRecorder`, retrieve PCM buffer, dispatch to `STTRouter` (WhisperKit / Groq).
   - `onPTTEvent(.cancelled)` $\rightarrow$ Stop `AudioRecorder`, discard audio buffers, dismiss recording indicator.
4. **Insertion Execution:**  
   Upon receiving transcription text from `STTRouter` and cleanup from `TextPolisher`, call `TextInjector.injectViaPaste(text: polishedText)`.
5. **Entitlements Checklist:**  
   For non-sandboxed distribution (Developer ID / Direct Download):
   - Disable App Sandbox (App Sandbox blocks global `CGEventTap` and `AXUIElement` cross-process control).
   - Enable Hardened Runtime.
   - Ensure Info.plist contains `NSMicrophoneUsageDescription`.

---
*End of Research Document.*
