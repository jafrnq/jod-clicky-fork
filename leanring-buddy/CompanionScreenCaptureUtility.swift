//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

enum CompanionScreenCaptureError: LocalizedError {
    case noFocusedWindow
    case windowCaptureFailed(underlying: Error)
    
    var errorDescription: String? {
        switch self {
        case .noFocusedWindow: return "No focused window found."
        case .windowCaptureFailed(let err): return "Window capture failed: \(err.localizedDescription)"
        }
    }
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        let sortedDisplays = content.displays.sorted { $0.frame.minX < $1.frame.minX }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    static func captureFocusedWindowAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        let mouseLocation = NSEvent.mouseLocation
        let ownBundle = Bundle.main.bundleIdentifier
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        
        var targetSCWindow: SCWindow? = nil
        var focusedDisplay: SCDisplay? = nil

        if let frontmost = frontmostApplication, frontmost.bundleIdentifier != ownBundle {
            let pid = frontmost.processIdentifier
            let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
            if let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] {
                let appWindows = windowInfoList.filter { dict in
                    guard let winPid = dict[kCGWindowOwnerPID] as? pid_t, winPid == pid,
                          let layer = dict[kCGWindowLayer] as? Int, layer == 0,
                          let boundsDict = dict[kCGWindowBounds] as? [CFString: Any],
                          let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return false }
                    return bounds.width > 0 && bounds.height > 0
                }
                
                if let frontmostWinInfo = appWindows.first,
                   let winNumber = frontmostWinInfo[kCGWindowNumber] as? CGWindowID {
                    targetSCWindow = content.windows.first { $0.windowID == winNumber }
                }
            }
            
            let activeWindows = content.windows.filter { window in
                window.owningApplication?.bundleIdentifier == frontmost.bundleIdentifier && window.isOnScreen
            }
            if targetSCWindow == nil && !activeWindows.isEmpty {
                let cgMouseLocation = CGPoint(x: mouseLocation.x, y: primaryScreenHeight - mouseLocation.y)
                targetSCWindow = activeWindows.first { $0.frame.contains(cgMouseLocation) }
                    ?? activeWindows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                    ?? activeWindows.first!
            }
        }
        
        if let win = targetSCWindow {
            let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
            focusedDisplay = content.displays.first { $0.frame.contains(center) }
        }

        if focusedDisplay == nil {
            focusedDisplay = content.displays.first { display in
                let frame = nsScreenByDisplayID[display.displayID]?.frame ?? display.frame
                return frame.contains(mouseLocation)
            }
        }

        let targetDisplay = focusedDisplay ?? content.displays.first!
        let screen = nsScreenByDisplayID[targetDisplay.displayID] ?? NSScreen.screens.first { 
            if let sc = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID { return sc == targetDisplay.displayID }
            return false
        } ?? NSScreen.screens.first ?? NSScreen()
        
        let maxPixels = 480_000.0
        let backingScale = screen.backingScaleFactor
        
        if let win = targetSCWindow {
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let contentRect = filter.contentRect
            let configuration = SCStreamConfiguration()
            configuration.ignoreShadowsSingleWindow = true
            configuration.scalesToFit = true
            
            let pixelWidth = contentRect.width * backingScale
            let pixelHeight = contentRect.height * backingScale
            let totalPixels = pixelWidth * pixelHeight
            let scale = totalPixels > maxPixels ? sqrt(maxPixels / totalPixels) : 1.0
            
            configuration.width = max(1, Int(pixelWidth * scale))
            configuration.height = max(1, Int(pixelHeight * scale))
            
            do {
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                if let jpegData = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                    let appKitY = primaryScreenHeight - contentRect.origin.y - contentRect.height
                    let windowAppKitFrame = CGRect(x: contentRect.origin.x, y: appKitY, width: contentRect.width, height: contentRect.height)
                    
                    return [CompanionScreenCapture(
                        imageData: jpegData,
                        label: "the frontmost app's focused window (primary focus)",
                        isCursorScreen: true,
                        displayWidthInPoints: Int(contentRect.width),
                        displayHeightInPoints: Int(contentRect.height),
                        displayFrame: windowAppKitFrame,
                        screenshotWidthInPixels: configuration.width,
                        screenshotHeightInPixels: configuration.height
                    )]
                }
            } catch {
                print("⚠️ Window capture failed or raced: \(error)")
                throw CompanionScreenCaptureError.windowCaptureFailed(underlying: error)
            }
        }

        print("⚠️ No focused window resolved.")
        throw CompanionScreenCaptureError.noFocusedWindow
    }

    static func captureRegionAsJPEG(globalRect: CGRect) async throws -> CompanionScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        guard !content.displays.isEmpty else { throw NSError(domain:"CompanionScreenCapture", code:-1, userInfo:[NSLocalizedDescriptionKey:"No display available for capture"]) }

        // Find display containing rect center
        let centerPoint = CGPoint(x: globalRect.midX, y: globalRect.midY)
        let targetDisplay = content.displays.first { display in
            let frame = nsScreenByDisplayID[display.displayID]?.frame ?? display.frame
            return frame.contains(centerPoint)
        } ?? content.displays.first!

        let screen = nsScreenByDisplayID[targetDisplay.displayID] ?? NSScreen.screens.first!
        let screenFrame = screen.frame
        let localX = globalRect.minX - screenFrame.minX
        let localY = screenFrame.maxY - globalRect.maxY
        let localRect = CGRect(x: localX, y: localY, width: globalRect.width, height: globalRect.height)

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: ownAppWindows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.scalesToFit = true

        let maxDimension: CGFloat = 1280
        let maxRectDim = max(globalRect.width, globalRect.height)
        let scale = maxRectDim > maxDimension ? maxDimension / maxRectDim : 1.0
        let backingScale = screen.backingScaleFactor
        configuration.width = Int(globalRect.width * scale * backingScale)
        configuration.height = Int(globalRect.height * scale * backingScale)
        
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to convert region capture to JPEG"])
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: "the region the user selected",
            isCursorScreen: true,
            displayWidthInPoints: Int(globalRect.width),
            displayHeightInPoints: Int(globalRect.height),
            displayFrame: globalRect,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )
    }
}
