//
//  UploadWidgetBundle.swift
//  UploadWidgetExtension
//
//  Widget bundle containing the Live Activity for upload progress.
//

import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

@main
struct UploadWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        RecentAlbumsWidget()
        RandomPhotoWidget()
        if #available(iOS 16.2, *) {
            UploadLiveActivity()
        }
    }
}
