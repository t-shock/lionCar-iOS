import SwiftUI
import LionCore

/// Lock / unlock and the other remote buttons, for the Car tab.
struct RemoteCard: View {
    @Environment(AppModel.self) private var model
    @State private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.remoteReady {
                HStack(spacing: 10) {
                    bigButton("Lock", "lock.fill") { await model.lockCar(true) }
                    bigButton("Unlock", "lock.open.fill") { await model.lockCar(false) }
                }
                HStack(spacing: 10) {
                    smallButton("Lights", "headlight.high.beam.fill") { await model.lights() }
                    smallButton("Horn", "horn.fill") { await model.horn() }
                }
            } else if model.remotePossible {
                Button { showSetup = true } label: {
                    Label("Set up remote control", systemImage: "key.radiowaves.forward").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                Text("Lock, unlock, lights and horn. Needs a one-time SMS code and your \(model.brand.app) security code.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(model.brand.display) has no remote services for this account.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSetup) { RemoteSetupView() }
    }

    private func bigButton(_ title: LocalizedStringKey, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: icon).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.commandLabel != nil)
    }

    private func smallButton(_ title: LocalizedStringKey, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .disabled(model.commandLabel != nil)
    }
}

/// One-time setup: SMS code + the brand app's security code.
struct RemoteSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sms = ""
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Remote commands are signed with one-time codes, exactly like in \(model.brand.app). To turn them on, \(model.brand.display) sends an SMS code to the phone number on your account, and you enter it together with your \(model.brand.app) security code (the 4-digit code you chose when you added the car).")
                        .font(.subheadline)
                }
                Section("1. Get the SMS code") {
                    Button {
                        Task { await model.requestSMS() }
                    } label: {
                        HStack {
                            Text(model.smsSent ? "Send a new SMS code" : "Send SMS code")
                            Spacer()
                            if model.setupBusy && !model.smsSent { ProgressView() }
                        }
                    }
                    .disabled(model.setupBusy)
                    if model.smsSent { Label("SMS sent — check your messages", systemImage: "checkmark.circle").foregroundStyle(.green) }
                }
                Section("2. Enter both codes") {
                    TextField("SMS code", text: $sms).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    SecureField("\(model.brand.app) security code", text: $pin).keyboardType(.numberPad)
                }
                Section {
                    Button {
                        Task { if await model.activateRemote(sms: sms, pin: pin) { dismiss() } }
                    } label: {
                        HStack {
                            Spacer()
                            if model.setupBusy && model.smsSent { ProgressView() } else { Text("Activate").bold() }
                            Spacer()
                        }
                    }
                    .disabled(sms.trimmingCharacters(in: .whitespaces).isEmpty || pin.count < 4 || model.setupBusy)
                } footer: {
                    Text("The security code stays on this iPhone, in the Keychain. \(model.brand.doorsPack) is needed for lock, unlock, lights and horn.")
                }
            }
            .navigationTitle("Remote control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// Settings › Remote control.
struct RemoteSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var showSetup = false
    @State private var confirmForget = false

    var body: some View {
        Section("Remote control") {
            LabeledContent("Status", value: model.remoteReady ? L("Ready") : (model.remotePossible ? L("Not set up") : L("Not available")))
            if model.remotePossible {
                Button(model.remoteReady ? "Set up again" : "Set up remote control") { showSetup = true }
            }
            if model.remoteReady {
                Button("Turn off remote control", role: .destructive) { confirmForget = true }
            }
            NavigationLink("Command log") { CommandLogView() }
        }
        .sheet(isPresented: $showSetup) { RemoteSetupView() }
        .confirmationDialog("Turn off remote control on this iPhone?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { model.forgetRemote() }
        } message: {
            Text("You can set it up again later with a new SMS code.")
        }
    }
}

struct CommandLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.commandLog.isEmpty { Text("No commands sent since the app was opened.").foregroundStyle(.secondary) }
            ForEach(Array(model.commandLog.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("Command log")
        .task { await model.loadCommandLog() }
        .refreshable { await model.loadCommandLog() }
    }
}
