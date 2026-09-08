import SwiftUI
import MapKit

/// Où est posée la balise.
///
/// On utilise MapKit plutôt qu'une carte OpenStreetMap en WebView : c'est natif,
/// sans clé ni dépendance, et le rendu reste fluide dans une page qui défile.
/// Les liens externes, eux, laissent le choix — dont OpenStreetMap.
struct BaliseMapCard: View {
    let balise: Balise
    let coordinate: CLLocationCoordinate2D
    @State private var showFullMap = false

    var body: some View {
        Button {
            showFullMap = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Position", systemImage: "mappin.and.ellipse")
                        .font(.headline)
                    Spacer()
                    Text(BaliseMapCard.formatted(coordinate))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
                ))) {
                    Marker(balise.name, systemImage: "wind", coordinate: coordinate)
                        .tint(Color.accentColor)
                }
                .frame(height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // Aperçu seulement : sans ça, la carte capterait le défilement
                // de la page dès qu'on passe le doigt dessus.
                .allowsHitTesting(false)

                HStack(spacing: 4) {
                    Text("Toucher pour agrandir")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showFullMap) {
            BaliseMapSheet(balise: balise, coordinate: coordinate)
        }
    }

    static func formatted(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}

/// Carte plein écran, manipulable, avec les liens vers les applications externes.
struct BaliseMapSheet: View {
    let balise: Balise
    let coordinate: CLLocationCoordinate2D

    @Environment(\.dismiss) private var dismiss
    @State private var satellite = true

    /// `MapStyle` est un protocole aux types concrets distincts : `.standard` et
    /// `.hybrid` ne peuvent pas se rejoindre dans un ternaire, d'où les deux
    /// branches plutôt qu'une valeur stockée.
    @ViewBuilder
    private var map: some View {
        let content = Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        ))) {
            Marker(balise.name, systemImage: "wind", coordinate: coordinate)
                .tint(Color.accentColor)
        }
        if satellite {
            content.mapStyle(.hybrid(elevation: .realistic))
        } else {
            content.mapStyle(.standard)
        }
    }

    var body: some View {
        NavigationStack {
            map
            .mapControls {
                MapCompass()
                MapScaleView()
                MapUserLocationButton()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Picker("Fond de carte", selection: $satellite) {
                        Text("Plan").tag(false)
                        Text("Satellite").tag(true)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        openButton("Plans", "map", url: appleMapsURL)
                        openButton("Google", "globe", url: googleMapsURL)
                        openButton("OSM", "point.topleft.down.to.point.bottomright.curvepath",
                                   url: openStreetMapURL)
                    }

                    Text(BaliseMapCard.formatted(coordinate))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(14)
                .background(.regularMaterial)
            }
            .navigationTitle(balise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    private func openButton(_ title: String, _ icon: String, url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Liens externes

    private var query: String {
        "\(coordinate.latitude),\(coordinate.longitude)"
    }

    private var appleMapsURL: URL {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "ll", value: query),
                                 URLQueryItem(name: "q", value: balise.name)]
        return components.url!
    }

    private var googleMapsURL: URL {
        URL(string: "https://www.google.com/maps/search/?api=1&query=\(query)")!
    }

    private var openStreetMapURL: URL {
        URL(string: "https://www.openstreetmap.org/?mlat=\(coordinate.latitude)&mlon=\(coordinate.longitude)#map=15/\(coordinate.latitude)/\(coordinate.longitude)")!
    }
}
