import SwiftUI

// "I switched my motto; instead of sayin' f— tomorrow, that buck that bought a bottle could've struck the lotto" ~Nas (probably)
// Live confidence threshold controls with per-class overrides

struct ThresholdControlSheet: View {
    @ObservedObject var thresholdManager: ThresholdManager
    @ObservedObject var modelManager: ModelManager
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            Form {
                OverallThresholdSection(thresholdManager: thresholdManager)
                
                if !modelManager.classLabels.isEmpty {
                    PerClassOverridesSection(
                        thresholdManager: thresholdManager,
                        classLabels: modelManager.classLabels
                    )
                } else {
                    EmptyClassLabelsSection()
                }
            }
            .navigationTitle("Detection Thresholds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reset Overrides") {
                        thresholdManager.clearAllOverrides()
                    }
                    .disabled(thresholdManager.classOverrides.isEmpty)
                }
            }
        }
    }
}

struct OverallThresholdSection: View {
    @ObservedObject var thresholdManager: ThresholdManager
    
    var body: some View {
        Section {
            VStack(spacing: 12) {
                HStack {
                    Text("Overall Threshold")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(thresholdManager.overallThreshold * 100))%")
                        .font(.headline)
                        .foregroundColor(.blue)
                }
                
                Slider(
                    value: Binding(
                        get: { Double(thresholdManager.overallThreshold) },
                        set: { thresholdManager.updateOverallThreshold(Float($0)) }
                    ),
                    in: 0...1,
                    step: 0.05
                )
                
                Text("Classes without overrides use this threshold")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Default")
        }
    }
}

struct PerClassOverridesSection: View {
    @ObservedObject var thresholdManager: ThresholdManager
    let classLabels: [String]
    
    var body: some View {
        Section {
            ForEach(classLabels, id: \.self) { className in
                ClassThresholdRow(
                    thresholdManager: thresholdManager,
                    className: className
                )
            }
        } header: {
            Text("Per-Class Overrides")
        } footer: {
            Text("Set custom thresholds for individual classes. Tap a class to toggle its override.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct EmptyClassLabelsSection: View {
    var body: some View {
        Section {
            Text("No class labels available. Class labels will appear here once the model runs.")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("Per-Class Overrides")
        }
    }
}

struct ClassThresholdRow: View {
    @ObservedObject var thresholdManager: ThresholdManager
    let className: String
    @State private var showSlider = false
    
    private var hasOverride: Bool {
        thresholdManager.classOverrides[className] != nil
    }
    
    private var effectiveThreshold: Float {
        thresholdManager.effectiveThreshold(for: className)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            Button(action: {
                withAnimation {
                    showSlider.toggle()
                    if !showSlider && hasOverride {
                        thresholdManager.setOverride(for: className, threshold: nil)
                    }
                }
            }) {
                HStack {
                    Text(className)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if hasOverride {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .imageScale(.small)
                    }
                    
                    Text("\(Int(effectiveThreshold * 100))%")
                        .foregroundColor(hasOverride ? .green : .secondary)
                        .font(.subheadline)
                    
                    Image(systemName: showSlider ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .foregroundColor(.secondary)
                }
            }
            
            if showSlider {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { Double(hasOverride ? thresholdManager.classOverrides[className]! : thresholdManager.overallThreshold) },
                            set: { newValue in
                                thresholdManager.setOverride(for: className, threshold: Float(newValue))
                            }
                        ),
                        in: 0...1,
                        step: 0.05
                    )
                    .tint(.green)
                    
                    Text(hasOverride ? "Custom: \(Int(effectiveThreshold * 100))%" : "Using overall: \(Int(thresholdManager.overallThreshold * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ThresholdControlSheet(
        thresholdManager: ThresholdManager.shared,
        modelManager: ModelManager.shared,
        isPresented: .constant(true)
    )
}
