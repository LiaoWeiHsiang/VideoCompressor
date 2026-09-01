import SwiftUI

/// Where the Immich server address and API key are entered.
///
/// The key is typed here and stored in the Keychain; it is never logged, never written
/// beside the queue, and never leaves the device except as the `x-api-key` header on
/// requests to the server the user named.
struct ImmichSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ImmichCredentialStore.serverURLString
    @State private var apiKey = ImmichCredentialStore.apiKey ?? ""
    @State private var isTesting = false
    @State private var serverResult: Result<String, Error>?
    @State private var keyResult: Result<String, Error>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://immich.example.com", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("伺服器網址")
                } footer: {
                    Text("填到網域即可，例如 https://immich.example.com，結尾的 /api 可加可不加。")
                }

                Section {
                    SecureField("API 金鑰", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API 金鑰")
                } footer: {
                    Text("在 Immich 網頁版的「帳號設定 → API 金鑰」建立。金鑰只會存在這支手機的 Keychain 裡。")
                }

                Section {
                    Button {
                        Task { await runChecks() }
                    } label: {
                        if isTesting {
                            HStack { ProgressView(); Text("測試中…") }
                        } else {
                            Text("測試連線")
                        }
                    }
                    .disabled(isTesting || serverURL.trimmingCharacters(in: .whitespaces).isEmpty)

                    // Reported separately on purpose: a wrong address and a wrong key need
                    // different fixes, and one combined "failed" leaves you guessing.
                    if let serverResult { resultRow("伺服器", serverResult) }
                    if let keyResult { resultRow("金鑰", keyResult) }
                }

                if ImmichCredentialStore.isConfigured {
                    Section {
                        Button("清除設定", role: .destructive) {
                            ImmichCredentialStore.clear()
                            serverURL = ""
                            apiKey = ""
                            serverResult = nil
                            keyResult = nil
                        }
                    }
                }
            }
            .navigationTitle("Immich 上傳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("儲存") { save(); dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ label: String, _ result: Result<String, Error>) -> some View {
        switch result {
        case .success(let detail):
            Label("\(label)：\(detail)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failure(let error):
            Label("\(label)：\(error.localizedDescription)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    private func save() {
        ImmichCredentialStore.serverURLString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ImmichCredentialStore.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runChecks() async {
        isTesting = true
        serverResult = nil
        keyResult = nil
        defer { isTesting = false }

        save()
        guard let credentials = ImmichCredentialStore.credentials else {
            serverResult = .failure(ImmichClient.Failure.badServerURL)
            return
        }
        let client = ImmichClient(credentials: credentials)

        do {
            try await client.checkServerReachable()
            serverResult = .success("可連線")
        } catch {
            serverResult = .failure(error)
            return          // no point testing a key against an address that is not there
        }

        do {
            keyResult = .success(try await client.checkCredentials())
        } catch {
            keyResult = .failure(error)
        }
    }
}
