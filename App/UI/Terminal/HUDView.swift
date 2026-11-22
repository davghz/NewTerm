//
//  HUDView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 25/12/2022.
//

import SwiftUI

class HUDViewState: ObservableObject {
	@Published var isVisible = false
}

struct HUDView: View {
	@EnvironmentObject private var state: HUDViewState

	var body: some View {
		if state.isVisible {
			Image(systemName: "bell")
				.font(.system(size: 25, weight: .medium))
				.imageScale(.large)
				.frame(width: 54, height: 54)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
				.task {
					do {
						try await Task.sleep(nanoseconds: 750_000_000)
						withAnimation(.linear(duration: 0.3)) { state.isVisible = false }
					} catch { /* The HUD was removed. */ }
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
