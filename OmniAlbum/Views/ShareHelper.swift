//
//  ShareHelper.swift
//  OmniAlbum
//
//  Presents the system share sheet.
//

import SwiftUI
import UIKit

enum ShareHelper {
    @MainActor
    static func share(items: [Any]) {
        // Small delay lets the gesture system settle (avoids "gesture gate timed out" on the simulator).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            guard var topVC = scene?.keyWindow?.rootViewController else { return }
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            // iPad: anchor the popover at the centre
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }

            topVC.present(activityVC, animated: true)
        }
    }
}
