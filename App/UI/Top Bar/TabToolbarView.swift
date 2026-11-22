//
//  TabToolbar.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 3/8/2022.
//

import SwiftUI
import SwiftUIX
import NewTermCommon

struct TerminalTab: Hashable {
	var title: String
	var screenSize: ScreenSize
	var isDirty: Bool
	var hasBell: Bool
}

class TabToolbarState: ObservableObject {
	@Published var delegate: TabToolbarDelegate?
	@Published var terminals = [TerminalTab]()
	@Published var selectedIndex = 0
}

struct TabToolbarView: View {

	private static let height: CGFloat = 32

	@EnvironmentObject private var state: TabToolbarState

	static func usesSingleRow(width: CGFloat) -> Bool {
		isBigDevice || width > 450
	}

	var body: some View {
		GeometryReader { bounds in
			if !Self.usesSingleRow(width: bounds.size.width) {
				VStack(spacing: 2) {
					HStack(alignment: .center, spacing: 6) {
						Color.clear
							.frame(width: 3 + (Self.height + 6) * 3)
						titleLabel
						buttons
					}
						.frame(height: Self.height)
					tabs
						.frame(height: Self.height)
				}
			} else {
				HStack(alignment: .center, spacing: 6) {
					tabs
					buttons
				}
					.frame(height: Self.height)
			}
		}
	}

	private var tabs: some View {
		ScrollViewReader { proxy in
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 0) {
					ForEach(Array(zip(state.terminals, state.terminals.indices)), id: \.1) { terminal, index in
						TabToolbarItemView(terminal: terminal,
															 isSelected: state.selectedIndex == index,
															 height: Self.height,
															 selectTerminal: { state.delegate?.selectTerminal(at: index) },
															 removeTerminal: { state.delegate?.removeTerminal(at: index) })
							.id(index)
					}
				}
			}
			.onChange(of: state.selectedIndex) { index in
				proxy.scrollTo(index)
			}
		}
	}

	private var titleLabel: some View {
		HStack {
			Spacer()
			Text(state.terminals.indices.contains(state.selectedIndex) ? state.terminals[state.selectedIndex].title : "")
				.font(.system(size: 17, weight: .semibold))
			Spacer()
		}
	}

	private var buttons: some View {
		HStack(spacing: 0) {
				Button(role: nil, action: { state.delegate?.openPasswordManager() },
							 label: { Image(systemName: "key.fill") })
					.squareFrame(sideLength: Self.height)
					.padding(.horizontal, 3)
					.accessibility(label: Text("Password Manager"))

				Button(role: nil, action: { state.delegate?.openSettings() },
							 label: { Image(systemName: "gear") })
					.squareFrame(sideLength: Self.height)
					.padding(.horizontal, 3)
					.accessibility(label: Text("Settings"))

				Button(role: nil, action: { state.delegate?.addTerminal() },
							 label: { Image(systemName: "plus") })
					.squareFrame(sideLength: Self.height)
					.padding(.horizontal, 3)
					.padding(.trailing, 3)
					.accessibility(label: Text("New Tab"))
			}
			.foregroundColor(.accentColor)
			.font(.system(size: 17 * 0.9, weight: .medium))
			.imageScale(.large)
	}

}

struct TabToolbarItemView: View {
	var terminal: TerminalTab
	var isSelected: Bool
	var height: CGFloat
	var selectTerminal: () -> Void
	var removeTerminal: () -> Void

	var body: some View {
		let accessibilityLabel: String
		switch true {
		case terminal.hasBell: accessibilityLabel = "\(terminal.title), \(String.localize("has bell"))"
		case terminal.isDirty: accessibilityLabel = "\(terminal.title), \(String.localize("has activity"))"
		default:               accessibilityLabel = terminal.title
		}

		return HStack(spacing: 0) {
			Button(role: nil, action: removeTerminal) {
				Image(systemName: terminal.hasBell ? "bell.fill" : terminal.isDirty ? "circle.fill" : "xmark.square.fill")
					.font(.system(size: terminal.hasBell ? 13 : terminal.isDirty ? 11 : 14))
					.foregroundColor(.label.opacity(terminal.hasBell ? 1 : 0.5))
					.frame(width: height, height: height)
					.contentShape(Rectangle())
			}
			.accessibilityLabel(Text("Close Tab"))

			Button(role: nil, action: selectTerminal) {
				Text(terminal.title)
					.font(.system(size: 12, weight: .semibold))
					.foregroundColor(.label)
					.padding(.trailing, 10)
					.frame(minWidth: height, minHeight: height)
					.contentShape(Rectangle())
			}
			.accessibilityLabel(Text(accessibilityLabel))
			.accessibilityAddTraits(isSelected ? .isSelected : [])
		}
		.buttonStyle(.plain)
		.background(isSelected ? Color(.tabSelected) : nil)
	}
}

struct TabToolbarView_Previews: PreviewProvider {
	static var previews: some View {
		let state = TabToolbarState()
		state.selectedIndex = 0
		state.terminals = [
			TerminalTab(title: "nano",
									screenSize: ScreenSize(cols: 80, rows: 25),
								  isDirty: false,
								  hasBell: false),
			TerminalTab(title: "mobile@iphone: ~",
									screenSize: ScreenSize(cols: 80, rows: 25),
									isDirty: true,
									hasBell: true),
			TerminalTab(title: "ssh",
									screenSize: ScreenSize(cols: 80, rows: 25),
									isDirty: true,
									hasBell: false),
		]

		return VStack {
			TabToolbarView()
				.environmentObject(state)
				.background(BlurEffectView(style: .systemChromeMaterial))
			Spacer()
		}
	}
}
