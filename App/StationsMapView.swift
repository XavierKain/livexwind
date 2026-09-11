import SwiftUI
import MapKit

/// Onglet Carte : toutes les balises connues autour d'un point, toutes sources
/// confondues.
///
/// C'est le pendant de la recherche par nom : sur place, on ne sait pas quelle
/// source couvre le coin — on veut voir ce qui existe et choisir sur la carte.
struct StationsMapView: View {
    @ObservedObject var store: WindStore
    var onAdded: () -> Void

    @StateObject private var location = LocationProvider()
    @State private var camera: MapCameraPosition = .automatic
    @State private var center = CLLocationCoordinate2D(latitude: 44.5761, longitude: -1.2247)
    @State private var stations: [MapStation] = []
    @State private var selected: MapStation?
    @State private var isLoading = false
    @State private var message: String?
    @State private var visibleSpan: Double = 0.5
    /// Dernière zone effectivement chargée, pour ne pas tout redemander à chaque
    /// petit déplacement.
    @State private var lastFetch: (center: CLLocationCoordinate2D, radius: Double)?

    /// Au-delà d'environ 220 km de large, afficher des balises n'a pas de sens :
    /// elles se chevaucheraient, et il faudrait charger le monde entier.
    private static let maxSpanDegrees = 2.0

    var body: some View {
        NavigationStack {
            // Les pastilles ne captent plus le toucher : un bouton posé sur la
            // carte avalait le début d'un pincement dès qu'un doigt s'y trouvait,
            // et le zoom ne partait pas. C'est la carte qui reçoit le tap, et on
            // cherche ensuite la balise la plus proche du point touché.
            MapReader { proxy in
                Map(position: $camera) {
                    ForEach(stations) { station in
                        Annotation(station.balise.name, coordinate: station.coordinate) {
                            pin(for: station)
                                .allowsHitTesting(false)
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .onTapGesture { point in
                    guard let touched = proxy.convert(point, from: .local) else { return }
                    selected = nearestStation(to: touched)
                }
            }
            .mapControls { MapUserLocationButton(); MapCompass() }
            // `.onEnd` : rien ne se charge pendant le geste, seulement quand la
            // carte s'immobilise.
            .onMapCameraChange(frequency: .onEnd) { context in
                let region = context.region
                center = region.center
                visibleSpan = max(region.span.latitudeDelta, region.span.longitudeDelta)
                Task { await reloadIfNeeded(region: region) }
            }
            .overlay(alignment: .top) { banner }
            .safeAreaInset(edge: .bottom) { legend }
            .navigationTitle("Carte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await locateMe() }
                    } label: {
                        Label("Autour de moi", systemImage: "location")
                    }
                }
            }
            .sheet(item: $selected) { station in
                MapStationSheet(station: station, store: store) {
                    selected = nil
                    onAdded()
                }
                .presentationDetents([.height(280)])
            }
            .task { await start() }
        }
    }

    // MARK: Pièces

    /// Pastille du vent plutôt qu'une épingle : sur une carte, ce qu'on cherche
    /// c'est « combien ça souffle là-bas », pas où est le capteur.
    ///
    /// Volontairement légère — pas de matériau translucide ni de pile de vues :
    /// avec plusieurs dizaines d'annotations, le flou temps réel faisait saccader
    /// le zoom.
    private func pin(for station: MapStation) -> some View {
        let tracked = store.catalog.balises.contains { $0.key == station.balise.key }
        let wind = station.reading?.averageKmh
        let offline = station.isOffline
        let tint: Color = offline ? .gray
            : (wind != nil ? WindPalette.color(kmh: wind) : color(of: station.balise.provider))

        return HStack(spacing: 2) {
                if let direction = station.reading?.directionDegrees, !offline {
                    WindArrow(degrees: direction, color: .white)
                        .frame(width: 8, height: 8)
                }
                Text(wind != nil && !offline ? store.unit.format(kmh: wind) : "—")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(tracked ? 1 : 0.35),
                                  lineWidth: tracked ? 2 : 1))
        .opacity(offline ? 0.6 : 1)
    }

    /// Balise la plus proche du point touché, dans une tolérance qui suit le
    /// zoom : environ 4 % de la largeur visible.
    private func nearestStation(to coordinate: CLLocationCoordinate2D) -> MapStation? {
        let toleranceKm = max(0.5, visibleSpan * 111 * 0.04)
        return stations
            .map { ($0, distanceKm($0.coordinate, coordinate)) }
            .filter { $0.1 <= toleranceKm }
            .min { $0.1 < $1.1 }?.0
    }

    @ViewBuilder
    private var banner: some View {
        if visibleSpan > Self.maxSpanDegrees {
            Label("Zoome pour voir les balises", systemImage: "plus.magnifyingglass")
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 6)
        } else if isLoading || message != nil {
            HStack(spacing: 6) {
                if isLoading { ProgressView().controlSize(.mini) }
                Text(message ?? "Recherche des balises…")
                    .font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 6)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Text("Vent en \(store.unit.symbol) · couleur = force")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                lastFetch = nil
                Task { await reload(around: center, radiusKm: min(150, max(10, visibleSpan * 111 * 0.7))) }
            } label: {
                Label("Actualiser", systemImage: "arrow.clockwise")
                    .font(.caption2.weight(.semibold))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func color(of provider: BaliseProvider) -> Color {
        switch provider {
        case .ffvl: return .blue
        case .windMorbihan: return .teal
        case .windguru: return .purple
        case .meteoCat: return .orange
        case .kwind: return .green
        }
    }

    // MARK: Chargement

    private func start() async {
        // On part de la balise affichée : c'est le contexte le plus probable.
        if let latitude = store.balise.latitude ?? store.snapshot.latitude,
           let longitude = store.balise.longitude ?? store.snapshot.longitude {
            center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        camera = .region(MKCoordinateRegion(center: center,
                                            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)))
        await reload(around: center, radiusKm: 40)
    }

    /// Recharge seulement si la vue est assez resserrée, et si elle a assez
    /// bougé depuis la dernière fois.
    private func reloadIfNeeded(region: MKCoordinateRegion) async {
        guard visibleSpan <= Self.maxSpanDegrees else {
            stations = []
            message = nil
            lastFetch = nil
            return
        }

        // Un degré de latitude ≈ 111 km ; on couvre la diagonale visible.
        let radius = min(150, max(10, visibleSpan * 111 * 0.7))

        if let last = lastFetch {
            let moved = distanceKm(last.center, region.center)
            let sameScale = abs(last.radius - radius) / last.radius < 0.4
            if sameScale && moved < last.radius * 0.35 { return }
        }

        await reload(around: region.center, radiusKm: radius)
    }

    private func distanceKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1000
    }

    private func locateMe() async {
        do {
            let here = try await location.current()
            center = here
            camera = .region(MKCoordinateRegion(center: here,
                                                span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)))
            await reload(around: here, radiusKm: 35)
        } catch {
            message = error.localizedDescription
        }
    }

    private func reload(around coordinate: CLLocationCoordinate2D, radiusKm: Double) async {
        isLoading = true
        message = nil
        stations = await MapStation.around(coordinate, radiusKm: radiusKm)
        lastFetch = (coordinate, radiusKm)
        isLoading = false
        if stations.isEmpty {
            message = "Aucune balise connue dans un rayon de \(Int(radiusKm)) km"
        }
    }
}

/// Une balise située, telle que la carte l'affiche.
struct MapStation: Identifiable, Hashable {
    let balise: Balise
    let distanceKm: Double?
    /// Vent du moment, quand la source sait le livrer sans requête dédiée.
    var reading: WindReading?

    var id: String { balise.key }

    /// Hors ligne : plus de deux fois la cadence habituelle de la source sans
    /// relevé. On n'a pas mesuré la cadence d'une balise qu'on ne suit pas, d'où
    /// l'estimation par source.
    var isOffline: Bool {
        guard let date = reading?.date else { return false }
        return Date().timeIntervalSince(date) > balise.provider.typicalPeriod * 2 + 60
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: balise.latitude ?? 0, longitude: balise.longitude ?? 0)
    }

    /// Interroge le serveur, qui interroge toutes les sources d'un coup ; à
    /// défaut, on recompose depuis les catalogues publics.
    static func around(_ coordinate: CLLocationCoordinate2D, radiusKm: Double) async -> [MapStation] {
        if let remote = try? await ServerClient.shared.mapStations(
            near: (latitude: coordinate.latitude, longitude: coordinate.longitude),
            radiusKm: radiusKm),
           !remote.isEmpty {
            return remote.compactMap { hit in
                guard let provider = BaliseProvider(rawValue: hit.provider),
                      let lat = hit.lat, let lon = hit.lon else { return nil }
                return MapStation(balise: Balise(code: hit.code, name: hit.name ?? hit.code,
                                                 altitude: hit.altitude, latitude: lat, longitude: lon,
                                                 provider: provider),
                                  distanceKm: hit.km,
                                  reading: hit.current?.reading)
            }
        }

        var found: [MapStation] = []
        for provider in BaliseProvider.allCases where provider.supportsProximity {
            let hits = await StationCatalog.nearby(latitude: coordinate.latitude,
                                                   longitude: coordinate.longitude,
                                                   provider: provider, radiusKm: radiusKm)
            found += hits.map { MapStation(balise: $0.balise, distanceKm: $0.km, reading: nil) }
        }
        return found.sorted { ($0.distanceKm ?? 0) < ($1.distanceKm ?? 0) }
    }
}

/// Fiche d'une balise touchée sur la carte, avec son vent du moment.
struct MapStationSheet: View {
    let station: MapStation
    @ObservedObject var store: WindStore
    var onAdded: () -> Void

    @State private var reading: WindReading?
    @State private var isAdding = false


    private var alreadyTracked: Bool {
        store.catalog.balises.contains { $0.key == station.balise.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(station.balise.name).font(.headline)
                HStack(spacing: 6) {
                    Text(station.balise.provider.label)
                    if let km = station.distanceKm { Text("· \(Int(km)) km") }
                    if let altitude = station.balise.altitude { Text("· \(altitude) m") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            if let reading {
                HStack(spacing: 12) {
                    WindArrow(degrees: reading.directionDegrees,
                              color: WindPalette.color(kmh: reading.averageKmh))
                        .frame(width: 26, height: 26)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(store.unit.format(kmh: reading.averageKmh))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(WindPalette.color(kmh: reading.averageKmh))
                        Text(store.unit.symbol).font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("raf. \(store.unit.format(kmh: reading.gustKmh))")
                            .foregroundStyle(.orange)
                        Text(reading.directionText).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Relevé en cours…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button {
                add()
            } label: {
                Label(alreadyTracked ? "Déjà dans mes spots" : "Ajouter à mes spots",
                      systemImage: alreadyTracked ? "checkmark.circle.fill" : "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(alreadyTracked || isAdding)
        }
        .padding(18)
        .task {
            // `??` place son membre droit dans une fermeture non asynchrone :
            // l'attente doit être écrite explicitement.
            if let known = station.reading {
                reading = known
            } else {
                reading = try? await BaliseClient(balise: station.balise).fetchPublicFeed().current
            }
        }
    }

    private func add() {
        isAdding = true
        Task {
            _ = await store.addBalise(station.balise)
            isAdding = false
            onAdded()
        }
    }
}
