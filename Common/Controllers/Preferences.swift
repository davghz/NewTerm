//
//  Preferences.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import Combine
import struct SwiftUI.Binding
import os.log

public enum KeyboardButtonStyle: Int {
	case text, icons
}

public enum KeyboardTrackpadSensitivity: Int, CaseIterable {
	case off, low, medium, high
}

public enum KeyboardArrowsStyle: Int, CaseIterable {
	case butterfly, scissor, classic, vim, vimInverted
}

public enum PreferencesSyncService: Int, Identifiable {
	case none, icloud, folder

	public var id: Self { self }
}

@propertyWrapper
public struct AppStorage<Value> {
	private let key: String
	private let defaultValue: Value
	private let store: UserDefaults

	public init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) {
		self.key = key
		self.defaultValue = wrappedValue
		self.store = store
	}

	public var wrappedValue: Value {
		get { (store.object(forKey: key) as? Value) ?? defaultValue }
		nonmutating set { store.set(newValue, forKey: key) }
	}

	public var projectedValue: Binding<Value> {
		Binding(get: { self.wrappedValue },
						set: { self.wrappedValue = $0 })
	}
}

@propertyWrapper
public struct AppStorageEnum<Value: RawRepresentable> where Value.RawValue == Int {
	private let key: String
	private let defaultValue: Value
	private let store: UserDefaults

	public init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) {
		self.key = key
		self.defaultValue = wrappedValue
		self.store = store
	}

	public var wrappedValue: Value {
		get {
			if let rawValue = store.object(forKey: key) as? Int,
			   let value = Value(rawValue: rawValue) {
				return value
			}
			return defaultValue
		}
		nonmutating set { store.set(newValue.rawValue, forKey: key) }
	}

	public var projectedValue: Binding<Value> {
		Binding(get: { self.wrappedValue },
						set: { self.wrappedValue = $0 })
	}
}

public class Preferences: NSObject, ObservableObject {

	public static let didChangeNotification = Notification.Name(rawValue: "NewTermPreferencesDidChangeNotification")

	public static let shared = Preferences()

	@Published public private(set) var fontMetrics = FontMetrics(font: AppFont(), fontSize: 12) {
		willSet { objectWillChange.send() }
	}
	@Published public private(set) var colorMap = ColorMap(theme: AppTheme()) {
		willSet { objectWillChange.send() }
	}

	override init() {
		super.init()

		if let version = Bundle.main.infoDictionary!["CFBundleVersion"] as? String {
			lastVersion = Int(version) ?? 0
		}

		fontMetricsChanged()
		colorMapChanged()

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(self.contentSizeCategoryDidChange),
			name: UIContentSizeCategory.didChangeNotification,
			object: nil
		)
	}

	@objc private func contentSizeCategoryDidChange() {
		if followSystemTextSize {
			fontMetricsChanged()
		}
	}

	@AppStorage("fontName")
	public var fontName: String = "SF Mono" {
		willSet { objectWillChange.send() }
		didSet { fontMetricsChanged() }
	}

	// TODO: Public just for testing, make it private later
	@AppStorage("fontSizePhone")
	public var fontSizePhone: Double = 12 {
		willSet { objectWillChange.send() }
		didSet { fontMetricsChanged() }
	}

	@AppStorage("fontSizePad")
	private var fontSizePad: Double = 13 {
		willSet { objectWillChange.send() }
		didSet { fontMetricsChanged() }
	}

	@AppStorage("fontSizeMac")
	public var fontSizeMac: Double = 13 {
		willSet { objectWillChange.send() }
		didSet { fontMetricsChanged() }
	}

	// TODO: Make this act like a DynamicProperty
	public var fontSize: Double {
		get {
			#if targetEnvironment(macCatalyst)
			return fontSizeMac
			#else
			return isBigDevice ? fontSizePad : fontSizePhone
			#endif
		}
		set {
			#if targetEnvironment(macCatalyst)
			fontSizeMac = newValue
			#else
			if isBigDevice {
				fontSizePad = newValue
			} else {
				fontSizePhone = newValue
			}
			#endif
		}
	}

	@AppStorage("themeName")
	public var themeName: String = "Basic (Dark)" {
		willSet { objectWillChange.send() }
		didSet { colorMapChanged() }
	}

	@AppStorageEnum("keyboardAccessoryStyle")
	public var keyboardAccessoryStyle: KeyboardButtonStyle = .text {
		willSet { objectWillChange.send() }
	}

	@AppStorageEnum("keyboardTrackpadSensitivity")
	public var keyboardTrackpadSensitivity: KeyboardTrackpadSensitivity = .medium {
		willSet { objectWillChange.send() }
	}

	@AppStorageEnum("keyboardArrowsStyle")
	public var keyboardArrowsStyle: KeyboardArrowsStyle = .butterfly {
		willSet { objectWillChange.send() }
	}

	/// When true, keyboard input is broadcast to every open terminal session simultaneously.
	@AppStorage("broadcastInput")
	public var broadcastInput: Bool = false {
		willSet { objectWillChange.send() }
	}

	@AppStorage("confirmMultiLinePaste")
	public var confirmMultiLinePaste: Bool = true {
		willSet { objectWillChange.send() }
	}

	@AppStorage("copyOnSelect")
	public var copyOnSelect: Bool = false {
		willSet { objectWillChange.send() }
	}

	@AppStorage("followSystemTextSize")
	public var followSystemTextSize: Bool = false {
		willSet { objectWillChange.send() }
		didSet { fontMetricsChanged() }
	}

	@AppStorage("bellHUD")
	public var bellHUD: Bool = true {
		willSet { objectWillChange.send() }
	}

	@AppStorage("bellVibrate")
	public var bellVibrate: Bool = true {
		willSet { objectWillChange.send() }
	}

	@AppStorage("bellSound")
	public var bellSound: Bool = true {
		willSet { objectWillChange.send() }
	}

	@AppStorage("refreshRateOnAC")
	public var refreshRateOnAC: Int = 60 {
		willSet { objectWillChange.send() }
	}

	@AppStorage("refreshRateOnBattery")
	public var refreshRateOnBattery: Int = 60 {
		willSet { objectWillChange.send() }
	}

	@AppStorage("reduceRefreshRateInLPM")
	public var reduceRefreshRateInLPM: Bool = true {
		willSet { objectWillChange.send() }
	}

	@AppStorageEnum("preferencesSyncService")
	public var preferencesSyncService: PreferencesSyncService = .icloud {
		willSet { objectWillChange.send() }
	}

	@AppStorage("preferencesSyncPath")
	public var preferencesSyncPath: String = "" {
		willSet { objectWillChange.send() }
	}

	@AppStorage("preferredLocale")
	public var preferredLocale: String = "" {
		willSet { objectWillChange.send() }
	}

	/// Extra environment variables injected at shell launch, stored as JSON-encoded [String:String].
	@AppStorage("extraEnvironmentJSON")
	private var extraEnvironmentJSON: String = "{}" {
		willSet { objectWillChange.send() }
	}

	public var extraEnvironment: [String: String] {
		get {
			(try? JSONDecoder().decode([String: String].self,
																from: extraEnvironmentJSON.data(using: .utf8) ?? Data())) ?? [:]
		}
		set {
			extraEnvironmentJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}"
		}
	}

	@AppStorage("lastVersion")
	public var lastVersion: Int = 0 {
		willSet { objectWillChange.send() }
	}

	public var userInterfaceStyle: UIUserInterfaceStyle { colorMap.userInterfaceStyle }

	/// Timestamp of the last successful iCloud sync (pull).
	@AppStorage("iCloudLastSyncDate")
	public var iCloudLastSyncDate: Double = 0 {
		willSet { objectWillChange.send() }
	}

	// MARK: - iCloud Sync

	/// Keys synced to iCloud KV store. Excludes device-specific prefs (refresh rate, etc.).
	private static let iCloudSyncedKeys: [String] = [
		"fontName", "fontSizePhone", "fontSizePad", "fontSizeMac",
		"themeName",
		"keyboardArrowsStyle", "keyboardTrackpadSensitivity",
		"confirmMultiLinePaste", "copyOnSelect",
		"bellHUD", "bellVibrate", "bellSound",
		"preferredLocale"
	]

	public func startICloudSync() {
		guard preferencesSyncService == .icloud else { return }
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(self.iCloudStoreDidChange(_:)),
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: NSUbiquitousKeyValueStore.default
		)
		// Pull remote values on startup.
		NSUbiquitousKeyValueStore.default.synchronize()
		applyICloudValues()
	}

	/// Push all synced prefs to iCloud KV store.
	public func pushToICloud() {
		guard preferencesSyncService == .icloud else { return }
		let store = NSUbiquitousKeyValueStore.default
		for key in Self.iCloudSyncedKeys {
			if let value = UserDefaults.standard.object(forKey: key) {
				store.set(value, forKey: key)
			}
		}
		store.synchronize()
	}

	@objc private func iCloudStoreDidChange(_ notification: Notification) {
		applyICloudValues()
	}

	/// Pull values from iCloud KV store into UserDefaults, then refresh state.
	private func applyICloudValues() {
		let store = NSUbiquitousKeyValueStore.default
		var changed = false
		for key in Self.iCloudSyncedKeys {
			if let remote = store.object(forKey: key) {
				let local = UserDefaults.standard.object(forKey: key)
				// Only apply if different to avoid spurious KVO/objectWillChange noise.
				if (local as? AnyHashable) != (remote as? AnyHashable) {
					UserDefaults.standard.set(remote, forKey: key)
					changed = true
				}
			}
		}
		if changed {
			DispatchQueue.main.async {
				self.iCloudLastSyncDate = Date().timeIntervalSinceReferenceDate
				self.fontMetricsChanged()
				self.colorMapChanged()
				self.objectWillChange.send()
				NotificationCenter.default.post(name: Preferences.didChangeNotification, object: nil)
			}
		}
	}

	// MARK: - Handlers

	private func fontMetricsChanged() {
		let font = AppFont.predefined[fontName] ?? AppFont()
		FontMetrics.loadFonts(for: font)
		objectWillChange.send()
		var resolvedSize = CGFloat(fontSize)
		if followSystemTextSize {
			// Scale the user's chosen base size by the current Dynamic Type ratio.
			// UIFontMetrics.default scales relative to the Large (default) category.
			let baseFont = UIFont.systemFont(ofSize: resolvedSize)
			let scaled = UIFontMetrics.default.scaledValue(for: resolvedSize,
																										 compatibleWith: UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory))
			resolvedSize = min(max(scaled, 10), 28)
			_ = baseFont // suppress unused warning
		}
		fontMetrics = FontMetrics(font: font, fontSize: resolvedSize)
	}

	private func colorMapChanged() {
		let theme = AppTheme.predefined[themeName] ?? AppTheme()
		objectWillChange.send()
		colorMap = ColorMap(theme: theme)
	}

}
