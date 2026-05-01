import SwiftUI

struct PurchaseReadinessView: View {
    @AppStorage("purchaseReadiness") private var readinessData: Data = Data()
    @State private var readiness = PurchaseReadiness()
    @State private var amountText = ""
    @State private var showingAddDoc = false
    @State private var newDocName = ""

    var body: some View {
        List {
            // Progress overview
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("準備状況")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(readiness.readinessPercentage * 100))%")
                            .font(.title2.bold())
                            .foregroundStyle(readiness.isReady ? .green : .orange)
                    }
                    ProgressView(value: readiness.readinessPercentage)
                        .tint(readiness.isReady ? .green : .orange)
                }
                .padding(.vertical, 4)
            }

            // Pre-approval section
            Section("事前審査") {
                Picker("ステータス", selection: $readiness.preApprovalStatus) {
                    ForEach(PreApprovalStatus.allCases, id: \.self) { status in
                        Label(status.displayName, systemImage: status.icon)
                            .tag(status)
                    }
                }

                HStack {
                    Text("承認額")
                    Spacer()
                    TextField("例: 10000", text: $amountText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .onChange(of: amountText) { _, v in readiness.preApprovalAmount = Int(v) }
                    Text("万円")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("金融機関")
                    Spacer()
                    TextField("銀行名", text: Binding(
                        get: { readiness.preApprovalBank ?? "" },
                        set: { readiness.preApprovalBank = $0.isEmpty ? nil : $0 }
                    ))
                    .multilineTextAlignment(.trailing)
                }

                DatePicker("有効期限",
                    selection: Binding(
                        get: { readiness.preApprovalExpiry ?? Date() },
                        set: { readiness.preApprovalExpiry = $0 }
                    ),
                    displayedComponents: .date
                )

                if let expiry = readiness.preApprovalExpiry {
                    let daysLeft = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
                    if daysLeft < 0 {
                        Label("期限切れ", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if daysLeft <= 30 {
                        Label("残り\(daysLeft)日", systemImage: "clock")
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Documents checklist
            Section {
                ForEach($readiness.requiredDocs) { $doc in
                    Toggle(doc.name, isOn: $doc.isCompleted)
                }
                .onDelete { indices in
                    readiness.requiredDocs.remove(atOffsets: indices)
                }
                Button {
                    showingAddDoc = true
                } label: {
                    Label("書類を追加", systemImage: "plus.circle")
                }
            } header: {
                HStack {
                    Text("必要書類")
                    Spacer()
                    Text("\(readiness.completedDocCount)/\(readiness.requiredDocs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("買付準備")
        .alert("書類を追加", isPresented: $showingAddDoc) {
            TextField("書類名", text: $newDocName)
            Button("追加") {
                if !newDocName.isEmpty {
                    readiness.requiredDocs.append(
                        RequiredDocument(id: UUID(), name: newDocName, isCompleted: false)
                    )
                    newDocName = ""
                }
            }
            Button("キャンセル", role: .cancel) { newDocName = "" }
        }
        .onAppear { load() }
        .onChange(of: readiness) { _, _ in save() }
    }

    private func load() {
        guard !readinessData.isEmpty else { return }
        if let decoded = try? JSONDecoder().decode(PurchaseReadiness.self, from: readinessData) {
            readiness = decoded
            amountText = readiness.preApprovalAmount.map { "\($0)" } ?? ""
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(readiness) {
            readinessData = encoded
        }
    }
}
