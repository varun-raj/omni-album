//
//  SplashScreenView.swift
//  OmniAlbum
//
//  Animated splash screen with logo and tagline.
//

import SwiftUI

struct SplashScreenView: View {
    @State private var logoScale: CGFloat = 0.4
    @State private var logoOpacity: Double = 0
    @State private var logoRotation: Double = -120
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 20
    @State private var taglineOpacity: Double = 0
    @State private var taglineOffset: CGFloat = 15

    private let taglines = [
        "Every server. One album.",
        "Your photos, everywhere.",
        "All your memories, unified.",
        "One app for every gallery.",
    ]

    @State private var selectedTagline: String = ""

    var body: some View {
        ZStack {
            // Background
            Color.white
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                Image("SplashLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(logoRotation))
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                Spacer().frame(height: 28)

                // App name
                Text("OmniAlbum")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .opacity(titleOpacity)
                    .offset(y: titleOffset)

                Spacer().frame(height: 10)

                // Tagline
                Text(selectedTagline)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .opacity(taglineOpacity)
                    .offset(y: taglineOffset)

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            selectedTagline = taglines.randomElement() ?? taglines[0]
            animateIn()
        }
    }

    private func animateIn() {
        // Logo appears with spring + rotation
        withAnimation(.spring(response: 0.7, dampingFraction: 0.6).delay(0.1)) {
            logoScale = 1.0
            logoOpacity = 1.0
            logoRotation = 0
        }

        // Title slides up and fades in
        withAnimation(.easeOut(duration: 0.5).delay(0.4)) {
            titleOpacity = 1.0
            titleOffset = 0
        }

        // Tagline follows
        withAnimation(.easeOut(duration: 0.5).delay(0.6)) {
            taglineOpacity = 1.0
            taglineOffset = 0
        }
    }
}

#Preview {
    SplashScreenView()
}
