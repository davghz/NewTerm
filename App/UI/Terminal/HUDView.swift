//
//  HUDView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 25/12/2022.
//

import SwiftUI
import SwiftUIX
import UIKit

private struct SpinnerView: UIViewRepresentable {
	func makeUIView(context: Context) -> UIActivityIndicatorView {
		let v = UIActivityIndicatorView(style: .medium)
		v.startAnimating()
		return v
	}
	func updateUIView(_ uiView: UIActivityIndicatorView, context: Context) {}
}

class HUDViewState: ObservableObject {
	@Published var isVisible = false
	/// Non-nil while a file download is in progress. Value is the filename.
	@Published var downloadingFileName: String? = nil
}

struct HUDView: View {
	@EnvironmentObject private var state: HUDViewState

	var body: some View {
		let isDownloading = state.downloadingFileName != nil
		VisualEffectBlurView(blurStyle: .systemMaterial,
												 vibrancyStyle: .label) {
			if isDownloading {
				VStack(spacing: 6) {
					SpinnerView()
					if let name = state.downloadingFileName {
						Text(name)
							.font(.system(size: 10, weight: .medium))
							.lineLimit(1)
							.truncationMode(.middle)
							.frame(maxWidth: 90)
					}
				}
				.foregroundColor(.label)
			} else {
				Image(systemName: .bell)
					.font(.system(size: 25, weight: .medium))
					.imageScale(.large)
					.foregroundColor(.label)
			}
		}
			.frame(width: isDownloading ? 110 : 54, height: 54)
			.cornerRadius(16, style: .continuous)
			.visible(state.isVisible || isDownloading,
						   animation: (state.isVisible || isDownloading) ? nil : .linear(duration: 0.3))
			.onReceive(state.$isVisible) { isVisible in
				if isVisible {
					Timer.scheduledTimer(withTimeInterval: 0.75, repeats: false) { _ in
						self.state.isVisible = false
					}
			}
		}
	}
}

struct HUDView_Previews: PreviewProvider {
	private static var state = HUDViewState()

	static var previews: some View {
		HUDView()
			.environmentObject(state)
			.onAppear {
				Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
					self.state.isVisible = true
				}
			}
	}
}
