import SwiftUI

/// The subject label (top left): what the camera locked onto ("woman", "keys", "Food"…).
/// Hidden while searching. Tap it to correct the name/type, fix the subject, or unlock.
struct SubjectChip: View {
    @ObservedObject var stage: StageMachine
    @ObservedObject var override: SubjectOverride
    @ObservedObject var objectNames: ObjectLabelTracker
    @ObservedObject var personTypes: PersonTypeTracker
    let subjects: SubjectTracker
    let onUnlock: () -> Void
    let onForce: (SubjectCategory?) -> Void
    let onRename: (ObjectLabel, String) -> Void

    @State private var renaming: ObjectLabel?
    @State private var typedName = ""

    var body: some View {
        if stage.stage != .searching {
            Menu {
                if let person = lockedPersonLabel {
                    Section("Who is this?") {
                        ForEach(PersonType.estimable) { type in
                            Button(type.rawValue) { personTypes.correct(id: person.id, to: type) }
                        }
                    }
                } else if let object = lockedObjectLabel {
                    Section("What is this?") {
                        ForEach(object.alternatives.filter { $0 != object.name }, id: \.self) { name in
                            Button(name) { onRename(object, name) }
                        }
                        Button("Type a name…") { typedName = object.name; renaming = object }
                    }
                }
                Section("Wrong subject?") {
                    Button { onForce(nil) } label: {
                        Label("Auto-detect", systemImage: override.category == nil ? "checkmark" : "sparkles")
                    }
                    ForEach(SubjectCategory.allCases.filter { $0 != .general }) { c in
                        Button { onForce(c) } label: {
                            if override.category == c { Label(c.title, systemImage: "checkmark") }
                            else { Label(c.title, systemImage: c.icon) }
                        }
                    }
                }
                Button(role: .destructive) { onUnlock() } label: { Label("Unlock subject", systemImage: "xmark") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: stage.lockedCategory.icon)
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(.black.opacity(0.35), in: Capsule())
            }
            .alert("Name this object", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("e.g. car keys", text: $typedName)
                Button("Save") { if let object = renaming { onRename(object, typedName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private var lockedBox: CGRect? { subjects.subject?.box }

    private var lockedPersonLabel: PersonLabel? {
        guard stage.lockedCategory == .people, let box = lockedBox else { return nil }
        return personTypes.labels.first { box.contains($0.faceBox.center) }
    }

    private var lockedObjectLabel: ObjectLabel? {
        guard stage.lockedCategory == .object || stage.lockedCategory == .food, let box = lockedBox else { return nil }
        return objectNames.labels.max { $0.box.iou(box) < $1.box.iou(box) }
    }

    /// "woman", "keys", "pasta?", or the category name.
    private var title: String {
        if let person = lockedPersonLabel { return person.type.rawValue }
        if let object = lockedObjectLabel { return object.displayName }
        return stage.lockedCategory.title
    }
}

/// Suggestion cards, shown only while LOCKED. Computed once at lock (frozen). The first card
/// is pre-selected and starts by itself unless you tap another one.
struct SuggestionCardsRow: View {
    @ObservedObject var stage: StageMachine
    let onPick: (Playbook.Suggestion) -> Void

    var body: some View {
        if stage.stage == .locked && !stage.cards.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stage.cards) { item in
                        card(item.suggestion, highlighted: stage.active?.id == item.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 62)
            .transition(.opacity)
        } else {
            Color.clear.frame(height: 62)
        }
    }

    private func card(_ s: Playbook.Suggestion, highlighted: Bool) -> some View {
        Button { onPick(s) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: s.icon)
                    .font(.system(size: 18))
                    .frame(width: 22)
                    .foregroundStyle(highlighted ? .black : .yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(s.description).font(.system(size: 11)).lineLimit(2)
                        .foregroundStyle(highlighted ? .black.opacity(0.75) : .white.opacity(0.75))
                }
            }
            .foregroundStyle(highlighted ? .black : .white)
            .padding(8)
            .frame(width: 170, height: 58, alignment: .topLeading)
            .background(highlighted ? Color.yellow : Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
