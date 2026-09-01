import SwiftUI

/// Gestion des balises suivies : ajout, suppression, choix de celle qui s'affiche.
///
/// Les deux sources ne s'ajoutent pas de la même façon — la FFVL a une URL par
/// balise, Wind Morbihan publie une liste de capteurs dans laquelle on pioche.
struct BalisesView: View {
    @ObservedObject var store: WindStore
    @Environment(\.dismiss) private var dismiss

    @State private var source: BaliseProvider = .ffvl
    @State private var input = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var addedName: String?

    @State private var sensors: [Balise] = []
    @State private var isLoadingSensors = false
    @State private var search = ""
    @State private var results: [Balise] = []
    @State private var distances: [Int: Double] = [:]
    @State private var indexNote: String?
    @StateObject private var location = LocationProvider()

    /// La recherche s'exécute chez la source choisie dans le sélecteur.
    private var searchProvider: BaliseProvider { source }

    private var filteredSensors: [Balise] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sensors }
        return sensors.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Form {
                suivies
                sourcePicker
                switch source {
                case .ffvl: ajoutParLien
                case .windguru, .meteoCat: ajoutParRecherche
                case .windMorbihan: ajoutWindMorbihan
                }
            }
            .navigationTitle("Balises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task(id: source) {
                if source == .windMorbihan && sensors.isEmpty { await loadSensors() }
            }
        }
    }

    // MARK: Sections

    private var suivies: some View {
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
                            Text(balise.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if balise.id == store.catalog.selectedID {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
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
    }

    private var sourcePicker: some View {
        Section {
            Picker("Source", selection: $source) {
                ForEach(BaliseProvider.allCases, id: \.self) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            Text(source.detail).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Ajouter depuis")
        }
    }

    private var ajoutParLien: some View {
        Section {
            TextField("balisemeteo.com/balise.php?idBalise=…", text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .onSubmit { addFFVL() }

            Button {
                addFFVL()
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

            statusLines
        } footer: {
            Text("Colle l'adresse de la balise depuis balisemeteo.com, ou tape simplement son numéro. L'app vérifie qu'elle existe et récupère son nom et son altitude.")
        }
    }

    private var ajoutParRecherche: some View {
        Section {
            TextField(source == .meteoCat
                      ? "Rechercher (Montsec, Àger…) ou coller un lien"
                      : "Rechercher (Tarifa, Leucate…) ou coller un lien", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { runSearch() }

            if search.contains("windguru.cz") || search.contains("meteo.cat") {
                Button {
                    addLink(source: searchProvider, value: search)
                } label: {
                    Label("Ajouter cette station", systemImage: "plus.circle.fill")
                }
                .disabled(isAdding)
            } else {
                Button("Chercher") { runSearch() }
                    .disabled(search.trimmingCharacters(in: .whitespaces).count < 2 || isLoadingSensors)
            }

            if source == .windguru {
            HStack(spacing: 14) {
                Button {
                    Task { await searchNearMe() }
                } label: {
                    Label("Autour de moi", systemImage: "location.fill")
                }
                if let lat = store.balise.latitude, let lon = store.balise.longitude {
                    Button {
                        Task { await searchNear(lat: lat, lon: lon) }
                    } label: {
                        Label("Autour de \(store.balise.name)", systemImage: "mappin.and.ellipse")
                            .lineLimit(1)
                    }
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            }

            if isLoadingSensors {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Recherche…").foregroundStyle(.secondary)
                }
            }

            ForEach(results) { station in
                Button {
                    Task {
                        _ = await store.addBalise(station)
                        addedName = station.name
                        errorMessage = nil
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.name).foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                if let km = distances[station.id] {
                                    Text("\(Int(km)) km")
                                }
                                if let alt = station.altitude {
                                    Text("\(alt) m")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.catalog.balises.contains(where: { $0.key == station.key }) {
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                    }
                }
            }

            if let indexNote {
                Text(indexNote).font(.caption2).foregroundStyle(.tertiary)
            }
            statusLines
        } footer: {
            Text(source == .meteoCat
                 ? "Le réseau XEMA couvre la Catalogne — Montsec d'Ares pour Àger, et 188 autres stations. Cherche par nom ou par code, ou colle une adresse meteo.cat/observacions/xema/dades?codi=…."
                 : "Windguru couvre le monde entier — Tarifa / Campo de Futbol, Leucate, Almanarre… Tu peux chercher par nom, ou coller directement une adresse windguru.cz/station/….")
        }
    }

    private var ajoutWindMorbihan: some View {
        Section {
            if isLoadingSensors {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Chargement des capteurs…").foregroundStyle(.secondary)
                }
            } else if sensors.isEmpty {
                Button("Réessayer") { Task { await loadSensors() } }
            } else {
                TextField("Rechercher un capteur", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                ForEach(filteredSensors) { sensor in
                    Button {
                        Task {
                            _ = await store.addBalise(sensor)
                            addedName = sensor.name
                            errorMessage = nil
                        }
                    } label: {
                        HStack {
                            Text(sensor.name).foregroundStyle(.primary)
                            Spacer()
                            if store.catalog.balises.contains(where: { $0.key == sensor.key }) {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "plus.circle").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            statusLines
        } footer: {
            Text("Wind Morbihan couvre la baie de Quiberon et le sud Bretagne. Les vitesses y sont publiées en nœuds et converties automatiquement.")
        }
    }

    @ViewBuilder
    private var statusLines: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if let addedName {
            Label("\(addedName) ajoutée", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
        }
    }

    // MARK: Actions

    private func addFFVL() { addLink(source: .ffvl, value: input) }

    private func addLink(source: BaliseProvider, value: String) {
        errorMessage = nil
        addedName = nil
        isAdding = true
        Task {
            do {
                let balise = try await store.addBalise(from: value, fallback: source)
                addedName = balise.name
                input = ""
                search = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isAdding = false
        }
    }

    private func runSearch() {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return }
        Task { await perform(query: query, near: nil, emptyMessage: "Aucune station trouvée pour « \(query) »") }
    }

    private func searchNearMe() async {
        do {
            let here = try await location.current()
            await searchNear(lat: here.latitude, lon: here.longitude)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func searchNear(lat: Double, lon: Double) async {
        await perform(query: "", near: (lat, lon),
                      emptyMessage: "Aucune station indexée dans un rayon de 60 km pour l'instant")
    }

    private func perform(query: String, near: (lat: Double, lon: Double)?, emptyMessage: String) async {
        isLoadingSensors = true
        errorMessage = nil
        indexNote = nil
        do {
            let found = try await ServerClient.shared.searchSensors(
                provider: .windguru, query: query, near: near)
            results = found.sensors.map {
                Balise(code: $0.sourceCode, name: $0.name, altitude: $0.altitude,
                       latitude: $0.lat, longitude: $0.lon, provider: searchProvider)
            }
            distances = Dictionary(uniqueKeysWithValues: found.sensors.compactMap { hit in
                hit.km.map { (Balise.handle(for: hit.sourceCode), $0) }
            })
            if let index = found.index, index.scanned < index.total {
                indexNote = "Catalogue en cours de constitution : \(index.indexed) stations indexées sur \(index.scanned) identifiants balayés. En attendant, coller un lien windguru fonctionne déjà."
            }
            if results.isEmpty { errorMessage = emptyMessage }
        } catch {
            errorMessage = "Recherche indisponible — le serveur doit être joignable (Tailscale)."
        }
        isLoadingSensors = false
    }

    private func loadSensors() async {
        isLoadingSensors = true
        errorMessage = nil
        do {
            sensors = try await WindMorbihanClient.shared.sensors()
        } catch {
            errorMessage = "Liste des capteurs indisponible — \(error.localizedDescription)"
        }
        isLoadingSensors = false
    }
}
