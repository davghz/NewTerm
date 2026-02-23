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

	@AppStorage("maximumRenderedLines")
	public var maximumRenderedLines: Int = 3000 {
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

	@AppStorage("lastVersion")
	public var lastVersion: Int = 0 {
		willSet { objectWillChange.send() }
	}

	public var userInterfaceStyle: UIUserInterfaceStyle { colorMap.userInterfaceStyle }

	// MARK: - Handlers

	private func fontMetricsChanged() {
		let font = AppFont.predefined[fontName] ?? AppFont()
		objectWillChange.send()
		fontMetrics = FontMetrics(font: font, fontSize: CGFloat(fontSize))
	}

	private func colorMapChanged() {
		let theme = AppTheme.predefined[themeName] ?? AppTheme()
		objectWillChange.send()
		colorMap = ColorMap(theme: theme)
	}

}
