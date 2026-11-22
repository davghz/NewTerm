//
//  SettingsAboutView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 3/4/21.
//

import SwiftUI
import SwiftUIX

struct SettingsAboutView: View {

	var windowScene: UIWindowScene?

	private let version: String = {
		let info = Bundle.main.infoDictionary!
		return "\(info["CFBundleShortVersionString"] as! String) (\(info["CFBundleVersion"] as! String))"
	}()

	@State private var showingAcknowledgements = false
	@State private var showingShare = false

	private func openURL(_ url: URL) {
		UIApplication.shared.open(url, options: [:], completionHandler: nil)
	}

	var body: some View {
		let supportURL = URL(string: "https://github.com/davghz/NewTerm/issues")!

		let guts = ScrollView {
			VStack(spacing: 15) {
					LogoHeaderViewRepresentable()
						.frame(height: 200)
						.edgesIgnoringSafeArea(.all)

				Text("t3rm \(version)")
					.padding(EdgeInsets(top: 15, leading: 15, bottom: 15, trailing: 15))
					.font(.system(size: 16, weight: .semibold))

				VStack(alignment: .leading, spacing: 15) {
					Text("This is a beta — thanks for trying it out! If you find any issues, please let us know.")
						.fixedSize(horizontal: false, vertical: true)
						.padding(EdgeInsets(top: 5, leading: 15, bottom: 5, trailing: 15))
						.font(.system(size: 14))

						Button(role: nil, action: { openURL(supportURL) },
									 label: {
							HStack {
								IconView(icon: Image(systemName: "envelope").resizable(),
												 backgroundColor: .blue)
								Text("Email Support")
							}
						})
							.buttonStyle(GroupedButtonStyle())
				}

				VStack(alignment: .leading, spacing: 15) {
					SponsorsView()
						.fixedSize(horizontal: false, vertical: true)
						.padding(EdgeInsets(top: 5, leading: 15, bottom: 5, trailing: 15))
						.font(.system(size: 14))

						Button(role: nil, action: { openURL(URL(string: "https://hashbang.productions/donate/")!) },
									 label: {
							HStack {
								IconView(icon: Image(systemName: "heart").resizable(),
												 backgroundColor: .red)
								Text("Support NewTerm Development")
							}
						})
							.buttonStyle(GroupedButtonStyle())

						Button(role: nil, action: { showingShare.toggle() },
									 label: {
							HStack {
								IconView(icon: Image(systemName: "square.and.arrow.up").resizable(),
												 backgroundColor: .systemIndigo)
								Text("Share t3rm")
							}
						})
							.buttonStyle(GroupedButtonStyle())
						.activityView(isPresented: $showingShare,
													activityItems: [
														String.localize("t3rm for rootless iOS 15"),
														URL(string: "https://github.com/davghz/NewTerm")!
													])
				}

				NavigationLink(destination: SettingsAcknowledgementsView(),
											 label: {
					HStack {
						Spacer()
						Text("License & Acknowlegements")
							.font(.system(size: 12))
							.buttonStyle(PlainButtonStyle())
						Spacer()
					}
				})
					.padding(EdgeInsets(top: 15, leading: 15, bottom: 0, trailing: 15))

				Divider()
					.padding(15)
					.fixedSize(horizontal: false, vertical: true)

					Button(role: nil, action: { openURL(URL(string: "https://hashbang.productions/")!) },
								 label: {
						VStack {
							Image("hashbang")
							Text("© HASHBANG Productions")
							.foregroundColor(.secondary)
							.padding(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
							.multilineTextAlignment(.center)
							.font(.system(size: 12, weight: .regular))
					}
					})
						.buttonStyle(PlainButtonStyle())
						.padding()

				Text("Dedicated to Dennis Bednarz (2000 – 2019), a friend and visionary of the iOS community taken from us too soon.")
					.fixedSize(horizontal: false, vertical: true)
					.frame(width: 260)
					.foregroundColor(.secondary)
					.padding(15)
					.multilineTextAlignment(.center)
					.font(.system(size: 12, weight: .regular))
			}
		}

		if windowScene == nil {
			return AnyView(
				guts
					.navigationBarTitle("", displayMode: .inline)
					.background(.systemGroupedBackground)
			)
		} else {
			return AnyView(
					NavigationView {
						guts
							.edgesIgnoringSafeArea(.top)
					}
					.navigationViewStyle(StackNavigationViewStyle())
					.navigationBarHidden(true)
			)
		}
	}
}

struct SettingsAboutView_Previews: PreviewProvider {
	static var previews: some View {
		NavigationView {
			SettingsAboutView()
		}
		NavigationView {
			SettingsAboutView()
		}
			.previewDevice("iPod touch (7th generation)")
	}
}
