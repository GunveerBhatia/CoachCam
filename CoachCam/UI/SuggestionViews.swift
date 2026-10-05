import SwiftUI

/// Top-left chip: what the camera thinks you're shooting ("keys", "People", "Food"…).
/// Tap it to fix the subject if detection is wrong.
struct SubjectChip: View {
    @ObservedObject var describer: SceneDescriber
    @ObservedObject var override: SubjectOverride
    @ObservedObject var objectNames: ObjectLabelTracker

    var body: some View {
        let category = override.effective(detected: describer.category)
        Menu {
            Section("Wrong subject?") {
                Button {
                    override.set(nil)
                } label: {
                    Label("Auto-detect", systemImage: override.category == nil ? "checkmark" : "sparkles")
                }
                ForEach(SubjectCategory.allCases.filter { $0 != .general }) { c in
                    Button {
                        override.set(c)
                    } label: {
                        if override.category == c { Label(c.title, systemImage: "checkmark") }
                        else { Label(c.title, systemImage: c.icon) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                Text(title(for: category))
                if override.category != nil {
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
    private func title(for category: SubjectCategory) -> String {
        if category == .object || category == .food, let name = objectNames.mainName { return name }
        return category.title
    }
}

/// The row of shot suggestion cards for the current subject, best fit first.
/// Tap a card to start its step-by-step walkthrough; tap ✕ to stop.
struct SuggestionCardsRow: View {
    @ObservedObject var ranker: SuggestionRanker

    var body: some View {
        if ranker.ranked.isEmpty {
            Text("Point at something to get shot ideas")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .frame(height: 62)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ranker.ranked) { item in
                        card(item.suggestion, selected: ranker.selected?.id == item.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 62)
            .animation(.easeOut(duration: 0.2), value: ranker.ranked)
        }
    }

    private func card(_ s: Playbook.Suggestion, selected: Bool) -> some View {
        Button {
            ranker.select(selected ? nil : s)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: s.icon)
                    .font(.system(size: 18))
                    .frame(width: 22)
                    .foregroundStyle(selected ? .black : .yellow)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(s.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        if s.burst != nil { Image(systemName: "square.stack.3d.down.forward").font(.system(size: 9)) }
                    }
                    Text(s.description).font(.system(size: 11)).lineLimit(2)
                        .foregroundStyle(selected ? .black.opacity(0.75) : .white.opacity(0.75))
                }
                if selected {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                }
            }
            .foregroundStyle(selected ? .black : .white)
            .padding(8)
            .frame(width: 170, height: 58, alignment: .topLeading)
            .background(selected ? Color.yellow : Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
