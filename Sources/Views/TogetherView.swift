//
//  TogetherView.swift
//  ViviMusic
//
//  Listen Together の画面。
//  部屋を作ってホストになるか、コードを入れて既存の部屋に入る。
//

import SwiftUI
import UIKit

struct TogetherView: View {
    @EnvironmentObject private var together: TogetherManager
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    @State private var roomCodeInput = ""
    @State private var showSettings = false
    @State private var showChat = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    intro
                    connectionCard

                    if together.state.isInRoom {
                        roomCard
                        if !together.pendingRequests.isEmpty {
                            requestsCard
                        }
                        membersCard
                    } else {
                        joinCard
                    }

                    settingsRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showSettings) {
                TogetherSettingsView()
            }
            .sheet(isPresented: $showChat) {
                TogetherChatView()
            }
            .overlay(alignment: .bottom) {
                messageBanner
            }
        }
    }

    // MARK: - 説明

    private var intro: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.2))
                    .frame(width: 60, height: 60)
                Image(systemName: "person.2.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Listen Together")
                    .font(.title3.weight(.bold))
                Text("友達とリアルタイムで音楽を一緒に聴くことができます。"
                     + "ルームを作成してホストするか、コードを使って既存のルームに参加できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - 接続状態

    private var connectionCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(together.state.label)
                    .font(.subheadline.weight(.semibold))
            }

            if together.state == .disconnected {
                Button {
                    together.connect()
                } label: {
                    Label("接続", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            } else {
                Button(role: .destructive) {
                    together.disconnect()
                } label: {
                    Label("切断", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusColor: Color {
        switch together.state {
        case .disconnected: return .gray
        case .connecting:   return .orange
        case .connected:    return .blue
        case .inRoom:       return .green
        }
    }

    // MARK: - 参加 / 作成

    private var joinCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                TextField("ユーザー名", text: $together.username)
                    .textInputAutocapitalization(.never)
            }
            .padding(14)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Image(systemName: "person.2")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                TextField("ルームコード", text: $roomCodeInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            .padding(14)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    together.joinRoom(code: roomCodeInput)
                } label: {
                    Label("参加", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .disabled(roomCodeInput.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    together.createRoom()
                } label: {
                    Label("ルームを作成", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 参加中の部屋

    private var roomCard: some View {
        VStack(spacing: 12) {
            if let code = together.roomCode {
                VStack(spacing: 4) {
                    Text("ルームコード")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = code
                        together.statusMessage = "コードをコピーしました"
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                            .font(.footnote)
                    }
                }
            }

            if together.isHost {
                Label("あなたがホストです。再生操作が全員に反映されます。",
                      systemImage: "crown.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("ホストの再生に合わせて自動で同期します。",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    showChat = true
                } label: {
                    Label("チャット", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)

                if !together.isHost {
                    Button {
                        together.requestSync()
                    } label: {
                        Label("再同期", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }
            }

            Button(role: .destructive) {
                together.leaveRoom()
            } label: {
                Label("ルームを退出", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 参加申請 (ホストのみ)

    private var requestsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参加のリクエスト")
                .font(.subheadline.weight(.semibold))

            ForEach(together.pendingRequests) { user in
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text(user.username)
                    Spacer()
                    Button("許可") { together.approve(userID: user.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                    Button("拒否") { together.reject(userID: user.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 参加者一覧

    private var membersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参加者 (\(together.users.count))")
                .font(.subheadline.weight(.semibold))

            if together.users.isEmpty {
                Text("まだ他に参加者はいません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(together.users) { user in
                HStack(spacing: 10) {
                    Image(systemName: user.isHost ? "crown.fill" : "person.crop.circle")
                        .foregroundStyle(user.isHost ? Theme.accent : .secondary)
                        .frame(width: 20)
                    Text(user.username)
                    if !user.isConnected {
                        Text("切断中")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if together.isHost, user.id != together.myUserID {
                        Button("退出させる") { together.kick(userID: user.id) }
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 設定

    private var settingsRow: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("設定")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("サーバーやユーザー名などを設定します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 通知帯

    @ViewBuilder
    private var messageBanner: some View {
        if let error = together.errorMessage {
            banner(text: error, color: .red) { together.errorMessage = nil }
        } else if let status = together.statusMessage {
            banner(text: status, color: Theme.accent) { together.statusMessage = nil }
        }
    }

    private func banner(text: String,
                        color: Color,
                        dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
        .background(color.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            dismiss()
        }
    }
}

// MARK: - 設定画面

struct TogetherSettingsView: View {
    @EnvironmentObject private var together: TogetherManager
    @Environment(\.dismiss) private var dismiss

    @State private var customURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("ユーザー名") {
                    TextField("表示名", text: $together.username)
                        .textInputAutocapitalization(.never)
                }

                Section {
                    ForEach(TogetherServer.all) { server in
                        Button {
                            together.serverURL = server.url
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .foregroundStyle(.primary)
                                    Text("\(server.location) ・ \(server.operatorName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if together.serverURL == server.url {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("サーバー")
                } footer: {
                    Text("同じサーバーに接続している人同士でルームを共有できます。"
                         + "Android 版の VIVI Music とも一緒に聴けます。")
                }

                Section {
                    TextField("wss://…", text: $customURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("このサーバーを使う") {
                        let trimmed = customURL.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        together.serverURL = trimmed
                        dismiss()
                    }
                    .disabled(customURL.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("自分のサーバー")
                } footer: {
                    Text("現在の接続先: \(together.serverURL)")
                }
            }
            .navigationTitle("Together の設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - チャット

struct TogetherChatView: View {
    @EnvironmentObject private var together: TogetherManager
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if together.chatMessages.isEmpty {
                    StateMessage(kind: .empty(
                        icon: "bubble.left.and.bubble.right",
                        title: "まだ発言がありません",
                        message: "下の欄からメッセージを送れます。"
                    ))
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(together.chatMessages) { message in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(message.username)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Theme.accent)
                                        Text(message.text)
                                            .font(.subheadline)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(message.id)
                                }
                            }
                            .padding(16)
                        }
                        .onChange(of: together.chatMessages.count) { _, _ in
                            if let last = together.chatMessages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    TextField("メッセージ", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendDraft)
                    Button {
                        sendDraft()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
            .navigationTitle("チャット")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func sendDraft() {
        together.sendChat(draft)
        draft = ""
    }
}
