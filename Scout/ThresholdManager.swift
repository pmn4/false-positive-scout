import Foundation
import SwiftUI

// "I never sleep, 'cause sleep is the cousin of death" ~Nas (probably)
// Confidence threshold management with per-class overrides

class ThresholdManager: ObservableObject {
    static let shared = ThresholdManager()
    
    @Published var overallThreshold: Float = 0.4
    @Published var classOverrides: [String: Float] = [:]
    
    private let overallKey = "scout_confidence"
    private let overridesKey = "scout_class_overrides"
    
    private init() {
        loadThresholds()
    }
    
    func effectiveThreshold(for className: String) -> Float {
        return classOverrides[className] ?? overallThreshold
    }
    
    func setOverride(for className: String, threshold: Float?) {
        if let threshold = threshold {
            classOverrides[className] = threshold
        } else {
            classOverrides.removeValue(forKey: className)
        }
        saveOverrides()
    }
    
    func clearAllOverrides() {
        classOverrides.removeAll()
        saveOverrides()
    }
    
    func updateOverallThreshold(_ threshold: Float) {
        overallThreshold = threshold
        saveOverallThreshold()
    }
    
    private func loadThresholds() {
        let storedPercent = UserDefaults.standard.integer(forKey: overallKey)
        if storedPercent > 0 {
            overallThreshold = Float(storedPercent) / 100.0
        } else {
            overallThreshold = 0.4
        }
        
        if let data = UserDefaults.standard.data(forKey: overridesKey),
           let decoded = try? JSONDecoder().decode([String: Float].self, from: data) {
            classOverrides = decoded
        }
    }
    
    private func saveOverallThreshold() {
        let percent = Int(overallThreshold * 100)
        UserDefaults.standard.set(percent, forKey: overallKey)
    }
    
    private func saveOverrides() {
        if let encoded = try? JSONEncoder().encode(classOverrides) {
            UserDefaults.standard.set(encoded, forKey: overridesKey)
        }
    }
}
