//
//  Window.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 3/10/19.
//  Copyright © 2019 Ian Ynda-Hummel. All rights reserved.
//

import Foundation
import Silica

// swiftlint:disable identifier_name
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: UInt32, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: inout UInt8) -> CGError

@_silgen_name("SLSMoveWindowsToManagedSpace")
func SLSMoveWindowsToManagedSpace(_ cid: Int32, _ window_ids: CFArray, _ sid: Int)

@_silgen_name("SLSSpaceSetCompatID")
func SLSSpaceSetCompatID(_ cid: Int32, _ sid: Int, _ workspace: Int32) -> CGError

@_silgen_name("SLSSetWindowListWorkspace")
func SLSSetWindowListWorkspace(_ cid: Int32, _ window_ids: UnsafePointer<UInt32>, _ window_count: Int32, _ workspace: Int32) -> CGError

let kCPSUserGenerated: UInt32 = 0x200
let kCPSNoWindows: UInt32 = 0x400
// swiftlint:enable identifier_name

/// Generic protocol for objects acting as windows in the system.
protocol WindowType: Equatable {
    associatedtype Screen: ScreenType
    associatedtype WindowID: Codable, Hashable

    /// Returns the currently focused window of its type.
    static func currentlyFocused() -> Self?

    /**
     Attempt to initialize a window based on a Silica element.
     
     Many of the accessibility APIs handle elements directly, so we need a way to convert those elements into a general window type. This is not necessarily meaningful in all cases — tests, for example, may provide window types that do not correspond to actual elements.
     
     - Parameters:
        - element: The element representing a window.
     */
    init?(element: SIAccessibilityElement?)

    /// Returns an opaque unique identifier for the window.
    func id() -> WindowID

    /// Returns the window's ID in the underlying window system.
    func cgID() -> CGWindowID

    /// Returns the window's current frame.
    func frame() -> CGRect

    /// Returns the screen, if any, that the window is currently on.
    func screen() -> Screen?

    /**
     Sets the frame of the window with an error threshold for what constitutes a new frame.
     
     The tolerance for error is necessary as for performance reasons we avoid performing unnecessary frame assignments, but some windows (e.g., Terminal's windows) have some constraints on their size such that `frame` and `window.frame()` will differ by some small amount even if `frame` has been applied before. We want to treat that frame as equivalent if it is close enough so that we get the performance benefit.
     
     - Parameters:
         - frame: The frame to apply.
         - threshold: The error tolerance for what constitutes a new frame.
     */

    func setFrame(_ frame: CGRect, withThreshold threshold: CGSize)

    /// Whether or not the window is currently holding focus.
    func isFocused() -> Bool

    /// The process ID of the process that owns the window.
    func pid() -> pid_t

    /**
     The title of the window.
     
     - Note: Windows do not necessarily have titles so this can be `nil`.
     */
    func title() -> String?

    /// Whether or not the window should actually be managed by Amethyst.
    func shouldBeManaged() -> Bool

    /// Whether or not the window should float by default.
    func shouldFloat() -> Bool

    /// Whether or not the window is currently active.
    func isActive() -> Bool

    /**
     Focuses the window.
     
     - Returns:
     `true` if the window was successfully focused, `false` otherwise.
     */
    @discardableResult func focus() -> Bool

    @discardableResult func minimize() -> Bool

    /**
     Moves the window to a screen.
     
     This method takes into account the dimensions of the screen to ensure that the window actually fits onto it.
     
     - Parameters:
        - screen: The screen to move the window to.
     */
    func moveScaled(to screen: Screen)

    /// Whether or not the window is currently on any screen.
    func isOnScreen() -> Bool

    /**
     Moves the window to a space.
     
     - Parameters:
        - space: The index of the space.
     */
    func move(toSpace space: UInt)

    /**
     Moves the window to a space.
     
     - Parameters:
         - spaceID: The id of the space.
     */
    func move(toSpace spaceID: CGSSpaceID)
}

enum WindowDecodingError: Error {
    case idNotFound
}

/**
 Final subclass of the Silica `SIWindow`.
 
 A final class is necessary for satisfying the `focusedWindow()` requirement in the `WindowType` protocol. Otherwise, as `SIWindow` is not final, the type system does not know how to constrain `Self`.
 */
final class AXWindow: SIWindow {}

/**
 Identifier for `AXWindow` objects.
 
 - Note:
 Decoding for this object is very inefficient. Use it sparingly.
 */
final class AXWindowID: Hashable, Codable {
    /// Coding keys.
    private enum CodingKeys: String, CodingKey {
        /// The pid of the process that owns the window.
        case pid

        /// The CoreGraphics id for the window.
        case windowID
    }

    private let window: AXWindow

    /// Equality for window IDs is based on the underlying CoreGraphics id and the owning pid, which (mostly) uniquely identifies a window.
    static func == (lhs: AXWindowID, rhs: AXWindowID) -> Bool {
        return lhs.window.pid() == rhs.window.pid() && lhs.window.windowID() == rhs.window.windowID()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(window.pid())
        hasher.combine(window.windowID())
    }

    fileprivate init(window: AXWindow) {
        self.window = window
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pid = try container.decode(pid_t.self, forKey: .pid)
        let windowID = try container.decode(CGWindowID.self, forKey: .windowID)

        guard let application = SIApplication(pid: pid) else {
            throw WindowDecodingError.idNotFound
        }

        let windows: [SIWindow] = application.windows()

        guard let window = windows.first(where: { $0.windowID() == windowID }) else {
            throw WindowDecodingError.idNotFound
        }

        self.window = AXWindow(axElement: window.axElementRef)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(window.pid(), forKey: .pid)
        try container.encode(window.windowID(), forKey: .windowID)
    }
}

/// Conformance of `AXWindow` as an Amethyst window.
extension AXWindow: WindowType {
    typealias Screen = AMScreen
    typealias WindowID = AXWindowID

    /**
     Returns the currently focused window.
     
     - Returns:
     The currently focused window as an `AXWindow`.
     */
    static func currentlyFocused() -> AXWindow? {
        return SIWindow.focused().flatMap { AXWindow(axElement: $0.axElementRef) }
    }

    /**
     The Silica initializer is not failable because it can always assume it has a reference to an ax element. The window type in general does not make that assumption and thus has a failable initializer. This just ports one into the other.
     
     - Parameters:
        - element: The element representing a window.
     */
    convenience init?(element: SIAccessibilityElement?) {
        guard let axElementRef = element?.axElementRef else {
            return nil
        }

        self.init(axElement: axElementRef)
    }

    func id() -> WindowID {
        return AXWindowID(window: self)
    }

    func cgID() -> CGWindowID {
        return windowID()
    }

    func screen() -> AMScreen? {
        let nsScreen: NSScreen? = screen()
        return nsScreen.flatMap { AMScreen(screen: $0) }
    }

    func pid() -> pid_t {
        return processIdentifier()
    }

    /**
     Whether or not the window should actually be managed by Amethyst.
     
     In this case the window must be movable and be a standard window.
     */
    func shouldBeManaged() -> Bool {
        guard isMovable() else {
            return false
        }

        guard let subrole = string(forKey: kAXSubroleAttribute as CFString), subrole == kAXStandardWindowSubrole as String else {
            return false
        }

        return true
    }

    func shouldFloat() -> Bool {
        let userConfiguration = UserConfiguration.shared
        let frame = self.frame()

        if userConfiguration.floatSmallWindows() && frame.size.width < 500 && frame.size.height < 500 {
            return true
        }

        return false
    }

    func isFocused() -> Bool {
        guard let focused = AXWindow.currentlyFocused() else {
            return false
        }

        return isEqual(to: focused)
    }

    /**
     Focuses the window.
     
     This handles focusing and also moves the cursor to the window's frame if mouse-follows-focus is enabled.
     
     - Returns:
     `true` if the window was successfully focused, `false` otherwise.
     
     - Description:
     What a mess. See: https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
     */
    @discardableResult override func focus() -> Bool {
        let pid = self.pid()
        var wid = self.cgID()
        var psn = ProcessSerialNumber()
        let status = GetProcessForPID(pid, &psn)

        guard status == noErr else {
            return false
        }

        var cgStatus = _SLPSSetFrontProcessWithOptions(&psn, wid, kCPSUserGenerated)

        guard cgStatus == .success else {
            return false
        }

        for byte in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xF8
            bytes[0x08] = UInt8(byte)
            bytes[0x3a] = 0x10
            memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
            memset(&bytes[0x20], 0xFF, 0x10)
            cgStatus = bytes.withUnsafeMutableBufferPointer { pointer in
                return SLPSPostEventRecordTo(&psn, &pointer.baseAddress!.pointee)
            }
            guard cgStatus == .success else {
                return false
            }
        }

        guard super.raise() else {
            return false
        }

        guard UserConfiguration.shared.mouseFollowsFocus() else {
            return true
        }

        let windowFrame = frame()
        let mouseCursorPoint = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        guard let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: mouseCursorPoint, mouseButton: .left) else {
            return true
        }
        mouseMoveEvent.flags = CGEventFlags(rawValue: 0)
        mouseMoveEvent.post(tap: CGEventTapLocation.cghidEventTap)

        return true
    }

    @discardableResult func minimize() -> Bool {
        super.minimize()
        return isWindowMinimized()
    }

    func moveScaled(to screen: Screen) {
        let screenFrame = screen.frameWithoutDockOrMenu()
        let currentFrame = frame()
        var scaledFrame = currentFrame

        if scaledFrame.width > screenFrame.width {
            scaledFrame.size.width = screenFrame.width
        }

        if scaledFrame.height > screenFrame.height {
            scaledFrame.size.height = screenFrame.height
        }

        if scaledFrame != currentFrame {
            setFrame(scaledFrame)
        }

        move(to: screen.screen)
    }

    func move(toSpace spaceID: CGSSpaceID) {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        if (osVersion.majorVersion >= 15) ||
            (osVersion.majorVersion == 14 && osVersion.minorVersion >= 5) ||
            (osVersion.majorVersion == 13 && osVersion.minorVersion >= 6) ||
            (osVersion.majorVersion == 12 && osVersion.minorVersion >= 7) {
            /*
             See:
             - https://github.com/ianyh/Amethyst/issues/1643
             - https://github.com/ianyh/Amethyst/issues/1666
             - https://github.com/koekeishiya/yabai/issues/2240
             - https://github.com/koekeishiya/yabai/issues/2408
             - https://github.com/koekeishiya/yabai/commit/98bbdbd1363f27d35f09338cded0de1ec010d830
             - https://github.com/koekeishiya/yabai/commit/c8f913cbc0497d1dfe16138f40a8ba6ecaa744f8
             */
            var error: CGError = .success

            error = SLSSpaceSetCompatID(CGSMainConnectionID(), spaceID, 0x79616265)
            defer { _ = SLSSpaceSetCompatID(CGSMainConnectionID(), spaceID, 0x0) }
            guard error == .success else {
                log.error("failed to set compat aside id: \(error)")
                return
            }

            var id = cgID()
            error = withUnsafeMutablePointer(to: &id, { pointer -> CGError in
                return SLSSetWindowListWorkspace(CGSMainConnectionID(), pointer, 1, 0x79616265)
            })
            guard error == .success else {
                log.error("failed to throw window: \(error)")
                return
            }
        } else {
            SLSMoveWindowsToManagedSpace(CGSMainConnectionID(), [cgID()] as CFArray, spaceID)
        }
    }
}
