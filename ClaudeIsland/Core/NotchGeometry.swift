//
//  NotchGeometry.swift
//  ClaudeIsland
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat

    /// Extra rendered width added by opened-state padding and corner treatment.
    static let openedVisualWidthPadding: CGFloat = 62

    private var notchCenterX: CGFloat {
        screenRect.midX
    }

    private var notchLeadingX: CGFloat {
        notchCenterX - deviceNotchRect.width / 2
    }

    private var notchTrailingX: CGFloat {
        notchCenterX + deviceNotchRect.width / 2
    }

    private var windowOriginY: CGFloat {
        screenRect.maxY - windowHeight
    }

    private func leadingXForPanel(width: CGFloat) -> CGFloat {
        notchTrailingX - width
    }

    private func windowRect(for screenSpaceRect: CGRect) -> CGRect {
        CGRect(
            x: screenSpaceRect.minX - screenRect.minX,
            y: screenSpaceRect.minY - windowOriginY,
            width: screenSpaceRect.width,
            height: screenSpaceRect.height
        )
    }

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: notchLeadingX,
            y: screenRect.maxY - deviceNotchRect.height,
            width: deviceNotchRect.width,
            height: deviceNotchRect.height
        )
    }

    /// The notch rect in window coordinates.
    var notchWindowRect: CGRect {
        windowRect(for: notchScreenRect)
    }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
        let width = size.width + Self.openedVisualWidthPadding
        let height = size.height
        return CGRect(
            x: leadingXForPanel(width: width),
            y: screenRect.maxY - height,
            width: width,
            height: height
        )
    }

    /// The opened panel rect in window coordinates for a given size.
    func openedWindowRect(for size: CGSize) -> CGRect {
        windowRect(for: openedScreenRect(for: size))
    }

    /// The closed panel rect in window coordinates for a rendered width.
    func closedWindowRect(contentWidth: CGFloat, contentHeight: CGFloat) -> CGRect {
        let width = max(contentWidth, deviceNotchRect.width)
        let screenSpaceRect = CGRect(
            x: leadingXForPanel(width: width),
            y: screenRect.maxY - contentHeight,
            width: width,
            height: contentHeight
        )
        return windowRect(for: screenSpaceRect)
    }

    /// Check if a point is in the notch area (with padding for easier interaction)
    func isPointInNotch(_ point: CGPoint) -> Bool {
        notchScreenRect.insetBy(dx: -10, dy: -5).contains(point)
    }

    /// Check if a point is in the opened panel area
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        openedScreenRect(for: size).contains(point)
    }

    /// Check if a point is outside the opened panel (for closing)
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !openedScreenRect(for: size).contains(point)
    }
}
