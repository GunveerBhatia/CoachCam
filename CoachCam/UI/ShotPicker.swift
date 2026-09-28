import SwiftUI

/// Top-left button: "<detected subject> · <your photo type>".
/// Tap to pick the photo type (only types that fit the subject are shown), or fix the
/// subject under "Wrong subject?". Your choice is remembered per subject category.
struct ShotPicker: View {
    @ObservedObject var describer: SceneDescriber
    @ObservedObject var store: PhotoTypeStore
    /// Names the main object, so the button says e.g. "keys" instead of "Object".
    @ObservedObject var objectNames: ObjectLabelTracker

    var body: some View {
        let category = store.effectiveCategory(detected: describer.category)
        let chosen = store.choice(for: category)
        Menu {
            if category == .general {
                Text("No clear subject yet. Pick one below.")
            } else {
                Section("Photo type · \(category.title)") {
                    ForEach(fittingTypes(for: category, chosen: chosen)) { type in
                        Button {
                            store.choose(type)
                        } label: {
                            if type == chosen {
                                Label(type.title, systemImage: "checkmark")
                            } else {
                                Text(type.title)
                            }
                        }
                    }
                }
            }
            Section("Wrong subject?") {
                Menu("Subject: \(category.title)\(store.categoryOverride == nil ? " (auto)" : "")") {
                    Button {
                        store.overrideCategory(nil)
                    } label: {
                        Label("Auto-detect", systemImage: store.categoryOverride == nil ? "checkmark" : "sparkles")
                    }
                    ForEach(SubjectCategory.allCases.filter { $0 != .general }) { c in
                        Button {
                            store.overrideCategory(c)
                        } label: {
                            if store.categoryOverride == c {
                                Label(c.title, systemImage: "checkmark")
                            } else {
                                Label(c.title, systemImage: c.icon)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                Text(subjectTitle(for: category))
                if category != .general {
                    Text("·").foregroundStyle(.white.opacity(0.6))
                    Text(chosen?.title ?? "Pick type")
                        .foregroundStyle(chosen == nil ? Color.yellow : Color.white)
                }
                if store.categoryOverride != nil {
                    Text("MANUAL")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                        .foregroundStyle(.black)
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .lineLimit(1)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(0.15), in: Capsule())
            .animation(.easeOut(duration: 0.15), value: category)
        }
    }

    /// "keys" / "pasta?" for objects and food (never just "Object"), otherwise the category.
    private func subjectTitle(for category: SubjectCategory) -> String {
        if category == .object || category == .food, let name = objectNames.mainName { return name }
        return category.title
    }

    /// Only the types that fit what's detected. "Mirror fit" needs a mirror cue
    /// (a phone held near the head), unless it's already your choice.
    private func fittingTypes(for category: SubjectCategory, chosen: PhotoType?) -> [PhotoType] {
        PhotoType.types(for: category).filter { type in
            if type == .mirrorFit { return describer.mirrorCue || chosen == .mirrorFit }
            return true
        }
    }
}
