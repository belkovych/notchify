import SwiftUI

/// The "where the music plays" screen: Spotify Connect devices, or the one-time setup for them.
struct DevicesView: View {
    @ObservedObject var model: SpotifyModel
    @ObservedObject var connect: SpotifyConnect
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                HeaderButton(symbol: "chevron.left", action: onBack)
                Text("Де грає музика")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if connect.phase == .ready {
                    HeaderButton(symbol: "arrow.clockwise") { connect.reload() }
                        .opacity(connect.loading ? 0.35 : 1)
                }
            }
            .padding(.leading, -6)

            Group {
                switch connect.phase {
                case .needsClientID: setup
                case .needsLogin: login
                case .waitingForBrowser: waiting
                case .ready: list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .onAppear { connect.reload() }
    }

    // MARK: - Device list

    private var list: some View {
        VStack(spacing: 4) {
            if connect.devices.isEmpty {
                Spacer(minLength: 0)
                if connect.loading {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                } else if connect.message == nil {
                    note("Пристроїв не знайдено.\nВідкрийте Spotify на потрібному пристрої й оновіть список.")
                }
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(connect.devices) { device in
                            DeviceRow(
                                device: device, playing: model.isPlaying, tint: model.palette.accent,
                                busy: connect.transferringID == device.id
                            ) { connect.transfer(to: device) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            if let message = connect.message { warning(message) }
        }
    }

    // MARK: - One-time setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 5) {
            step("1", "developer.spotify.com → Create app, API: Web API")
            step("2", "Redirect URI:  \(SpotifyConnect.redirectURI)")
            step("3", "Скопіюйте Client ID застосунку й натисніть «Вставити»")
            Spacer(minLength: 0)
            if let message = connect.message { warning(message) }
            HStack(spacing: 6) {
                PillButton(title: "Сайт") { NSWorkspace.shared.open(SpotifyConnect.dashboardURL) }
                PillButton(title: "Копіювати URI") { connect.copyRedirectURI() }
                Spacer(minLength: 0)
                PillButton(title: "Вставити Client ID", prominent: true) { connect.pasteClientID() }
            }
        }
    }

    private var login: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            note("Client ID збережено. Увійдіть у Spotify,\nщоб бачити пристрої й перемикати музику.")
            if let message = connect.message { warning(message) }
            HStack(spacing: 6) {
                PillButton(title: "Інший Client ID") { connect.forgetClientID() }
                PillButton(title: "Увійти в Spotify", prominent: true) { connect.login() }
            }
            Spacer(minLength: 0)
        }
    }

    private var waiting: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            ProgressView().controlSize(.small).colorScheme(.dark)
            note("Підтвердьте доступ у браузері…")
            PillButton(title: "Скасувати") { connect.cancelLogin() }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Text pieces

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(number)
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.45))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

private struct DeviceRow: View {
    var device: ConnectDevice
    var playing: Bool
    var tint: Color
    var busy: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24)
                Text(device.name)
                    .font(.system(size: 13, weight: device.isActive ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                } else if device.isActive {
                    EqualizerBars(playing: playing, color: tint)
                        .frame(width: 14, height: 12)
                }
            }
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(device.isActive ? tint : .white)
            .opacity(device.isRestricted ? 0.35 : (device.isActive || hovering ? 1 : 0.75))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(hovering && !device.isRestricted ? 0.13 : (device.isActive ? 0.07 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct HeaderButton: View {
    var symbol: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.6))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct PillButton: View {
    var title: String
    var prominent = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        prominent
                            ? Color(red: 0.12, green: 0.84, blue: 0.38).opacity(hovering ? 1 : 0.92)
                            : Color.white.opacity(hovering ? 0.24 : 0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
