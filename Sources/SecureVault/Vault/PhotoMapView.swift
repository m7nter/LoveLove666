import SwiftUI
import MapKit

struct PhotoPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let url: URL
    let date: Date
}

struct PinCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let pins: [PhotoPin]
}

struct PhotoMapView: View {
    @Environment(\.dismiss) var dismiss
    @State private var pins: [PhotoPin] = []
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.75, longitude: 37.62),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )
    @State private var selectedPin: PhotoPin?
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        ZStack {
            Map(coordinateRegion: $region,
                annotationItems: clusteredPins(pins: pins, span: region.span)) { cluster in
                MapAnnotation(coordinate: cluster.coordinate) {
                    if cluster.pins.count > 1 {
                        Button {
                            withAnimation {
                                region = MKCoordinateRegion(
                                    center: cluster.coordinate,
                                    span: MKCoordinateSpan(
                                        latitudeDelta: region.span.latitudeDelta / 2.5,
                                        longitudeDelta: region.span.longitudeDelta / 2.5
                                    )
                                )
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 38, height: 38)
                                Text("\(cluster.pins.count)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .shadow(radius: 2)
                        }
                    } else if let pin = cluster.pins.first {
                        Button {
                            selectedPin = pin
                        } label: {
                            VStack(spacing: 2) {
                                if let img = FileStorageManager.shared.loadImage(at: pin.url) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.orange, lineWidth: 2)
                                        )
                                } else {
                                    Image(systemName: "camera.fill")
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.orange)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Image(systemName: "triangle.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.orange)
                                    .rotationEffect(.degrees(180))
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding()
                    Spacer()
                    Text("Карта меток")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)
                    Spacer()
                    // Кнопка центрировать на текущей позиции
                    Button {
                        if let loc = LocationManager.shared.location {
                            region.center = loc.coordinate
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding()
                }
                .padding(.top, 50)

                Spacer()

                // Счётчик меток
                Text("\(pins.count) фото на карте")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(12)
                    .padding(.bottom, 32)
            }

            // Превью выбранного фото
            if let pin = selectedPin {
                VStack {
                    Spacer()
                    HStack {
                        if let img = FileStorageManager.shared.loadImage(at: pin.url) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "%.6f, %.6f",
                                        pin.coordinate.latitude,
                                        pin.coordinate.longitude))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                            Text(formatDate(pin.date))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Button {
                            selectedPin = nil
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.gray.opacity(0.4))
                                .clipShape(Circle())
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(16)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100)
                }
            }
        }
        .onAppear { loadPins() }
    }

    private func clusteredPins(pins: [PhotoPin], span: MKCoordinateSpan) -> [PinCluster] {
        guard settings.clusterMapPins, pins.count > 1 else {
            return pins.map { PinCluster(id: $0.id.uuidString, coordinate: $0.coordinate, pins: [$0]) }
        }

        // Квантуем масштаб ступенями (по степеням двойки), чтобы кластеры
        // не пересчитывались на каждый пиксель во время непрерывного зума —
        // именно это раньше вызывало "мигание" меток.
        let rawSpan = max(span.latitudeDelta, span.longitudeDelta)
        guard rawSpan > 0 else {
            return pins.map { PinCluster(id: $0.id.uuidString, coordinate: $0.coordinate, pins: [$0]) }
        }
        let zoomLevel = floor(log2(rawSpan))
        let steppedSpan = pow(2.0, zoomLevel)
        let gridSize = steppedSpan / 20
        guard gridSize > 0 else {
            return pins.map { PinCluster(id: $0.id.uuidString, coordinate: $0.coordinate, pins: [$0]) }
        }

        var buckets: [String: [PhotoPin]] = [:]
        for pin in pins {
            let latKey = Int((pin.coordinate.latitude / gridSize).rounded())
            let lonKey = Int((pin.coordinate.longitude / gridSize).rounded())
            let key = "\(Int(zoomLevel))_\(latKey)_\(lonKey)"
            buckets[key, default: []].append(pin)
        }

        return buckets.map { key, group in
            let avgLat = group.map { $0.coordinate.latitude }.reduce(0, +) / Double(group.count)
            let avgLon = group.map { $0.coordinate.longitude }.reduce(0, +) / Double(group.count)
            return PinCluster(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                pins: group
            )
        }
    }

    private func loadPins() {
        let items = FileStorageManager.shared.loadAllWithMeta()
        var result: [PhotoPin] = []
        for (url, meta) in items {
            if let m = meta, m.hasLocation != false,
               CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: m.latitude, longitude: m.longitude)) {
                result.append(PhotoPin(
                    coordinate: CLLocationCoordinate2D(
                        latitude: m.latitude,
                        longitude: m.longitude
                    ),
                    url: url,
                    date: m.date
                ))
            }
        }
        pins = result

        // Центрируем карту на первом пине
        if let first = result.first {
            region.center = first.coordinate
        } else if let loc = LocationManager.shared.location {
            region.center = loc.coordinate
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return f.string(from: date)
    }
}
