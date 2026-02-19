//
//  SettingsEnvironmentView.swift
//  NewTerm (iOS)
//

import SwiftUI
import NewTermCommon

struct SettingsEnvironmentView: View {

	@ObservedObject private var preferences = Preferences.shared

	@State private var isAddingVariable = false
	@State private var newKey = ""
	@State private var newValue = ""

	private var sortedEnv: [(key: String, value: String)] {
		preferences.extraEnvironment.sorted { $0.key < $1.key }
	}

	var body: some View {
		PreferencesList {
			PreferencesGroup(
				header: Text("Custom Variables"),
				footer: Text("These variables are injected into every new terminal session. Built-in variables (TERM, LANG, etc.) are set after custom ones and will override duplicates.")
			) {
				ForEach(sortedEnv, id: \.key) { item in
					KeyValueView(title: Text(item.key),
											 value: Text(item.value).foregroundColor(.secondary))
				}
				.onDelete { offsets in
					var env = preferences.extraEnvironment
					let keys = sortedEnv.map(\.key)
					for i in offsets {
						env.removeValue(forKey: keys[i])
					}
					preferences.extraEnvironment = env
				}

				Button(action: { isAddingVariable = true }) {
					HStack {
						Image(systemName: "plus.circle.fill")
						Text("Add Variable")
					}
				}
			}
		}
		.navigationBarTitle("Environment")
		.sheet(isPresented: $isAddingVariable) {
			NavigationView {
				Form {
					Section(header: Text("New Variable")) {
						TextField("NAME", text: $newKey)
							.autocapitalization(.allCharacters)
							.disableAutocorrection(true)
						TextField("value", text: $newValue)
							.disableAutocorrection(true)
					}
				}
				.navigationBarTitle("Add Variable", displayMode: .inline)
				.navigationBarItems(
					leading: Button("Cancel") {
						newKey = ""; newValue = ""; isAddingVariable = false
					},
					trailing: Button("Add") {
						guard !newKey.isEmpty else { return }
						var env = preferences.extraEnvironment
						env[newKey] = newValue
						preferences.extraEnvironment = env
						newKey = ""; newValue = ""; isAddingVariable = false
					}.disabled(newKey.isEmpty)
				)
			}
		}
	}
}

struct SettingsEnvironmentView_Previews: PreviewProvider {
	static var previews: some View {
		NavigationView {
			SettingsEnvironmentView()
		}
	}
}
