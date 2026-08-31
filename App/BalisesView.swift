import SwiftUI

/// Gestion des balises suivies : ajout par URL balisemeteo.com, suppression,
/// sélection de celle qui est affichée.
struct BalisesView: View {
    @ObservedObject var store: WindStore
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var addedName: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.catalog.balises) { balise in
                        Button {
                            Task {
                                await store.select(baliseID: balise.id)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(balise.name).foregroundStyle(.primary)
                                    Text(balise.subtitle)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if balise.id == store.catalog.selectedID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.catalog.balises[$0].id }
                        Task { for id in ids { await store.removeBalise(id: id) } }
                    }
                } header: {
                    Text("Balises suivies")
                } footer: {
                    Text(store.catalog.balises.count > 1
                         ? "Glisse vers la gauche pour retirer une balise. La dernière ne peut pas être supprimée."
                         : "Le serveur relève toutes les balises de cette liste ; seule celle qui est cochée déclenche l'activité en direct et les alertes.")
                }

                Section {
                    TextField("balisemeteo.com/balise.php?idBalise=…", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit { add() }

                    Button {
                        add()
                    } label: {
                        HStack {
                            if isAdding {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                            Text("Ajouter cette balise")
                        }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let addedName {
                        Label("\(addedName) ajoutée", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    }
                } header: {
                    Text("Ajouter")
                } footer: {
                    Text("Colle l'adresse de la balise depuis balisemeteo.com, ou tape simplement son numéro. L'app vérifie qu'elle existe et récupère son nom et son altitude.")
                }
            }
            .navigationTitle("Balises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    private func add() {
        let value = input
        errorMessage = nil
        addedName = nil
        isAdding = true
        Task {
            do {
                let balise = try await store.addBalise(from: value)
                addedName = balise.name
                input = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isAdding = false
        }
    }
}
